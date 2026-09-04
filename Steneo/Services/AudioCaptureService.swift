import AVFoundation
import Accelerate
import AudioToolbox
import CoreAudio
import os

private let logger = Logger(subsystem: "com.youngpilot.Steneo", category: "AudioCapture")

/// Captures microphone audio as 16 kHz mono for the ASR.
///
/// THE RULE, since 1.4.3: while no recording is running, this class holds NO
/// audio resources at all. No engine warm-up, no installed tap, no open device.
/// It builds everything at `startCapture()` and throws it away at
/// `stopCapture()`.
///
/// That is not tidiness. Merely touching `engine.inputNode` makes CoreAudio
/// select and open an input device — and an open input device forces a
/// Bluetooth headset out of high-quality playback into the mono call profile.
/// Steneo used to warm the engine at launch and keep it warm between
/// recordings, so simply having the app running degraded the user's AirPods.
/// Building on demand costs about 200 ms at the start of a recording, which is
/// exactly what the orange "arming" icon is for.
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
    /// four hours. The fix is `applyInputDevice()` — name the device explicitly,
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
    var hasInputChainForTesting: Bool { engineQueue.sync { builtSignature != nil } }
    /// Builds an input chain on purpose. Production never does this outside a
    /// recording — that is the point of 1.4.3 — but a test that means to
    /// exercise rebuilding needs something to rebuild.
    func primeInputChainForTesting() { engineQueue.sync { refreshTapIfNeeded() } }
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

    // Raw recorded audio (ch0, at the input sample rate) for ONE clean conversion
    // at stop — per-buffer resampling warms its filter each clip and garbles short
    // ones. All access serialized on engineQueue (no render-thread lock).
    private var rawRecording: [Float] = []
    private var rawRate: Double = 0
    private var segmentStart = 0   // index of the first sample not yet handed off to a segment cut
    private static let maxRaw = 48_000 * 60 * 10   // ~10 min @ 48 kHz cap

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

    /// Deliberately does nothing to the audio hardware.
    ///
    /// This used to install a tap and call `engine.prepare()` at launch. Both
    /// touch `inputNode`, which opens an input device and keeps it open for the
    /// life of the app — the reason a running Steneo could ruin Bluetooth
    /// playback without ever recording. The ~200 ms it saved is not worth
    /// holding someone's microphone open all day.
    func prepareEngine() {}

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
    /// This is the whole fix: the resolution runs fresh on every call and uses
    /// stable UIDs, so a device that came back with a new `AudioDeviceID` is
    /// found again, and a device that is gone falls through to the system
    /// default, then to the built-in microphone. engineQueue only, engine stopped.
    @discardableResult
    private func applyInputDevice() -> AudioDeviceResolver.Resolution? {
        guard let resolution = AudioDeviceResolver.current(preferredUID: preferredDeviceUID) else {
            logger.error("No usable audio input device")
            return nil
        }
        guard let unit = engine.inputNode.audioUnit else {
            logger.error("Input node has no audio unit — cannot pin the device")
            return resolution
        }
        var deviceID = resolution.device.id
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr {
            logger.error("Could not select input device \(resolution.device.name, privacy: .public): OSStatus \(status, privacy: .public)")
            return resolution
        }
        if resolution.source != .chosen && resolution.source != .systemDefault {
            // A fallback is a fact worth seeing, not a detail.
            logger.info("Falling back to \(resolution.device.name, privacy: .public) (\(resolution.source.rawValue, privacy: .public))")
        } else {
            logger.debug("Input device: \(resolution.device.name, privacy: .public) (\(resolution.source.rawValue, privacy: .public))")
        }
        return resolution
    }

    /// The recovery policy after a failed engine start: rebuild once, try once
    /// more, then give up. Split out so it can be verified without a microphone —
    /// the machine that hit this bug is not the machine the tests run on.
    static func retryAfterRebuild(
        rebuild: () -> Void,
        start: () throws -> Void,
        onError: (Error) -> Void
    ) -> Bool {
        rebuild()
        do {
            try start()
            return true
        } catch {
            onError(error)
            return false
        }
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
        refreshTapIfNeeded()
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
            do {
                refreshTapIfNeeded()
                guard converter != nil else {
                    // No input at all: say so instead of failing with a generic
                    // engine error the user cannot act on.
                    logger.error("Start refused: no usable audio input device")
                    active = false
                    completion(.noInputDevice)
                    return
                }
                // Clear any resampler filter state from the previous session. Safe
                // here: the engine is stopped and the tap is inactive, so no
                // render-thread callback can be touching the converter.
                converter?.reset()
                rawRecording = []
                rawRate = 0
                segmentStart = 0
                active = true
                if !engine.isRunning {
                    engine.prepare()   // nothing is kept warm any more — always needed here
                    #if DEBUG
                    if failNextStartForTesting {
                        failNextStartForTesting = false
                        throw NSError(domain: NSOSStatusErrorDomain, code: -10868)
                    }
                    #endif
                    try engine.start()
                }
                // The input works — put the fuse back in, so one bad stretch
                // doesn't disable recovery for the rest of the app's life.
                rebuildPolicy.reset()
                reportedInputUnavailable = false
                completion(nil)
            } catch {
                logger.error("Failed to start engine: \(error.localizedDescription, privacy: .public)")
                // Recover from a wedged engine (see the note on `engine`): rebuild
                // against the current hardware and try once more before giving up.
                let recovered = Self.retryAfterRebuild(
                    rebuild: { [self] in
                        rebuildEngine()
                        engine.prepare()
                    },
                    start: { [self] in try engine.start() },
                    onError: { [self] error in
                        logger.error("Engine start failed again after the rebuild: \(error.localizedDescription, privacy: .public)")
                    })
                if recovered {
                    logger.info("Engine started after rebuilding the input chain")
                    rebuildPolicy.reset()
                    reportedInputUnavailable = false
                    completion(nil)
                } else {
                    active = false
                    completion(.engineStartFailed)
                }
            }
        }
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

    /// The raw audio recorded since the last segment cut (the WHOLE recording if no
    /// cut fired) + its rate, for the final single-shot conversion at stop. Clears
    /// the buffer.
    func takeRecording() -> (samples: [Float], rate: Double) {
        engineQueue.sync {
            let tail = segmentStart < rawRecording.count ? Array(rawRecording[segmentStart...]) : []
            rawRecording = []
            segmentStart = 0
            return (tail, rawRate)
        }
    }

    /// Hand over the raw audio recorded since the last cut WITHOUT clearing the
    /// buffer (advances the segment marker) — for mid-recording incremental
    /// transcription of finished segments.
    func takeSegment() -> (samples: [Float], rate: Double) {
        engineQueue.sync {
            guard segmentStart < rawRecording.count else { return ([], rawRate) }
            let slice = Array(rawRecording[segmentStart...])
            segmentStart = rawRecording.count
            return (slice, rawRate)
        }
    }

    /// (Re)install the tap if it's missing or the input format changed since last
    /// time (e.g. the user switched audio device between recordings). Only ever
    /// called on `engineQueue` while stopped/starting — never mid-recording.
    private func refreshTapIfNeeded() {
        // Pin the device BEFORE reading any format. Reading first would ask a
        // node that has already resolved some other (possibly dead) device.
        applyInputDevice()
        let signature = currentInputSignature()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { return } // no device yet
        // The signature has to be part of this, not just the format: switching
        // from the display microphone to the built-in one keeps 48 kHz mono, so
        // a format-only comparison would keep a tap pointed at the old device.
        if converter != nil, tapFormat == inputFormat, builtSignature == signature { return }

        input.removeTap(onBus: 0)
        guard let conv = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            logger.error("Failed to create audio converter")
            converter = nil
            tapFormat = nil
            return
        }
        converter = conv
        tapFormat = inputFormat
        builtSignature = signature
        let target = targetFormat
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.handleTap(buffer, inputFormat: inputFormat, targetFormat: target)
        }
        logger.debug("Tap installed @ \(inputFormat.description, privacy: .public)")
    }

    private func handleTap(_ buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat, targetFormat: AVAudioFormat) {
        guard active, let conv = converter else { return }
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
            let rate = inputFormat.sampleRate
            engineQueue.async { [self] in
                rawRecording.append(contentsOf: chunk)
                rawRate = rate
                if rawRecording.count > Self.maxRaw {
                    let drop = rawRecording.count - Self.maxRaw
                    rawRecording.removeFirst(drop)
                    segmentStart = max(0, segmentStart - drop)   // keep the marker valid after trimming
                }
            }
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
