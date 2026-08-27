import XCTest
@testable import Steneo

/// Typing text key by key drops characters when the target app's event queue
/// can't keep up — the 0.8.5 bug, which was narrowed to "only short text" instead
/// of removed and therefore came back in 1.4/1.5. These tests exist so nobody
/// re-introduces a length threshold as an optimisation.
final class InsertionModeTests: XCTestCase {

    func testAutoNeverTypesDirectlyAtAnyLength() {
        for length in [0, 1, 5, 29, 30, 31, 100, 5000] {
            XCTAssertFalse(OutputService.usesDirectTyping(mode: .auto, textLength: length),
                           "Auto must never type directly — length \(length)")
        }
    }

    func testClipboardNeverTypesDirectly() {
        for length in [1, 30, 1000] {
            XCTAssertFalse(OutputService.usesDirectTyping(mode: .clipboard, textLength: length))
        }
    }

    /// Direct stays available, but only when explicitly chosen — and then length
    /// must not change the answer either.
    func testDirectAlwaysTypesDirectly() {
        for length in [1, 30, 31, 1000] {
            XCTAssertTrue(OutputService.usesDirectTyping(mode: .direct, textLength: length))
        }
    }
}
