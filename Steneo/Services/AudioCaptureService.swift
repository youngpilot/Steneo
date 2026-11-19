import AVFoundation
import Accelerate
import CoreAudio
import os

private let logger = Logger(subsystem: "com.youngpilot.Steneo", category: "AudioCapture")

/// What a successful start ended up on — so a fallback is something the app can
/// say out loud instead of something that silently happened.
struct CaptureStartInfo: Equatable, Sendable {
    let device: AudioDevice
    let source: AudioDeviceResolver.Source
    /// Devices ranked ahead of this one that are not being used because they
    /// did not start, in order.
    let failedNames: [String]
    /// How long this device took to deliver its first audio. Shown next to it
    /// in the picker.
    let startMilliseconds: Double
}

/// Host time, the clock CoreAudio stamps every buffer with, in seconds.
enum HostClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func seconds(_ ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    static func ticks(_ seconds: Double) -> UInt64 {
        UInt64((seconds * 1_000_000_000 * Double(timebase.denom) / Double(timebase.numer)).rounded())
    }
}

/// A stretch of one recording from one microphone, at that microphone's rate.
struct CapturePiece: Equatable, Sendable {
    let rate: Double
    private(set) var samples: [Float] = []
    /// The host time just past the last sample held.
    private(set) var endHostTime: UInt64 = 0

    init(rate: Double) { self.rate = rate }

    mutating func append(_ new: [Float], at hostTime: UInt64) {
        samples.append(contentsOf: new)
        endHostTime = hostTime + HostClock.ticks(Double(new.count) / rate)
    }

    /// Drop what this microphone recorded from `hostTime` on — the moment
    /// another one took over — so the two join without saying anything twice.
    /// Never more than `limit`: if the two clocks disagree by more than that,
    /// something is wrong with a time stamp, and a syllable heard twice is the
    /// better mistake than a first word cut off. Returns the frames dropped.
    @discardableResult
    mutating func cut(at hostTime: UInt64, limit: TimeInterval = 0.25) -> Int {
        guard endHostTime > hostTime else { return 0 }
        let overlap = min(HostClock.seconds(endHostTime - hostTime), limit)
        let frames = min(samples.count, Int((overlap * rate).rounded()))
        samples.removeLast(frames)
        endHostTime = hostTime
        return frames
    }

    /// Hand the samples over and start empty.
    mutating func take() -> [Float] {
        let taken = samples
        samples = []
        return taken
    }

    /// Keep the newest `seconds`, checked only once `slack` over it: trimming on
    /// every buffer moved 115 MB twelve times a second past the ten-minute mark.
    mutating func keepLast(seconds: Double, slack: Double) {
        guard samples.count > Int((seconds + slack) * rate) else { return }
        samples.removeFirst(samples.count - Int(seconds * rate))
    }
}

/// Captures microphone audio for the ASR, directly from the device.
///
/// THE RULE, since 1.4.3: while no recording is running, this class holds NO
/// audio resources at all. No open device, nothing warmed up. An open input
/// device drags a Bluetooth headset into its call profile, and Steneo used to
/// keep one open for as long as it ran.
///
/// The price of that rule is paid at the start of every recording, and it is
/// the hardware's price: a USB display microphone needs about 450 ms before its
/// first sample exists. Until 1.7 whatever was said in that time was gone.
///
/// THE BRIDGE, since 1.7: the Mac's own microphone delivers after about 35 ms.
/// When another microphone is the one to record with, the Mac's is started
/// first and records until the other one delivers; the two are joined on the
/// time stamp of the hand-over. If the other one never delivers, the recording
/// simply stays where it is. Bridge and fallback are one mechanism.
///
/// STARTING walks an ordered list — the chosen device, then every other one by
/// how fast it starts — until one delivers a first buffer. A device that starts
/// and delivers nothing has not started.
///
/// THREADING: devices are opened and closed on `controlQueue`, their buffers
/// arrive on `ioQueue`, and everything both sides share sits behind one lock.
/// No device call is ever made while holding it.
final class AudioCaptureService: @unchecked Sendable {
    /// The device the user picked, by UID. `nil` means "Automatic": the
    /// microphone that starts fastest. Read when a recording starts.
    var preferredDeviceUID: String?
    /// What is known about how long each microphone takes to start, in
    /// milliseconds by UID. Decides the order under "Automatic".
    var startTimes: [String: Double] = [:]
    /// Reported once per successful start, when the microphone the recording
    /// ends up on is known: which one, and what was passed over to get there.
    var onStarted: (@Sendable (CaptureStartInfo) -> Void)?

