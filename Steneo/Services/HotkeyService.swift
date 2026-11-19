import AppKit
import Carbon
import Observation

/// How the recording hotkey activates: tap to toggle, or hold (push-to-talk).
enum ActivationMode: String, CaseIterable, Identifiable {
    case toggle   // press to start, press again to stop (double-press for modifier keys)
    case hold     // push-to-talk: hold to record, release to stop
    var id: String { rawValue }
    var label: String { self == .toggle ? "Toggle" : "Hold" }
}

@Observable
@MainActor
final class HotkeyService {
    private var flagsMonitor: Any?
    private var keyDownMonitor: Any?
    private var keyUpMonitor: Any?
    private var mouseDownMonitor: Any?
    /// One tap detector per modifier hotkey, so two enabled modifier hotkeys can
    /// never interfere with each other's tap timing.
    private var tapDetectors: [HotkeyChoice: ModifierTapDetector] = [:]
    /// Ignore a toggle this soon after the previous one — belt and braces against
    /// any residual double-fire (a duplicate monitor, a repeated event).
    private let minToggleGap: TimeInterval = 0.25
    private var lastToggleFire: TimeInterval = -.greatestFiniteMagnitude
    private var currentHotkeys: Set<HotkeyChoice> = [.doubleRightOption]
    /// In Hold mode, the hotkey currently held down (pairs press→release).
    private var heldHotkey: HotkeyChoice?

    /// The modifier hotkeys, with the key code and the flag their press sets.
    private static let modifierHotkeys: [(choice: HotkeyChoice, keyCode: UInt16, flag: NSEvent.ModifierFlags)] = [
        (.doubleRightOption, 61, .option),
        (.doubleRightCmd, 54, .command),
        (.doubleFn, 63, .function),
    ]

    /// Modifiers that disqualify a tap when held alongside it. `.function` is left
    /// out on purpose: some keyboards report it liberally, and a false positive here
    /// would break the hotkey entirely — real shortcuts are already caught by the
    /// "another key was pressed" rule.
    private static let disqualifyingFlags: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    var onToggle: (() -> Void)?    // Toggle mode
    var onPress: (() -> Void)?     // Hold mode: hotkey pressed → start
    var onRelease: (() -> Void)?   // Hold mode: hotkey released → stop

    func start() {
        // Always tear down first: start() runs again whenever setup() is retried
        // (the model-load Retry button), and a second set of monitors would make
        // every key event fire twice — the first tap alone would then toggle.
        stop()
        currentHotkeys = SettingsStore.shared.hotkeys
        SettingsStore.shared.onHotkeyChanged = { [weak self] newHotkeys in
            self?.currentHotkeys = newHotkeys
            self?.resetDetectors()
        }
        installMonitors()
    }

    func stop() {
        for m in [flagsMonitor, keyDownMonitor, keyUpMonitor, mouseDownMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(m)
        }
        flagsMonitor = nil; keyDownMonitor = nil; keyUpMonitor = nil; mouseDownMonitor = nil
        resetDetectors()
        heldHotkey = nil
    }

    private func resetDetectors() { tapDetectors.removeAll() }

    private var mode: ActivationMode { SettingsStore.shared.activationMode }

