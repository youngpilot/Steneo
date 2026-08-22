import XCTest
@testable import Steneo

/// The regression guard for the "double-press Right ⌘ doesn't start recording" bug.
///
/// The old detector counted every modifier key-down, so two ordinary shortcuts typed
/// within the double-press window (⌘C then ⌘V) silently toggled recording. The
/// phantom recording that started there was then stopped by the next deliberate
/// double-tap — which is exactly what "the mic flashes and nothing records" looked
/// like. Every case below is written against that failure.
final class ModifierTapDetectorTests: XCTestCase {

    /// Wraps the detector so a test reads as a timeline, and counts the toggles.
    private struct Rig {
        var detector = ModifierTapDetector()
        private(set) var toggles = 0

        /// A clean tap of the modifier alone: down at `at`, up `duration` later.
        mutating func tap(at: TimeInterval, duration: TimeInterval = 0.06) {
            feed(.down(at: at, otherModifiers: false))
            feed(.up(at: at + duration, otherModifiers: false))
        }

        /// A shortcut typed with the same modifier (⌘C): modifier down, another key
        /// down while it is held, modifier up.
        mutating func shortcut(at: TimeInterval, duration: TimeInterval = 0.09) {
            feed(.down(at: at, otherModifiers: false))
            feed(.otherInput(at: at + duration / 2))
            feed(.up(at: at + duration, otherModifiers: false))
        }

        mutating func feed(_ event: ModifierTapDetector.Event) {
            if detector.handle(event) { toggles += 1 }
        }
    }

    // MARK: - The bug

    func testTwoShortcutsInQuickSuccessionDoNotToggle() {
        var rig = Rig()
        rig.shortcut(at: 0.00)   // ⌘C
        rig.shortcut(at: 0.20)   // ⌘V, well inside the 0.4s window
        XCTAssertEqual(rig.toggles, 0)
    }

    func testShortcutFollowedByDeliberateDoubleTapTogglesExactlyOnce() {
        var rig = Rig()
        rig.shortcut(at: 0.00)   // ⌘V — used to arm the detector
        rig.tap(at: 0.25)        // first deliberate tap: must NOT fire yet
        XCTAssertEqual(rig.toggles, 0, "the shortcut must not pair up with a tap")
        rig.tap(at: 0.45)        // second deliberate tap
        XCTAssertEqual(rig.toggles, 1)
    }

    func testTapCancelledByShortcutDoesNotPairWithLaterTap() {
        var rig = Rig()
        rig.tap(at: 0.00)        // pending first tap
        rig.shortcut(at: 0.10)   // cancels it
        rig.tap(at: 0.25)        // would have been "the second tap" before the fix
        XCTAssertEqual(rig.toggles, 0)
    }

    // MARK: - The feature still works

    func testCleanDoubleTapTogglesOnce() {
        var rig = Rig()
        rig.tap(at: 0.00)
        rig.tap(at: 0.15)
        XCTAssertEqual(rig.toggles, 1)
    }

    func testThreeTapsToggleOnlyOnce() {
        var rig = Rig()
        rig.tap(at: 0.00)
        rig.tap(at: 0.15)   // fires
        rig.tap(at: 0.30)   // starts a fresh pair, must not fire again
        XCTAssertEqual(rig.toggles, 1)
    }

    func testTwoConsecutiveDoubleTapsToggleTwice() {
        var rig = Rig()
        rig.tap(at: 0.00); rig.tap(at: 0.15)   // start
        rig.tap(at: 2.00); rig.tap(at: 2.15)   // stop
        XCTAssertEqual(rig.toggles, 2)
    }

    // MARK: - Timing and modifier rules

    func testTapsTooFarApartDoNotToggle() {
        var rig = Rig()
        rig.tap(at: 0.00)
        rig.tap(at: 0.50)   // > 0.4s window
        XCTAssertEqual(rig.toggles, 0)
    }

    func testHeldModifierIsNotATap() {
        var rig = Rig()
        // Both presses are holds, and their key-DOWNs are only 0.30s apart — the
        // old detector counted downs and would fire here.
        rig.tap(at: 0.00, duration: 0.45)
        rig.tap(at: 0.30, duration: 0.45)
        XCTAssertEqual(rig.toggles, 0)
    }

    func testHoldThenTapDoesNotToggle() {
        var rig = Rig()
        rig.tap(at: 0.00, duration: 0.35)   // hold
        rig.tap(at: 0.38)                   // clean tap right after — downs 0.38s apart
        XCTAssertEqual(rig.toggles, 0)
    }

    func testTapWithAnotherModifierHeldDoesNotCount() {
        var rig = Rig()
        // ⌘⇧ pressed twice: shift is held throughout, so neither press is a tap.
        rig.feed(.down(at: 0.00, otherModifiers: true))
        rig.feed(.up(at: 0.06, otherModifiers: true))
        rig.feed(.down(at: 0.15, otherModifiers: true))
        rig.feed(.up(at: 0.21, otherModifiers: true))
        XCTAssertEqual(rig.toggles, 0)
    }

    func testModifierReleasedWithAnotherModifierStillDownDoesNotCount() {
        var rig = Rig()
        rig.feed(.down(at: 0.00, otherModifiers: false))
        rig.feed(.up(at: 0.06, otherModifiers: true))   // e.g. shift pressed meanwhile
        rig.tap(at: 0.15)
        XCTAssertEqual(rig.toggles, 0)
    }

    func testMouseClickWhileModifierHeldCancelsTheTap() {
        var rig = Rig()
        rig.feed(.down(at: 0.00, otherModifiers: false))
        rig.feed(.otherInput(at: 0.03))   // ⌘-click
        rig.feed(.up(at: 0.08, otherModifiers: false))
        rig.tap(at: 0.20)
        XCTAssertEqual(rig.toggles, 0)
    }

    // MARK: - Housekeeping

    func testReleaseWithoutPressIsIgnored() {
        var rig = Rig()
        // App starts while the key is already down: we only see the release.
        rig.feed(.up(at: 0.00, otherModifiers: false))
        rig.tap(at: 0.10)
        XCTAssertEqual(rig.toggles, 0, "a lone release must not count as a tap")
        rig.tap(at: 0.25)
        XCTAssertEqual(rig.toggles, 1, "and it must not break the next real double-tap")
    }

    func testResetDropsPendingTap() {
        var rig = Rig()
        rig.tap(at: 0.00)
        rig.detector.reset()
        rig.tap(at: 0.15)
        XCTAssertEqual(rig.toggles, 0)
    }

    func testTapDurationExactlyAtLimitStillCounts() {
        var rig = Rig()
        rig.tap(at: 0.00, duration: 0.30)
        rig.tap(at: 0.35, duration: 0.30)
        XCTAssertEqual(rig.toggles, 1)
    }
}