    #if DEBUG
    /// Makes the next attempt on a device fail, so falling back can be tested
    /// for real instead of waiting for a microphone to break.
    var failNextStartForTesting = false
    #endif

    private let controlQueue = DispatchQueue(label: "com.youngpilot.Steneo.capture", qos: .userInitiated)
    private let ioQueue = DispatchQueue(label: "com.youngpilot.Steneo.capture.io", qos: .userInteractive)
    private let liveQueue = DispatchQueue(label: "com.youngpilot.Steneo.capture.live", qos: .userInitiated)

    /// Devices that recently refused to start. Passed over while the hardware
    /// looks the same, so a broken device costs its timeout once, not at every
    /// recording. controlQueue only.
    private var failures: [AudioDeviceResolver.Failure] = []
    /// Every device currently open. controlQueue only.
    private var open: [DeviceInputStream] = []
    /// liveQueue only.
    private let downsampler = LiveDownsampler()

    /// How long a device gets to produce its first buffer: wired devices answer
    /// within half a second, Bluetooth has to switch profiles first.
    private static let firstBufferLimit: TimeInterval = 0.7
    private static let firstBufferLimitBluetooth: TimeInterval = 2.5
    /// The most audio one recording keeps, and how far over before trimming.
    private static let maxSeconds: Double = 600
    private static let trimSlack: Double = 5

    private struct Sinks: Sendable {
        let onBuffer: @Sendable ([Float]) -> Void
        let onLevel: @Sendable (Float) -> Void
    }

    private struct State {
        /// Counts starts and stops. Whatever belongs to an earlier number is
        /// late and is dropped.
        var run = 0
        var capturing = false
        /// The microphone the recording is meant to run on.
        var lead: DeviceInputStream?
        /// The Mac's own microphone, covering until the lead delivers.
        var bridge: DeviceInputStream?
        var leadPiece: CapturePiece?
        var bridgePiece: CapturePiece?
        /// Called once: at the first audio, or with the reason there is none.
        var report: (@Sendable (AudioCaptureError?) -> Void)?
        var sinks: Sinks?
        var lastBufferAt: TimeInterval = 0
        /// Audio waiting to become one block for the level meter and the VAD.
        var pending: [Float] = []
        var pendingRate: Double = 0
        var began = DispatchTime.now()
        /// Milliseconds from the start call to the first audio.
        var liveAfter: Double?
        /// Milliseconds from the start call to the lead taking over from the bridge.
        var handoverAfter: Double?
        var overlapMilliseconds: Double = 0
    }

    private let lock = NSLock()
    private var state = State()