    private func installMonitors() {
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.handleFlagsChanged(event) }
        }
        keyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handleKeyDown(event) }
        }
        keyUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { [weak self] event in
            MainActor.assumeIsolated { self?.handleKeyUp(event) }
        }
        // A click while the modifier is held also means "shortcut, not a tap"
        // (⌘-clicking links, for one).
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.noteOtherInput(at: event.timestamp) }
        }
    }

    // MARK: - Modifier keys (Right ⌥ / Right ⌘ / Fn)

    private func handleFlagsChanged(_ event: NSEvent) {
        if mode == .hold { handleHoldFlags(event); return }
        // Toggle mode: double-TAP of a modifier hotkey. The flag being present in
        // the event is the press, its absence the release — both are fed to the
        // detector, which only counts a press that was tapped alone.
        guard let hk = Self.modifierHotkeys.first(where: { $0.keyCode == event.keyCode }),
              currentHotkeys.contains(hk.choice)
        else { return }

        let isDown = event.modifierFlags.contains(hk.flag)
        let others = !event.modifierFlags
            .intersection(Self.disqualifyingFlags.subtracting(hk.flag))
            .isEmpty
        let tapEvent: ModifierTapDetector.Event = isDown
            ? .down(at: event.timestamp, otherModifiers: others)
            : .up(at: event.timestamp, otherModifiers: others)

        var detector = tapDetectors[hk.choice] ?? ModifierTapDetector()
        let isDoubleTap = detector.handle(tapEvent)
        tapDetectors[hk.choice] = detector
        if isDoubleTap { fireToggle() }
    }

    /// Any other key or click: cancels a modifier press in flight, so shortcuts
    /// (⌘C, ⌘V, ⌘Tab …) can never be mistaken for taps.
    private func noteOtherInput(at timestamp: TimeInterval) {
        for key in tapDetectors.keys {
            _ = tapDetectors[key]?.handle(.otherInput(at: timestamp))
        }
    }

    /// Hold mode: a modifier's keyCode event carries the resulting flag state —
    /// flag present = pressed (start), absent = released (stop).
    private func handleHoldFlags(_ event: NSEvent) {
        if currentHotkeys.contains(.doubleRightOption), event.keyCode == 61 {
            event.modifierFlags.contains(.option) ? holdPress(.doubleRightOption) : holdRelease(.doubleRightOption)
            return
        }
        if currentHotkeys.contains(.doubleRightCmd), event.keyCode == 54 {
            event.modifierFlags.contains(.command) ? holdPress(.doubleRightCmd) : holdRelease(.doubleRightCmd)
            return
        }
        if currentHotkeys.contains(.doubleFn), event.keyCode == 63 {
            event.modifierFlags.contains(.function) ? holdPress(.doubleFn) : holdRelease(.doubleFn)
            return
        }
    }

    // MARK: - Regular keys (F5, ⌥Space, Fn Space)

    /// A key-down counts as a press only when it is not the keyboard repeating a
    /// key that is being held. Without this, holding F5 past the repeat delay
    /// (450 ms on this Mac, shorter than a recording takes to start) fired the
    /// toggle a second time and ended the recording the moment it began.
    nonisolated static func isFreshPress(_ event: NSEvent) -> Bool { !event.isARepeat }

    private func handleKeyDown(_ event: NSEvent) {
        noteOtherInput(at: event.timestamp)
        guard Self.isFreshPress(event) else { return }
        if mode == .hold {
            if matchesF5(event) { holdPress(.f5) }
            else if matchesOptionSpace(event) { holdPress(.optionSpace) }
            else if matchesFnSpace(event) { holdPress(.fnSpace) }
            return
        }
        if matchesF5(event) || matchesOptionSpace(event) || matchesFnSpace(event) { fireToggle() }
    }

    private func handleKeyUp(_ event: NSEvent) {
        guard mode == .hold else { return }
        if event.keyCode == 96 { holdRelease(.f5); return }   // F5 up
        if event.keyCode == 49 {                              // Space up → end any space-combo hold
            holdRelease(.optionSpace)
            holdRelease(.fnSpace)
        }
    }

    private func matchesF5(_ e: NSEvent) -> Bool {
        currentHotkeys.contains(.f5) && e.keyCode == 96
    }
    private func matchesOptionSpace(_ e: NSEvent) -> Bool {
        currentHotkeys.contains(.optionSpace) && e.keyCode == 49 &&
            e.modifierFlags.contains(.option) &&
            !e.modifierFlags.contains(.command) && !e.modifierFlags.contains(.control)
    }
    private func matchesFnSpace(_ e: NSEvent) -> Bool {
        currentHotkeys.contains(.fnSpace) && e.keyCode == 49 &&
            e.modifierFlags.contains(.function) &&
            !e.modifierFlags.contains(.command) && !e.modifierFlags.contains(.option) &&
            !e.modifierFlags.contains(.control)
    }

    // MARK: - Helpers

    private func fireToggle() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastToggleFire >= minToggleGap else { return }
        lastToggleFire = now
        onToggle?()
    }

    /// Hold-mode press: start once, tracking which key is held.
    private func holdPress(_ choice: HotkeyChoice) {
        guard heldHotkey == nil else { return }
        heldHotkey = choice
        onPress?()
    }

    /// Hold-mode release: stop only when the key that started the hold is released.
    private func holdRelease(_ choice: HotkeyChoice) {
        guard heldHotkey == choice else { return }
        heldHotkey = nil
        onRelease?()
    }
}
