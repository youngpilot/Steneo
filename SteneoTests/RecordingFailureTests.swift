import XCTest
@testable import Steneo

/// The taxonomy that replaces a bare empty string.
///
/// Before 1.4.4 all of these produced exactly the same thing — `""` — and
/// `stopRecording()` responded to it by doing nothing at all: no insert, no
/// history entry, no message, no audio kept. These tests exist so that stays
/// impossible.
final class RecordingFailureTests: XCTestCase {

    private func classify(samples: Int, minimum: Int = 4800, threw: Bool = false, text: String = "") -> RecordingFailure? {
        RecordingFailure.classify(sampleCount: samples, minimumSamples: minimum,
                                  asrThrew: threw, transcript: text)
    }

    func testTextMeansNoFailure() {
        XCTAssertNil(classify(samples: 48_000, text: "Good morning, everyone."))
    }

    /// With segmentation the tail handed to the classifier can be a fraction of a
    /// long recording. Words that arrived outweigh a small sample count.
    func testTextWinsOverEveryOtherSignal() {
        XCTAssertNil(classify(samples: 0, threw: true, text: "Good morning"),
                     "a transcript that exists is not a failure, whatever else happened")
    }

    func testWhitespaceIsNotText() {
        XCTAssertEqual(classify(samples: 48_000, text: "   \n  "), .emptyResult)
    }

    func testDeafRecordingIsNamed() {
        XCTAssertEqual(classify(samples: 0), .noSamples,
                       "no audio at all is a different fault from hearing no words")
    }

    func testTooShortIsNamed() {
        XCTAssertEqual(classify(samples: 1_000), .tooShort)
    }

    func testAModelFailureIsNotSilence() {
        XCTAssertEqual(classify(samples: 48_000, threw: true), .asrError,
                       "a thrown model must never look like an empty room")
    }

    func testSilenceIsTheLastExplanation() {
        XCTAssertEqual(classify(samples: 48_000), .emptyResult)
    }

    // MARK: - What follows from the reason

    func testOnlyFailuresWithAudioAreWorthKeeping() {
        XCTAssertFalse(RecordingFailure.engineStart.hasRecoverableAudio, "nothing was ever captured")
        XCTAssertFalse(RecordingFailure.noSamples.hasRecoverableAudio)
        XCTAssertFalse(RecordingFailure.tooShort.hasRecoverableAudio)
        XCTAssertTrue(RecordingFailure.asrError.hasRecoverableAudio, "the audio is fine, the model was not")
        XCTAssertTrue(RecordingFailure.emptyResult.hasRecoverableAudio)
    }

    func testEveryReasonCanBeToldToSomeone() {
        for reason in RecordingFailure.allCases {
            XCTAssertFalse(reason.message.isEmpty, "\(reason.rawValue) has nothing to say")
            XCTAssertFalse(reason.message.contains(reason.rawValue), "\(reason.rawValue) leaks its identifier into the UI")
        }
    }

    // MARK: - The threshold the classifier is measured against

    func testMinimumSamplesIsATenthOfASecondAtAnyRate() {
        XCTAssertEqual(TranscriptionService.minimumSamples(atRate: 48_000), 4_800)
        XCTAssertEqual(TranscriptionService.minimumSamples(atRate: 24_000), 2_400)
        XCTAssertEqual(TranscriptionService.minimumSamples(atRate: 16_000), 1_600)
        XCTAssertEqual(TranscriptionService.minimumSamples(atRate: 0), 1_600,
                       "an unknown rate must not make every recording look long enough")
    }
}
