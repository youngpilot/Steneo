import AVFoundation
import Accelerate
import AudioToolbox
import CoreAudio
import os

private let logger = Logger(subsystem: "com.youngpilot.Steneo", category: "AudioCapture")

/// What a successful start ended up on — so a fallback is something the app can
/// say out loud instead of something that silently happened.
struct CaptureStartInfo: Equatable, Sendable {
    let device: AudioDevice
    let source: AudioDeviceResolver.Source
    /// Devices that were tried first and did not start, in order.
    let failedNames: [String]
}

/// Captures microphone audio as 16 kHz mono for the ASR.
///
/// THE RULE, since 1.4.3: while no recording is running, this class holds NO
/// audio resources at all. No engine warm-up, no installed tap, no open device.
/// It builds everything at `startCapture()` and throws it away at
/// `stopCapture()`.
///
/// That is not tidiness. Merely touching `engine.inputNode` makes CoreAudio
/// select and open an input device, and Steneo used to keep one open for as
/// long as it was running. The price is paid at the start of every recording:
/// measured on 19.11.2026 at about 615 ms from shortcut to live microphone, not
/// the 200 ms this comment used to promise. Every start now logs where that
/// time went, so the next cut is made on numbers.
///
/// STARTING, since 1.6: a start walks an ordered list of microphones — chosen
/// device, system default, the Mac's own, anything else — until one actually
/// starts AND delivers a first buffer. "The right device" can be present and
/// still refuse to start; that used to end the recording before it began.
///
/// THREADING: every AVAudioEngine operation (prepare / tap install / start /
/// stop) runs on the single serial `engineQueue`. AVAudioEngine is not
/// thread-safe — mixing main-thread tap-install with a background-thread start
/// scrambles/drops the first buffers (the 55461fa regression). One queue, always.
final class AudioCaptureService: @unchecked Sendable {
    /// Replaceable, but no longer the actual defence.
    ///
    /// Until 1.4.3 this class let AVAudioEngine pick the input device implicitly,
    /// which means the engine remembers an `AudioDeviceID` — a transient handle.
    /// After a USB re-enumeration that number points at nothing, the engine falls
    /// back to a device without an input, and every start fails. Rebuilding the
    /// engine did not help, because the replacement asked for the same dead
    /// number: on 04.09.2026 that loop ran at nine rebuilds per second for over
    /// four hours. The fix is `select(_:)` — name the device explicitly,
    /// by its stable UID, before anything reads a format. Rebuilding is now only
    /// what it should always have been: a response to a REAL change.
    private var engine = AVAudioEngine()
    private let engineQueue = DispatchQueue(label: "com.youngpilot.Steneo.audioengine", qos: .userInitiated)
    private var configObserver: NSObjectProtocol?

    #if DEBUG
    /// Makes the next `engine.start()` fail, so the recovery path can be tested
    /// for real instead of hoping a device change reproduces the wedge.
    var failNextStartForTesting = false
    /// Counts input-chain rebuilds. The bug was never "a rebuild happened", it
    /// was "1727 rebuilds happened" — so the test has to be able to count.
    private(set) var rebuildCountForTesting = 0
    /// Lets a test make every notification look like a real device change,
    /// which is the one condition a healthy Mac will not produce on demand.
    var signatureOverrideForTesting: (@Sendable () -> String)?
    /// Whether an input chain exists at all. A test that means to exercise
    /// rebuilding has to know its priming worked, or a silent no-op reads as a
    /// pass for the wrong reason.
    /// Builds an input chain on purpose. Production never does this outside a
    /// recording — that is the point of 1.4.3 — but a test that means to
    /// exercise rebuilding needs something to rebuild.
    ///
    /// Asynchronous, and NOT `engineQueue.sync`: building a chain touches
    /// `engine.inputNode`, which dispatches to the main queue, so a caller that
    /// blocks the main thread waiting on this queue deadlocks.
    func primeInputChainForTesting(completion: @escaping @Sendable (Bool) -> Void) {
        engineQueue.async { [self] in
            completion(buildChainForCurrentInput())
        }
    }
    #endif
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    private var converter: AVAudioConverter?
    private var tapFormat: AVAudioFormat?
    private var active = false