    /// How long ago audio last arrived, or nil if none has since capture started.
    /// This is what makes "the microphone went deaf" observable at all.
    var secondsSinceLastBuffer: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        guard state.lastBufferAt > 0 else { return nil }
        return Date().timeIntervalSinceReferenceDate - state.lastBufferAt
    }

    // MARK: - Start

    /// Begin recording. `completion` reports `nil` the moment the first audio is
    /// being kept — with a bridge that is about 40 ms after the call — or the
    /// reason nothing could be started. `onBuffer` receives 16 kHz mono in
    /// blocks of about 80 ms, for the VAD; the recording itself is fetched with
    /// `takeRecording()`.
    func startCapture(
        onBuffer: @escaping @Sendable ([Float]) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void,
        completion: @escaping @Sendable (AudioCaptureError?) -> Void
    ) {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        logger.debug("Mic permission status: \(status.rawValue, privacy: .public)")
        if status == .denied || status == .restricted { completion(.microphoneDenied); return }
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                logger.debug("Mic permission granted: \(granted, privacy: .public)")
            }
            completion(.microphoneDenied); return
        }

        let preferredUID = preferredDeviceUID
        let startTimes = startTimes
        lock.lock()
        let unanswered = state.report
        let run = state.run + 1
        state = State()
        state.run = run
        state.capturing = true
        state.report = completion
        state.sinks = Sinks(onBuffer: onBuffer, onLevel: onLevel)
        lock.unlock()
        unanswered?(.startFailed)   // a start nobody waited for still gets its answer

        controlQueue.async { [self] in start(run: run, preferredUID: preferredUID, startTimes: startTimes) }
    }

    private func start(run: Int, preferredUID: String?, startTimes: [String: Double]) {
        closeAll()   // nothing of an earlier recording stays open
        let snapshot = AudioDeviceResolver.snapshot()
        let candidates = AudioDeviceResolver.candidates(preferredUID: preferredUID, in: snapshot, startTimes: startTimes)
        guard !candidates.isEmpty else {
            // No input at all: say so instead of a generic error nobody can act on.
            logger.error("Start refused: no usable audio input device")
            fail(run, .noInputDevice)
            return
        }

        let now = Date().timeIntervalSinceReferenceDate
        let passedOver = AudioDeviceResolver.activeFailures(failures, now: now, fingerprint: snapshot.fingerprint)
        failures.removeAll { !passedOver.contains($0.uid) }   // stale or outdated: forget
        let order = AudioDeviceResolver.attemptOrder(candidates, excluding: passedOver)

        // The Mac's own microphone first, when it is not the one to record with:
        // it is live an order of magnitude sooner than anything on a cable.
        let bridge = AudioDeviceResolver.bridge(in: order)
        let bridgeStream = bridge.flatMap { openStream(on: $0.device, run: run, asBridge: true) }

        var attempts = 0
        var failed: [AudioDeviceResolver.Resolution] = []
        var winner: (resolution: AudioDeviceResolver.Resolution, stream: DeviceInputStream)?
        for candidate in order {
            guard isCurrent(run) else { break }
            let stream: DeviceInputStream?
            if let bridge, candidate.device.uid == bridge.device.uid {
                // Everything ranked ahead of it failed: the recording stays on
                // the microphone it has been running on since the first moment.
                stream = bridgeStream.flatMap { delivers($0, run: run) ? $0 : nil }
                if let stream {
                    promoteBridge(stream)
                } else if let bridgeStream {
                    dismissBridge(bridgeStream)
                }
            } else {
                attempts += 1
                stream = attempt(candidate.device, run: run)
            }
            if let stream {
                winner = (candidate, stream)
                break
            }
            guard isCurrent(run) else { break }   // stopped, not failed: nothing to hold against the device
            failed.append(candidate)
            failures.append(.init(uid: candidate.device.uid, at: now, fingerprint: snapshot.fingerprint))
        }

        guard isCurrent(run) else {
            closeAll()   // stopped while starting: nothing to report, nothing to keep open
            return
        }
        guard let winner else {
            closeAll()
            logger.error("No microphone could be started (\(order.count, privacy: .public) attempts)")
            fail(run, .startFailed)
            return
        }

        // The lead delivers: the bridge has done its part.
        if let bridgeStream, bridgeStream !== winner.stream { dismissBridge(bridgeStream) }
        failures.removeAll { $0.uid == winner.resolution.device.uid }   // it works: no reason to pass it over

        // Failed just now OR passed over because it failed a moment ago: both
        // mean "this recording is not on the microphone you would expect".
        let unusable = Set(failed.map(\.device.uid)).union(passedOver)
        let failedNames = AudioDeviceResolver.outranked(by: winner.resolution.device, in: candidates, unusable: unusable)
        let deviceStart = winner.stream.startMilliseconds ?? 0

        lock.lock()
        let liveAfter = state.liveAfter ?? Self.milliseconds(since: state.began)
        let handoverAfter = state.handoverAfter
        let overlap = state.overlapMilliseconds
        lock.unlock()

        // One line per start, in the build people actually run: the only honest
        // record of how long "press to live" takes and why.
        var bridged = ""
        if let bridge, let handoverAfter {
            bridged = ", bridged by \(bridge.device.name) until \(Int(handoverAfter.rounded())) ms (overlap \(Int(overlap.rounded())) ms)"
        }
        logger.info("""
            Start \(liveAfter, format: .fixed(precision: 0), privacy: .public) ms on \(winner.resolution.device.name, privacy: .public) \
            (\(winner.resolution.source.rawValue, privacy: .public)) — device start \(deviceStart, format: .fixed(precision: 0), privacy: .public), \
            attempts \(attempts, privacy: .public)\(bridged, privacy: .public)
            """)
        if !failedNames.isEmpty {
            logger.error("Fell back to \(winner.resolution.device.name, privacy: .public) — did not start: \(failedNames.joined(separator: ", "), privacy: .public)")
        }
        onStarted?(CaptureStartInfo(device: winner.resolution.device, source: winner.resolution.source,
                                    failedNames: failedNames, startMilliseconds: deviceStart))
    }

    /// One attempt to make `device` the microphone of this recording. Returns
    /// its stream once it has delivered audio, nil otherwise. controlQueue only.
    private func attempt(_ device: AudioDevice, run: Int) -> DeviceInputStream? {
        #if DEBUG
        if failNextStartForTesting {
            failNextStartForTesting = false
            logger.error("\(device.name, privacy: .public) did not start (injected for a test)")
            return nil
        }
        #endif
        guard let stream = openStream(on: device, run: run, asBridge: false) else { return nil }
        if delivers(stream, run: run) { return stream }

        lock.lock()
        // It may have delivered in the very moment the wait gave up.
        let deliveredAfterAll = state.lead === stream && state.leadPiece != nil
        if !deliveredAfterAll, state.lead === stream { state.lead = nil }
        lock.unlock()
        if deliveredAfterAll { return stream }
        close(stream)
        return nil
    }

    /// Open `device` and route its buffers into this recording. controlQueue only.
    private func openStream(on device: AudioDevice, run: Int, asBridge: Bool) -> DeviceInputStream? {
        guard let stream = DeviceInputStream(device: device) else {
            logger.error("\(device.name, privacy: .public) reports no usable input format")
            return nil
        }
        lock.lock()
        if asBridge { state.bridge = stream } else { state.lead = stream }
        lock.unlock()
        open.append(stream)
        let started = stream.start(on: ioQueue) { [weak self, weak stream] samples, hostTime in
            guard let self, let stream else { return }
            self.receive(samples, at: hostTime, from: stream, run: run)
        }
        if started { return stream }
        lock.lock()
        if state.bridge === stream { state.bridge = nil }
        if state.lead === stream { state.lead = nil }
        lock.unlock()
        close(stream)
        return nil
    }

    /// Wait for the first buffer, in short slices so a stop does not have to
    /// sit out a Bluetooth timeout before the next recording can start.
    private func delivers(_ stream: DeviceInputStream, run: Int) -> Bool {
        let limit = stream.device.isBluetooth ? Self.firstBufferLimitBluetooth : Self.firstBufferLimit
        let deadline = DispatchTime.now() + limit
        while DispatchTime.now() < deadline {
            if stream.waitForFirstBuffer(timeout: 0.05) { return true }
            if !isCurrent(run) { return false }
        }
        logger.error("\(stream.device.name, privacy: .public) started but delivered no audio within \(limit, privacy: .public) s")
        return false
    }

    /// Nothing ranked ahead of the bridge delivered, so the bridge is the
    /// microphone of this recording, and what it recorded is the recording.
    private func promoteBridge(_ stream: DeviceInputStream) {
        lock.lock()
        state.lead = stream
        state.leadPiece = state.bridgePiece
        state.bridge = nil
        state.bridgePiece = nil
        lock.unlock()
    }

    /// The bridge is no longer needed, or never delivered. What it recorded
    /// before the hand-over stays part of the recording.
    private func dismissBridge(_ stream: DeviceInputStream) {
        lock.lock()
        if state.bridge === stream { state.bridge = nil }
        lock.unlock()
        close(stream)
    }

    private func isCurrent(_ run: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return state.run == run && state.capturing
    }

    private func fail(_ run: Int, _ error: AudioCaptureError) {
        lock.lock()
        guard state.run == run else { lock.unlock(); return }
        state.capturing = false
        let report = state.report
        state.report = nil
        lock.unlock()
        report?(error)
    }

    private func close(_ stream: DeviceInputStream) {
        stream.stop()
        open.removeAll { $0 === stream }
    }

    private func closeAll() {
        open.forEach { $0.stop() }
        open.removeAll()
    }

    private static func milliseconds(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    // MARK: - Stop and hand over

    /// Stop recording and give every device back. What was recorded stays until
    /// it is fetched or the next recording starts.
    func stopCapture() {
        lock.lock()
        state.run += 1
        state.capturing = false
        state.lead = nil
        state.bridge = nil
        state.sinks = nil
        let unanswered = state.report
        state.report = nil
        lock.unlock()
        unanswered?(.startFailed)
        controlQueue.async { [self] in closeAll() }
    }

    /// Everything recorded since the last hand-over (the WHOLE recording if no
    /// segment was cut), as 16 kHz mono. Hands the storage over and starts empty.
    func takeRecording() -> (samples: [Float], rate: Double) {
        lock.lock()
        var parts: [(samples: [Float], rate: Double)] = []
        if let rate = state.bridgePiece?.rate, let samples = state.bridgePiece?.take() { parts.append((samples, rate)) }
        if let rate = state.leadPiece?.rate, let samples = state.leadPiece?.take() { parts.append((samples, rate)) }
        lock.unlock()
        return (Self.assemble(parts), 16_000)
    }

    /// Mid-recording: hand over the finished segment for background
    /// transcription. The samples are never read again after that, so they are
    /// released here instead of staying in memory until the recording ends.
    func takeSegment() -> (samples: [Float], rate: Double) {
        takeRecording()
    }

    /// The pieces of one recording as a single 16 kHz signal. Each piece is
    /// converted in ONE pass: converting buffer by buffer warms the filter up
    /// again every time and garbles short clips.
    static func assemble(_ parts: [(samples: [Float], rate: Double)]) -> [Float] {
        let converted = parts.filter { !$0.samples.isEmpty }
            .map { TranscriptionService.resample($0.samples, from: $0.rate) }
        return converted.count == 1 ? converted[0] : converted.flatMap { $0 }
    }

    // MARK: - Audio arriving (ioQueue)

    private func receive(_ samples: [Float], at hostTime: UInt64, from stream: DeviceInputStream, run: Int) {
        lock.lock()
        guard state.run == run, state.capturing else { lock.unlock(); return }

        if stream === state.lead {
            if state.leadPiece == nil {
                state.leadPiece = CapturePiece(rate: stream.sampleRate)
                // The hand-over: from this buffer on the recording is the lead's.
                // What the bridge holds from the same moment on is said twice.
                if let bridgeRate = state.bridgePiece?.rate, let dropped = state.bridgePiece?.cut(at: hostTime) {
                    state.overlapMilliseconds = Double(dropped) / bridgeRate * 1000
                    state.handoverAfter = Self.milliseconds(since: state.began)
                }
            }
            state.leadPiece?.append(samples, at: hostTime)
            state.leadPiece?.keepLast(seconds: Self.maxSeconds, slack: Self.trimSlack)
        } else if stream === state.bridge, state.leadPiece == nil {
            if state.bridgePiece == nil { state.bridgePiece = CapturePiece(rate: stream.sampleRate) }
            state.bridgePiece?.append(samples, at: hostTime)
        } else {
            lock.unlock()
            return
        }

        state.lastBufferAt = Date().timeIntervalSinceReferenceDate
        var report: (@Sendable (AudioCaptureError?) -> Void)?
        if state.liveAfter == nil {
            state.liveAfter = Self.milliseconds(since: state.began)
            report = state.report
            state.report = nil
        }

        // Level meter and VAD get blocks of about 80 ms, not every IO cycle: a
        // device hands over a buffer roughly every 10 ms.
        let rate = stream.sampleRate
        if state.pendingRate != rate {
            state.pending.removeAll(keepingCapacity: true)
            state.pendingRate = rate
        }
        state.pending.append(contentsOf: samples)
        var block: [Float]?
        if state.pending.count >= Int(rate / 12) {
            block = state.pending
            state.pending = []
        }
        let sinks = state.sinks
        lock.unlock()

        report?(nil)
        if let block, let sinks {
            liveQueue.async { [self] in emit(block, rate: rate, to: sinks, run: run) }
        }
    }

    /// One block for the level meter and the VAD, as 16 kHz. liveQueue only.
    private func emit(_ block: [Float], rate: Double, to sinks: Sinks, run: Int) {
        guard isCurrent(run) else { return }
        let converted = downsampler.convert(block, rate: rate)
        guard !converted.isEmpty else { return }
        // Several levels per block so the meter scrolls instead of stepping.
        let windowLength = max(1, converted.count / 4)
        converted.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            var offset = 0
            while offset < converted.count {
                let length = min(windowLength, converted.count - offset)
                var rms: Float = 0
                vDSP_rmsqv(base + offset, 1, &rms, vDSP_Length(length))
                // dB-like scale tuned for laptop mic speech: -55 dB floor, -15 dB ceiling.
                let db = 20 * log10(max(rms, 1e-6))
                sinks.onLevel(min(max((db + 55) / 40, 0), 1.0))
                offset += length
            }
        }
        sinks.onBuffer(converted)
    }
}

