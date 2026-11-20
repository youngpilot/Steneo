import AVFoundation
import Accelerate
import os

private let logger = Logger(subsystem: "com.youngpilot.Steneo", category: "SelfCheck")

/// The release check that used to need a person dictating a sentence.
///
/// Runs only when the app is launched with `--release-self-check <audio file>`,
/// which only `scripts/release.sh` does. It checks the bundle that ships, in the
/// place it is installed, with the permissions it really has:
/// 1. the microphone: about a second of the room on "Automatic", read the way a
///    recording reads it;
/// 2. the speech model: the given file (a sentence `say` wrote to disk, never
///    played) through the same path a recording takes at stop.
/// Plays nothing, changes no volume, switches no device, types nothing.
/// The results go to the log, where `scripts/check-installed.sh` reads them.
@MainActor
enum ReleaseSelfCheck {
    static let argument = "--release-self-check"

    static func requestedFile() -> URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard !AppEnvironment.isRunningTests,
              let index = arguments.firstIndex(of: argument), index + 1 < arguments.count
        else { return nil }
        return URL(fileURLWithPath: arguments[index + 1])
    }

    static func run(file: URL) async {
        logger.notice("Self-check started")
        await checkMicrophone()
        await checkModel(file: file)
        logger.notice("Self-check finished")
    }

    private final class Started: @unchecked Sendable {
        private let lock = NSLock()
        private var value: CaptureStartInfo?
        func set(_ info: CaptureStartInfo) { lock.lock(); value = info; lock.unlock() }
        var info: CaptureStartInfo? { lock.lock(); defer { lock.unlock() }; return value }
    }

    private static func checkMicrophone() async {
        let capture = AudioCaptureService()
        capture.startTimes = SettingsStore.shared.inputStartTimes
        let started = Started()
        capture.onStarted = { started.set($0) }
        let error: AudioCaptureError? = await withCheckedContinuation { continuation in
            capture.startCapture(onBuffer: { _ in }, onLevel: { _ in }) { continuation.resume(returning: $0) }
        }
        if let error {
            logger.error("Self-check microphone FAILED: \(error.localizedDescription, privacy: .public)")
            return
        }
        try? await Task.sleep(for: .seconds(1.2))
        capture.stopCapture()
        let recording = capture.takeRecording()
        var level: Float = 0
        if !recording.samples.isEmpty {
            vDSP_rmsqv(recording.samples, 1, &level, vDSP_Length(recording.samples.count))
        }
        let seconds = Double(recording.samples.count) / recording.rate
        let name = started.info?.device.name ?? "unknown"
        // A live microphone is never digitally silent; zeros mean no access.
        guard seconds > 0.5, level > 0.000_001 else {
            logger.error("Self-check microphone FAILED: \(name, privacy: .public) gave \(seconds, format: .fixed(precision: 2), privacy: .public) s at level \(level, privacy: .public)")
            return
        }
        logger.notice("Self-check microphone OK: \(name, privacy: .public), \(seconds, format: .fixed(precision: 2), privacy: .public) s of sound")
    }

    private static func checkModel(file: URL) async {
        guard let audio = try? AVAudioFile(forReading: file),
              let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat,
                                            frameCapacity: AVAudioFrameCount(audio.length)),
              (try? audio.read(into: buffer)) != nil,
              let channel = buffer.floatChannelData?[0]
        else {
            logger.error("Self-check model FAILED: could not read \(file.path, privacy: .public)")
            return
        }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        // Its own instance: nothing a dictation running at the same moment holds
        // is touched. Same path a recording takes when it stops.
        let service = TranscriptionService()
        let began = Date()
        service.beginCapturing()
        await service.startTranscription()
        let text = await service.stopTranscription(rawSamples: samples, rate: audio.processingFormat.sampleRate)
        let milliseconds = Date().timeIntervalSince(began) * 1000
        guard !text.isEmpty else {
            logger.error("Self-check model FAILED: no text (\(service.lastFailure?.rawValue ?? "unknown", privacy: .public))")
            return
        }
        logger.notice("Self-check model OK in \(milliseconds, format: .fixed(precision: 0), privacy: .public) ms: \(text, privacy: .public)")
    }
}
