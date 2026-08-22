import Foundation

/// Detects a deliberate double-TAP of a single modifier key (Right ⌘ / Right ⌥ / Fn).
///
/// The condition that matters — and that the old inline check was missing — is that a
/// tap only counts when the modifier went down and back up ALONE. Without it every
/// ordinary shortcut typed with the same modifier (⌘C, ⌘V, ⌘Z, ⌘Tab …) fed the
/// detector, so any two shortcuts inside the double-tap window silently toggled
/// recording: a phantom recording that the next deliberate double-tap then stopped.
///
/// Kept pure and synchronous so the whole state machine is unit-testable without any
/// event plumbing — `HotkeyService` only translates NSEvents into `Event` values.
struct ModifierTapDetector {
    /// Two taps closer together than this count as a double-tap.
    var doubleTapInterval: TimeInterval = 0.4
    /// A press held longer than this is a hold, not a tap.
    var maxTapDuration: TimeInterval = 0.3

    enum Event {
        /// The watched modifier went down. `otherModifiers`: another modifier was already held.
        case down(at: TimeInterval, otherModifiers: Bool)
        /// The watched modifier came back up.
        case up(at: TimeInterval, otherModifiers: Bool)
        /// Any other key or mouse button went down.
        case otherInput(at: TimeInterval)
    }

    private var pressStart: TimeInterval?
    private var pressIsClean = false
    private var lastTapEnd: TimeInterval?

    init() {}

    /// Feeds one event; returns true exactly when a double-tap completes.
    mutating func handle(_ event: Event) -> Bool {
        switch event {
        case let .down(at, otherModifiers):
            pressStart = at
            pressIsClean = !otherModifiers

        case .otherInput:
            // A key or click while the modifier is down means this was a shortcut,
            // not a tap.
            pressIsClean = false

        case let .up(at, otherModifiers):
            let start = pressStart
            let clean = pressIsClean && !otherModifiers
            pressStart = nil
            pressIsClean = false
            guard let start, clean, at - start <= maxTapDuration else {
                // Not a clean tap — and it also cancels a pending first tap, so a
                // shortcut can never pair up with a later tap into a double-tap.
                lastTapEnd = nil
                return false
            }
            if let last = lastTapEnd, at - last < doubleTapInterval {
                lastTapEnd = nil
                return true
            }
            lastTapEnd = at
        }
        return false
    }

    /// Drop all pending state (hotkey selection changed, monitors reinstalled).
    mutating func reset() {
        pressStart = nil
        pressIsClean = false
        lastTapEnd = nil
    }
}