    /// The device the user picked, by UID. `nil` means "follow the system
    /// default", which is where macOS users already manage their microphone.
    /// Written before a recording starts, read on `engineQueue`.
    var preferredDeviceUID: String?

    /// Brake, fuse and precondition for configuration-change notifications.
    /// engineQueue only.
    private var rebuildPolicy = AudioEngineRebuildPolicy()
    /// The input signature the current tap was built for. engineQueue only.
    private var builtSignature: String?
    /// So a blown fuse is reported once, not on every further notification.
    private var reportedInputUnavailable = false
    /// Reported when the fuse blows or no input device exists at all — so the
    /// failure is visible instead of being a microphone that quietly does nothing.
    var onInputUnavailable: (@Sendable (String) -> Void)?
    /// Reported on every successful start: which microphone, and what was
    /// passed over to get there.
    var onStarted: (@Sendable (CaptureStartInfo) -> Void)?

    /// Devices that recently refused to start. Passed over while the hardware
    /// looks the same, so a broken device costs its timeout once, not at every
    /// recording. engineQueue only.
    private var failures: [AudioDeviceResolver.Failure] = []
    /// Where the time of the current start went, in milliseconds. engineQueue only.
    private var timing = StartTiming()
    private struct StartTiming {
        var attempts = 0
        var select = 0.0, tap = 0.0, prepare = 0.0, engine = 0.0, firstBuffer = 0.0
    }
    /// A started engine that delivers nothing is not a start. How long a device
    /// gets to produce its first buffer: wired devices answer within ~100 ms,
    /// Bluetooth has to switch profiles first.
    private static let firstBufferLimit: TimeInterval = 0.7
    private static let firstBufferLimitBluetooth: TimeInterval = 2.5

    // Raw recorded audio (ch0, at the input sample rate) for ONE clean conversion
    // at stop — per-buffer resampling warms its filter each clip and garbles short
    // ones. All access serialized on engineQueue (no render-thread lock).
    /// When the last buffer reached the tap. Written on the render thread and
    /// read from the main actor, so it gets its own small lock rather than
    /// `engineQueue` — a `sync` onto that queue from the main actor would block
    /// behind whatever engine work is queued.
    private let heartbeatLock = NSLock()
    private var lastBufferAt: TimeInterval = 0
    /// Signalled by the tap when the first buffer of a start arrives. Guarded by
    /// `heartbeatLock`.
    private var firstBufferSignal: DispatchSemaphore?

    /// How long ago audio last arrived, or nil if none has since capture started.
    /// This is what makes "the microphone went deaf" observable at all.
    var secondsSinceLastBuffer: TimeInterval? {
        heartbeatLock.lock()
        defer { heartbeatLock.unlock() }
        guard lastBufferAt > 0 else { return nil }
        return Date().timeIntervalSinceReferenceDate - lastBufferAt
    }

    // The raw recording is guarded by its OWN lock, deliberately not by
    // `engineQueue`. Reading it used to be `engineQueue.sync` from the main actor,
    // and `engineQueue` touches `engine.inputNode` — whose first access dispatches
    // SYNCHRONOUSLY to the main queue. Main waits for the queue, the queue waits
    // for main, and the app is gone. Found by a hung test on 04.09.2026, and
    // reachable in the product whenever a device change rebuilds the engine while
    // a segment cut or a stop reads the buffer.
    private let bufferLock = NSLock()
    private var rawRecording: [Float] = []
    private var rawRate: Double = 0
    private static let maxRaw = 48_000 * 60 * 10   // ~10 min @ 48 kHz cap
    /// Trim back to the cap only once this far over it. Trimming on every buffer
    /// moved 115 MB twelve times a second once a recording passed ten minutes.
    private static let trimSlack = 48_000 * 5

    // Per-recording sinks; the tap forwards to them only while `active`.
    private var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var onLevel: (@Sendable (Float) -> Void)?

