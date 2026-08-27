import XCTest
@testable import Steneo

/// The gate for 1.6.0, not a regression test. Speaker recognition only ships if it
/// can put words on the right speaker. The bar was set BEFORE the first run — 90%
/// of tokens correct and the right number of speakers — so the outcome can't be
/// rationalised afterwards. ITN once looked like a cheap win in the same roadmap
/// and turned out to be a no-op; this is the check that was missing there.
///
/// Skipped unless STENEO_MEASURE_DIARIZATION=1: it downloads CoreML models and
/// takes minutes.
final class DiarizationMeasurementTests: XCTestCase {

    func testSpeakerAttributionOnACleanTwoSpeakerRecording() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["STENEO_MEASURE_DIARIZATION"] == "1",
                          "measurement only — set STENEO_MEASURE_DIARIZATION=1")
        let dir = try XCTUnwrap(env["STENEO_TURNS_DIR"], "STENEO_TURNS_DIR missing")

        let manifest = URL(fileURLWithPath: dir).appendingPathComponent("turns.txt")
        let turns: [DiarizationMeasurement.Turn] = try String(contentsOf: manifest, encoding: .utf8)
            .split(separator: "\n")
            .map { line in
                let parts = line.split(separator: "\t").map(String.init)
                return .init(url: URL(fileURLWithPath: dir).appendingPathComponent(parts[0]), speaker: parts[1])
            }
        XCTAssertGreaterThanOrEqual(turns.count, 4, "too few turns to say anything")

        // Optionally tell the diarizer how many speakers to expect — the question
        // is whether that rescues the 3-speaker case that fails on automatic.
        let expected = env["STENEO_EXPECTED_SPEAKERS"].flatMap(Int.init)
        let threshold = env["STENEO_THRESHOLD"].flatMap(Float.init)
        let report = try await DiarizationMeasurement.run(
            turns: turns, expectedSpeakers: expected, threshold: threshold)
        print("MEASUREMENT RESULT: \(report.summary)")

        XCTAssertGreaterThan(report.tokensScored, 20, "too few tokens scored for the number to mean anything")
        XCTAssertEqual(report.detectedSpeakers, report.trueSpeakers, "speaker count must be right")
        XCTAssertGreaterThanOrEqual(report.accuracy, 0.90, "bar set before the run: 90% on the right speaker")
    }
}
