import Foundation

/// Why a recording produced no text.
///
/// Until 1.4.4 there was no such thing: `stopRecording()` did nothing at all when
/// the transcript came back empty — no insert, no history entry, no message, no
/// audio kept, not even a counter. Every failure upstream (a dead audio device, a
/// torn-down engine, an ASR error, real silence) arrived at the same silent hole
/// and looked identical to the user: the recording simply never happened.
///
/// Naming the reason is what turns "it vanished" into something that can be told,
/// logged and acted on.
enum RecordingFailure: String, Equatable, Sendable, CaseIterable {
    /// The microphone never came up. Nothing was captured, so nothing can be kept.
    case engineStart = "engine-start"
    /// The engine ran but no audio arrived — a deaf recording.
    case noSamples = "no-samples"
    /// Under a tenth of a second. Usually a double-press that toggled twice.
    case tooShort = "too-short"
    /// The speech model threw.
    case asrError = "asr-error"
    /// Audio was captured and the model ran, but heard no words.
    case emptyResult = "empty-result"

    /// What to tell the user. One line, no jargon, and it never blames them.
    var message: String {
        switch self {
        case .engineStart: "Couldn't start the microphone — nothing was recorded."
        case .noSamples: "No audio arrived from the microphone — the recording is kept."
        case .tooShort: "That was too short to transcribe."
        case .asrError: "Transcription failed — the recording is kept."
        case .emptyResult: "No speech found — the recording is kept."
        }
    }

    /// Whether there is audio worth keeping for a second attempt. A start that
    /// never happened has nothing to keep.
    var hasRecoverableAudio: Bool {
        switch self {
        case .engineStart, .noSamples, .tooShort: false
        case .asrError, .emptyResult: true
        }
    }

    /// Decide what went wrong, from facts the caller already has.
    ///
    /// Pure so the mapping is testable: these states appear when hardware
    /// disappears or a model throws, and no test machine produces them on demand.
    static func classify(
        sampleCount: Int,
        minimumSamples: Int,
        asrThrew: Bool,
        transcript: String
    ) -> RecordingFailure? {
        // Text first: with segmentation the tail handed in here can be a fraction
        // of a long recording, so a small sample count says nothing when words
        // actually arrived.
        if !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        if sampleCount == 0 { return .noSamples }
        if sampleCount < minimumSamples { return .tooShort }
        if asrThrew { return .asrError }
        return .emptyResult
    }
}