    init() {
        // Fires when the input or output hardware changes under us (device
        // plugged in, default input switched, sample rate changed). Registered
        // for any engine rather than a specific one, so it keeps working after a
        // rebuild replaces the instance.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil
        ) { [weak self] note in
            // Identity only: `Notification.object` is not Sendable, and comparing
            // it on this thread would race with a rebuild replacing `engine`.
            // `ObjectIdentifier` is a value, and the comparison happens on
            // engineQueue where `engine` is stable.
            let sender = (note.object as AnyObject?).map(ObjectIdentifier.init)
            self?.handleConfigurationChange(from: sender)
        }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    private func handleConfigurationChange(from sender: ObjectIdentifier?) {
        engineQueue.async { [self] in
            // A notification from an engine we already threw away says nothing
            // about the engine we are using now. Registering with `object: nil`
            // used to let those through, which multiplied every storm.
            // A nil sender is a manual/test post and always applies.
            if let sender, sender != ObjectIdentifier(engine) { return }
            // Nothing is built and nothing is recording: there is no input chain
            // to rebuild. The next start builds one against the hardware as it is
            // then, which is strictly better than guessing now.
            if builtSignature == nil, !active { return }

            let signature = currentInputSignature()
            let changed = signature != builtSignature
            let decision = rebuildPolicy.decide(at: Date().timeIntervalSinceReferenceDate,
                                                signatureChanged: changed)
            switch decision {
            case .unchanged, .tooSoon:
                // Deliberately debug, not info: this is the case that produced
                // 1727 log lines in ten minutes and evicted twelve hours of
                // diagnostics from the unified log.
                logger.debug("Configuration change ignored (\(String(describing: decision), privacy: .public))")
                return
            case .circuitOpen:
                guard !reportedInputUnavailable else { return }
                reportedInputUnavailable = true
                logger.error("Audio input keeps reconfiguring — giving up until the next successful start")
                onInputUnavailable?("Audio input is unstable — check your microphone")
                return
            case .rebuild:
                break
            }

            failures.removeAll()   // the hardware really changed: every device gets a fresh chance
            let wasCapturing = active
            logger.info("Audio input changed to \(signature, privacy: .public) (capturing: \(wasCapturing, privacy: .public)) — rebuilding")
            rebuildEngine()
            guard wasCapturing else { return }
            // Mid-recording: bring the mic straight back up on the new device
            // instead of leaving a live recording deaf.
            do {
                engine.prepare()
                try engine.start()
                logger.info("Capture resumed on the new input device")
            } catch {
                // No second mechanism needed: with the engine down no buffers
                // arrive, and the watchdog ends the recording within two seconds
                // instead of leaving a red icon over a dead microphone.
                logger.error("Could not resume capture after the device change: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// What the input looks like RIGHT NOW, read from CoreAudio rather than from
    /// the engine. The engine is exactly the thing that goes stale, so asking it
    /// whether it is stale cannot work.
    private func currentInputSignature() -> String {
        #if DEBUG
        if let signatureOverrideForTesting { return signatureOverrideForTesting() }
        #endif
        return AudioDeviceResolver.current(preferredUID: preferredDeviceUID)?.device.signature ?? "no-input"
    }

    /// Name the input device explicitly, before anything reads a format.
    ///
    /// The engine never chooses: it used to remember a transient device number,
    /// and a number that went stale took recording down with it. engineQueue
    /// only, engine stopped. Returns false when the device cannot be selected —
    /// the caller moves on to the next one instead of recording on a guess.
    private func select(_ device: AudioDevice) -> Bool {
        guard let unit = engine.inputNode.audioUnit else {
            logger.error("Input node has no audio unit — cannot select \(device.name, privacy: .public)")
            return false
        }
        var deviceID = device.id
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            logger.error("Could not select \(device.name, privacy: .public): OSStatus \(status, privacy: .public)")
            return false
        }
        return true
    }

    /// Build the input chain for ONE device on the current engine: select it,
    /// read the format the hardware really has, install the tap. engineQueue
    /// only, engine stopped.
    private func buildChain(for device: AudioDevice) -> Bool {
        let began = DispatchTime.now()
        guard select(device) else { return false }
        timing.select += Self.milliseconds(since: began)
        let tapBegan = DispatchTime.now()
        let input = engine.inputNode
        // `inputFormat`, NOT `outputFormat`. Selecting the device renegotiates the
        // hardware — a microphone the system was running at 44.1 kHz comes back at
        // 48 kHz — while `outputFormat` keeps returning the value the node cached
        // BEFORE the device was set. A tap installed with that stale format is
        // never called: AVFoundation's own precondition is
        // `format.sampleRate == inputHWFormat.sampleRate`, and it fails silently.
        // Measured 04.09.2026: tap 44100 against hardware 48000 gave 0 frames in a
        // second, where the hardware format gave 48000.
        let hardwareFormat = input.inputFormat(forBus: 0)
        let inputFormat = hardwareFormat.sampleRate > 0 ? hardwareFormat : input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            logger.error("\(device.name, privacy: .public) reports no usable input format")
            return false
        }
        input.removeTap(onBus: 0)
        guard let conv = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            logger.error("Failed to create audio converter for \(device.name, privacy: .public)")
            converter = nil
            tapFormat = nil
            return false
        }
        converter = conv
        tapFormat = inputFormat
        builtSignature = device.signature
        let target = targetFormat
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.handleTap(buffer, inputFormat: inputFormat, targetFormat: target)
        }
        timing.tap += Self.milliseconds(since: tapBegan)
        return true
    }

