import Foundation

/// Decides whether a running recording is still hearing anything.
///
/// The failure this exists for: the audio engine dies under a live recording —
/// a device is pulled, a resume after a configuration change fails — and nothing
/// notices. `isRecording` stays true, the menubar mic stays red, and the user
/// keeps talking to an app that captures silence. Red has to mean "your audio is
/// being captured" or it means nothing.
///
/// Pure and time-injected: a microphone that stops mid-sentence is not a state
/// any test machine produces on demand.
struct DeafMicrophoneWatchdog: Equatable {

    enum Verdict: Equatable {
        /// Audio is arriving, or the engine is still within its warm-up.
        case hearing
        /// No audio for long enough that the recording is not a recording.
        case deaf
    }

    /// The audio engine needs a moment before the first buffer lands. Cutting a
    /// recording off during that window would be worse than the bug.
    var grace: TimeInterval = 2.0
    /// A gap this long mid-recording is not a pause in speech — the tap has
    /// stopped delivering. Buffers arrive roughly every 85 ms at 4096 frames.
    var silenceLimit: TimeInterval = 2.0

    /// `secondsSinceLastBuffer` is nil while no buffer has arrived at all.
    func verdict(secondsSinceLastBuffer: TimeInterval?, secondsSinceStart: TimeInterval) -> Verdict {
        guard let gap = secondsSinceLastBuffer else {
            // Nothing has ever arrived: only a fault once the warm-up is over.
            return secondsSinceStart > grace ? .deaf : .hearing
        }
        return gap > silenceLimit ? .deaf : .hearing
    }
}
