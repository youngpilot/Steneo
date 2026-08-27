import AVFoundation
import Accelerate
import os

private let logger = Logger(subsystem: "com.youngpilot.Steneo", category: "AudioCapture")

/// Captures microphone audio as 16 kHz mono for the ASR.
///
/// The `AVAudioEngine` is created once and reused for the app's lifetime; it's
/// warmed up ahead of time so the first start is fast. The mic is only live
/// between `startCapture()` and `stopCapture()` — there is no always-on
/// microphone (or always-on indicator).
///
/// THREADING: every AVAudioEngine operation (prepare / tap install / start /
/// stop) runs on the single serial `engineQueue`. AVAudioEngine is not
/// thread-safe — mixing main-thread tap-install with a background-thread start
/// scrambles/drops the first buffers (the 55461fa regression). One queue, always.
final class AudioCaptureService: @unchecked Sendable {
    /// Replaceable on purpose. A long-lived engine keeps the input hardware's
    /// format from the moment it was first configured; when the default input
    /// device changes, `inputNode.outputFormat(forBus:)` can keep reporting the
    /// OLD one. `refreshTapIfNeeded` then compares old against old, decides
    /// nothing changed, and `engine.start()` fails with -10868 (format not
    /// supported) on every attempt from then on — the app never recovers. A fresh
    /// instance has no such memory, which is why recovery replaces it instead of
    /// resetting it.
    private var engine = AVAudioEngine()
    private let engineQueue = DispatchQueue(label: "com.youngpilot.Steneo.audioengine", qos: .userInitiated)
    private var configObserver: NSObjectProtocol?

    #if DEBUG
    /// Makes the next `engine.start()` fail, so the recovery path can be tested
    /// for real instead of hoping a device change reproduces the wedge.
    var failNextStartForTesting = false
    #endif
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    private var converter: AVAudioConverter?
    private var tapFormat: AVAudioFormat?
    private var active = false

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
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    /// Allocate engine resources ahead of time (no mic I/O, no indicator) so the
    /// first real start is fast. Call once at launch, only when mic is granted.
    func prepareEngine() {
        engineQueue.async { [self] in
            refreshTapIfNeeded()
            engine.prepare()
            logger.debug("Engine prepared")
        }
    }

    private func handleConfigurationChange() {
        engineQueue.async { [self] in
            let wasCapturing = active
            logger.info("Audio configuration changed (capturing: \(wasCapturing, privacy: .public)) — rebuilding input")
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
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        engine = AVAudioEngine()
        converter = nil
        tapFormat = nil
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
                // Clear any resampler filter state from the previous session. Safe
                // here: the engine is stopped and the tap is inactive, so no
                // render-thread callback can be touching the converter.
                converter?.reset()
                rawRecording = []
                rawRate = 0
                segmentStart = 0
                active = true
                if !engine.isRunning {
                    engine.prepare()
                    #if DEBUG
                    if failNextStartForTesting {
                        failNextStartForTesting = false
                        throw NSError(domain: NSOSStatusErrorDomain, code: -10868)
                    }
                    #endif
                    try engine.start()
                }
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
            if engine.isRunning { engine.stop() }   // mic off; engine kept warm for next time
        }
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
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { return } // no device yet
        if converter != nil, tapFormat == inputFormat { return }

        input.removeTap(onBus: 0)
        guard let conv = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            logger.error("Failed to create audio converter")
            converter = nil
            tapFormat = nil
            return
        }
        converter = conv
        tapFormat = inputFormat
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

enum AudioCaptureError: Error, LocalizedError {
    case microphoneDenied
    case formatError
    case converterError
    case engineStartFailed

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: "Microphone access is denied"
        case .formatError: "Failed to create audio format"
        case .converterError: "Failed to create audio converter"
        case .engineStartFailed: "Failed to start the audio engine"
        }
    }
}