    /// The chain for whatever the first candidate is right now. Used when the
    /// hardware changes under a running recording; a start walks the whole list.
    @discardableResult
    private func buildChainForCurrentInput() -> Bool {
        guard let resolution = AudioDeviceResolver.current(preferredUID: preferredDeviceUID) else {
            logger.error("No usable audio input device")
            return false
        }
        return buildChain(for: resolution.device)
    }

    private static func milliseconds(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    /// Throws away the engine and every cached format, and builds the input chain
    /// again against the hardware as it is NOW. engineQueue only.
    private func rebuildEngine() {
        #if DEBUG
        rebuildCountForTesting += 1
        #endif
        if engine.isRunning { engine.stop() }
        if converter != nil { engine.inputNode.removeTap(onBus: 0) }
        engine = AVAudioEngine()
        converter = nil
        tapFormat = nil
        builtSignature = nil
        buildChainForCurrentInput()
    }

    /// Begin forwarding mic audio to the sinks. All engine I/O runs on
    /// `engineQueue` (off the main thread, but always the SAME thread). The audio
    /// engine start (~HAL setup) is the only unavoidable latency before the mic is
    /// live — there's no always-on mic. `completion` reports `nil` on success
    /// (engine live → capturing) or an error; the caller hops it to the main actor
    /// and only then flips into the recording state (red == recording).
    func startCapture(
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
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

        self.onBuffer = onBuffer
        self.onLevel = onLevel

        engineQueue.async { [self] in
            let began = DispatchTime.now()
            timing = StartTiming()
            let snapshot = AudioDeviceResolver.snapshot()
            let candidates = AudioDeviceResolver.candidates(preferredUID: preferredDeviceUID, in: snapshot)
            guard !candidates.isEmpty else {
                // No input at all: say so instead of failing with a generic
                // engine error the user cannot act on.
                logger.error("Start refused: no usable audio input device")
                active = false
                completion(.noInputDevice)
                return
            }
            let resolved = Self.milliseconds(since: began)

            let now = Date().timeIntervalSinceReferenceDate
            let passedOver = AudioDeviceResolver.activeFailures(failures, now: now, fingerprint: snapshot.fingerprint)
            failures.removeAll { !passedOver.contains($0.uid) }   // stale or outdated: forget
            let order = AudioDeviceResolver.attemptOrder(candidates, excluding: passedOver)

            let outcome = AudioDeviceResolver.firstWorking(order) { candidate in
                if attemptStart(on: candidate.device) { return true }
                failures.append(.init(uid: candidate.device.uid, at: now, fingerprint: snapshot.fingerprint))
                return false
            }
            guard let outcome else {
                active = false
                logger.error("No microphone could be started (\(order.count, privacy: .public) attempts)")
                completion(.engineStartFailed)
                return
            }

            let winner = order[outcome.index]
            failures.removeAll { $0.uid == winner.device.uid }   // it works: no reason to pass it over
            // The input works — put the fuse back in, so one bad stretch doesn't
            // disable recovery for the rest of the app's life.
            rebuildPolicy.reset()
            reportedInputUnavailable = false

            // Failed just now OR passed over because it failed a moment ago: both
            // mean "this recording is not on the microphone you would expect".
            let unusable = Set(outcome.failed.map(\.device.uid)).union(passedOver)
            let failedNames = AudioDeviceResolver.outranked(by: winner.device, in: candidates, unusable: unusable)
            // One line per start, in the build people actually run: this is the
            // only honest record of how long "press to live" takes and why.
            let total = Self.milliseconds(since: began)
            logger.info("""
                Start \(total, format: .fixed(precision: 0), privacy: .public) ms on \(winner.device.name, privacy: .public) \
                (\(winner.source.rawValue, privacy: .public)) — resolve \(resolved, format: .fixed(precision: 0), privacy: .public), \
                select \(self.timing.select, format: .fixed(precision: 0), privacy: .public), \
                tap \(self.timing.tap, format: .fixed(precision: 0), privacy: .public), \
                prepare \(self.timing.prepare, format: .fixed(precision: 0), privacy: .public), \
                engine start \(self.timing.engine, format: .fixed(precision: 0), privacy: .public), \
                first buffer \(self.timing.firstBuffer, format: .fixed(precision: 0), privacy: .public), \
                attempts \(self.timing.attempts, privacy: .public)
                """)
            if !failedNames.isEmpty {
                logger.error("Fell back to \(winner.device.name, privacy: .public) — did not start: \(failedNames.joined(separator: ", "), privacy: .public)")
            }
            onStarted?(CaptureStartInfo(device: winner.device, source: winner.source, failedNames: failedNames))
            completion(nil)
        }
    }

    /// One attempt on one device, from a bare engine: build the chain, start,
    /// and wait for the first buffer. A started engine that delivers nothing is
    /// not a start — it is the deaf microphone the watchdog would otherwise
    /// need two seconds of a live recording to notice. engineQueue only.
    private func attemptStart(on device: AudioDevice) -> Bool {
        timing.attempts += 1
        releaseEngine()
        guard buildChain(for: device) else { releaseEngine(); return false }

        bufferLock.lock()
        rawRecording = []
        rawRate = 0
        bufferLock.unlock()
        let firstBuffer = DispatchSemaphore(value: 0)
        heartbeatLock.lock()
        lastBufferAt = 0
        firstBufferSignal = firstBuffer
        heartbeatLock.unlock()

        active = true
        let prepareBegan = DispatchTime.now()
        engine.prepare()
        timing.prepare += Self.milliseconds(since: prepareBegan)
        let engineBegan = DispatchTime.now()
        do {
            #if DEBUG
            if failNextStartForTesting {
                failNextStartForTesting = false
                throw NSError(domain: NSOSStatusErrorDomain, code: -10868)
            }
            #endif
            try engine.start()
        } catch {
            logger.error("\(device.name, privacy: .public) did not start: \(error.localizedDescription, privacy: .public)")
            active = false
            releaseEngine()
            return false
        }
        timing.engine += Self.milliseconds(since: engineBegan)

        let waitBegan = DispatchTime.now()
        let limit = device.isBluetooth ? Self.firstBufferLimitBluetooth : Self.firstBufferLimit
        guard firstBuffer.wait(timeout: .now() + limit) == .success else {
            logger.error("\(device.name, privacy: .public) started but delivered no audio within \(limit, privacy: .public) s")
            active = false
            releaseEngine()
            return false
        }
        timing.firstBuffer += Self.milliseconds(since: waitBegan)
        return true
    }

    func stopCapture() {
        active = false   // stop forwarding immediately (handleTap guards on this)
        engineQueue.async { [self] in
            releaseEngine()
        }
    }

    /// Give the audio device back. Stopping the engine is not enough: the input
    /// node keeps its audio unit, its ioproc and its device selection, so the
    /// device stays open and a Bluetooth headset stays in call mode. Discarding
    /// the engine releases all of it.
    ///
    /// Note the difference to `rebuildEngine()`: that one builds a new input
    /// chain immediately. This one builds NOTHING — a bare `AVAudioEngine` has
    /// touched no hardware until someone asks for its `inputNode`, and the next
    /// `startCapture()` is what asks.
    private func releaseEngine() {
        if engine.isRunning { engine.stop() }
        // Only if we actually installed one: asking a fresh engine for its
        // `inputNode` just to remove a tap that was never there would open a
        // device — the exact thing this method exists to avoid.
        if converter != nil { engine.inputNode.removeTap(onBus: 0) }
        engine = AVAudioEngine()
        converter = nil
        tapFormat = nil
        builtSignature = nil
    }

    /// Everything recorded since the last hand-over (the WHOLE recording if no
    /// segment was cut) + its rate, for the final single-shot conversion at stop.
    /// Hands the storage over instead of copying it, and starts an empty buffer.
    func takeRecording() -> (samples: [Float], rate: Double) {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        let samples = rawRecording
        rawRecording = []
        return (samples, rawRate)
    }

    /// Mid-recording: hand over the finished segment for background
    /// transcription. The samples are never read again after that, so they are
    /// released here — they used to stay in memory until the recording ended,
    /// up to 115 MB at ten minutes.
    func takeSegment() -> (samples: [Float], rate: Double) {
        takeRecording()
    }

    private func handleTap(_ buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat, targetFormat: AVAudioFormat) {
        guard active, let conv = converter else { return }
        heartbeatLock.lock()
        let isFirst = lastBufferAt == 0
        lastBufferAt = Date().timeIntervalSinceReferenceDate
        let firstBuffer = isFirst ? firstBufferSignal : nil
        heartbeatLock.unlock()
        firstBuffer?.signal()   // the start is waiting for exactly this
        // Generous output capacity (round up + headroom) so the resampler output is
        // never truncated.
        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let frameCapacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else { return }

        // CRITICAL: hand the resampler this input buffer EXACTLY ONCE. The old code
        // returned `buffer` on every input-block call, so when the resampler asked
        // for more input (e.g. while priming its filter) it got the SAME buffer
        // again → duplicated/garbled audio, worst at the start of a clip (so short
        // clips came out mangled like "to tst wi siht's aus"). Return .noDataNow
        // after the first hand-off; the converter keeps its filter state for the
        // next call, giving a clean, continuous stream.
        var error: NSError?
        var didProvide = false
        let status = conv.convert(to: converted, error: &error) { _, outStatus in
            if didProvide {
                outStatus.pointee = .noDataNow
                return nil
            }
            didProvide = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, converted.frameLength > 0 else { return }

        if let floatData = converted.floatChannelData, let onLevel {
            let count = Int(converted.frameLength)
            if count > 0 {
                // Emit several sub-window levels per buffer (~16/sec at 4096-frame
                // taps) so the level meter scrolls smoothly instead of in ~4 steps.
                let subWindows = 4
                let windowLen = max(1, count / subWindows)
                var offset = 0
                while offset < count {
                    let len = min(windowLen, count - offset)
                    var rms: Float = 0
                    vDSP_rmsqv(floatData[0] + offset, 1, &rms, vDSP_Length(len))
                    // dB-like scale tuned for laptop mic speech.
                    let db = 20 * log10(max(rms, 1e-6))
                    let level = min(max((db + 55) / 40, 0), 1.0) // -55dB floor, -15dB ceiling
                    onLevel(level)
                    offset += len
                }
            }
        }
        onBuffer?(converted)

        // Accumulate the RAW input (ch0, at the input rate) for ONE clean
        // conversion at stop. Copy on the render thread (like `converted`),
        // append on engineQueue so all `rawRecording` access stays serialized.
        let rawCount = Int(buffer.frameLength)
        if let raw = buffer.floatChannelData, rawCount > 0 {
            let chunk = Array(UnsafeBufferPointer(start: raw[0], count: rawCount))
            // Under the buffer's own lock. This tap thread already allocates (the
            // copy above), so a short lock is cheaper than the queue hop it
            // replaces — and it keeps the buffer off `engineQueue`, which is what
            // made reading it from the main actor a deadlock.
            bufferLock.lock()
            rawRecording.append(contentsOf: chunk)
            rawRate = inputFormat.sampleRate
            if rawRecording.count > Self.maxRaw + Self.trimSlack {
                rawRecording.removeFirst(rawRecording.count - Self.maxRaw)
            }
            bufferLock.unlock()
        }
    }
}

enum AudioCaptureError: Error, LocalizedError, Equatable {
    case microphoneDenied
    case formatError
    case converterError
    case engineStartFailed
    case noInputDevice

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: "Microphone access is denied"
        case .formatError: "Failed to create audio format"
        case .converterError: "Failed to create audio converter"
        case .engineStartFailed: "Failed to start the audio engine"
        case .noInputDevice: "No microphone found"
        }
    }
}