/// Converts the running audio to 16 kHz block by block, for the level meter and
/// the VAD only. Both tolerate what a streaming converter does at block edges;
/// the recording itself is converted in one pass at the end.
private final class LiveDownsampler {
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var source: AVAudioFormat?
    private var converter: AVAudioConverter?

    func convert(_ samples: [Float], rate: Double) -> [Float] {
        guard rate != target.sampleRate else { return samples }
        if source?.sampleRate != rate {
            source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)
            converter = source.flatMap { AVAudioConverter(from: $0, to: target) }
        }
        let capacity = AVAudioFrameCount((Double(samples.count) * target.sampleRate / rate).rounded(.up)) + 64
        guard let source, let converter, !samples.isEmpty,
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity),
              let inputData = input.floatChannelData
        else { return [] }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { inputData[0].update(from: $0.baseAddress!, count: samples.count) }

        // Hand the converter this block EXACTLY ONCE. Returning it again when the
        // converter asks for more (it does, while priming its filter) duplicates
        // audio; `.noDataNow` lets it keep its state for the next block.
        var error: NSError?
        var provided = false
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if provided {
                outStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error, error == nil, output.frameLength > 0, let data = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }
}

enum AudioCaptureError: Error, LocalizedError, Equatable {
    case microphoneDenied
    case startFailed
    case noInputDevice

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: "Microphone access is denied"
        case .startFailed: "No microphone could be started"
        case .noInputDevice: "No microphone found"
        }
    }
}
