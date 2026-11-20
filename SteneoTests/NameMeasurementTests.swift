import XCTest
@testable import Steneo

/// Runs the names measurement and prints its report. Not a test of the app:
/// a measurement, and a slow one, so it only runs when asked for:
///
///     TEST_RUNNER_STENEO_MEASURE=names xcodebuild test -only-testing:SteneoTests/NameMeasurementTests
///
/// Silent: the sentences are written to files and never played.
final class NameMeasurementTests: XCTestCase {
    func testNamesWithAndWithoutAList() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STENEO_MEASURE"] == "names",
                          "a measurement, not a test: run it with TEST_RUNNER_STENEO_MEASURE=names")
        let report = try await NameMeasurement.run()
        print("NAME-MEASUREMENT-BEGIN\n\(report)\nNAME-MEASUREMENT-END")
    }
}
