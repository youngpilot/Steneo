import AppKit
import Foundation

// This check brings TextEdit to the front and types into it. Silent, but still a
// takeover of someone's keyboard — it does not start unasked either.
guard CommandLine.arguments.contains("--confirm")
        || ProcessInfo.processInfo.environment["STENEO_GATE_CONFIRM"] == "1" else {
    print("""
          Check A opens TextEdit and types into it for a few seconds.
          Run it with --confirm (or STENEO_GATE_CONFIRM=1) when the Mac is free.
          """)
    exit(3)
}


/// Check A of the release gate: does text survive insertion character for
/// character?
///
/// This is the failure that hit twice — 0.8.5 and again in 1.4/1.5. Typing text
/// key by key posts one event per character, and a busy target app silently drops
/// some, so "Deutsch" arrives as "Dutsch". Nobody notices until they re-read their
/// own writing. A unit test cannot see it: the loss happens between two processes.
///
/// So this drives BOTH insertion mechanisms exactly as OutputService implements
/// them, into a scratch TextEdit document, and compares byte for byte.
///
/// Boundary, stated rather than glossed over: this measures the mechanism on this
/// machine, not the shipped binary. That the app never CHOOSES the lossy one is
/// covered by InsertionModeTests; that a real dictation arrives is check B.
///
/// Exit 0 = the clipboard path (what Auto uses) is exact.

let source = CGEventSource(stateID: .hidSystemState)

/// A name of its own per run. On 19.11.2026 an aborted run left its document
/// open, the next run replaced the file underneath it, TextEdit dropped the
/// document, and every paste went nowhere.
let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("steneo-check-\(ProcessInfo.processInfo.processIdentifier).txt")

@discardableResult
func osa(_ script: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    try? p.run()
    let out = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

/// Same, but WITHOUT trimming — only the single newline osascript appends is
/// removed. Trimming the content is how this probe accused the app of dropping a
/// character that its own reader had eaten: a trailing space.
func osaRaw(_ script: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    try? p.run()
    let out = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    var text = String(data: out, encoding: .utf8) ?? ""
    if text.hasSuffix("\n") { text.removeLast() }
    return text
}

/// The document is addressed by NAME, not by index: if TextEdit ever opens a
/// second window, "document 1" silently becomes the wrong one and every read
/// comes back empty — which reads like character loss and is not.
let docName = scratch.lastPathComponent

/// Close the document and remove the file, then exit. `defer` does not run on
/// `exit()`, which is how a failed run used to leave its window behind.
func finish(_ code: Int32) -> Never {
    osa("tell application \"TextEdit\" to close document \"\(docName)\" saving no")
    try? FileManager.default.removeItem(at: scratch)
    exit(code)
}

func openScratch() {
    try? "".write(to: scratch, atomically: true, encoding: .utf8)
    osa("tell application \"TextEdit\" to open POSIX file \"\(scratch.path)\"")
    // Opening is not instant. Wait until the document really exists instead of
    // pasting at a window that is not there yet.
    for _ in 0..<25 {
        if osa("tell application \"TextEdit\" to get name of every document").contains(docName) { break }
        Thread.sleep(forTimeInterval: 0.2)
    }
    guard osa("tell application \"TextEdit\" to get name of every document").contains(docName) else {
        print("ABORT: TextEdit did not open the scratch document — nothing was measured.")
        finish(2)
    }
    focusScratch()
}

/// Bringing another app to the front is not instant and not guaranteed on the
/// first try — the app that had focus can take it back. So: ask, wait, verify,
/// repeat. Giving up loudly beats measuring the wrong window.
func focusScratch() {
    for attempt in 1...6 {
        osa("tell application \"TextEdit\" to activate")
        if attempt > 2 {
            // Politeness didn't work; insist via System Events.
            osa("tell application \"System Events\" to set frontmost of process \"TextEdit\" to true")
        }
        Thread.sleep(forTimeInterval: 0.6)
        if frontmostApp() == "TextEdit" { clickIntoDocument(); return }
    }
}

/// Frontmost is not the same as "the text view will receive keystrokes" —
/// AppleScript can fill a document without ever giving it an insertion point, and
/// then every pasted character goes nowhere. One click into the window settles it.
func clickIntoDocument() {
    let bounds = osa("""
        tell application "System Events" to tell process "TextEdit"
            set p to position of window 1
            set s to size of window 1
            return (item 1 of p) & "," & (item 2 of p) & "," & (item 1 of s) & "," & (item 2 of s)
        end tell
        """)
    let parts = bounds.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard parts.count == 4 else { return }
    // Well inside the text area: below the title bar, away from every edge.
    let point = CGPoint(x: parts[0] + parts[2] / 2, y: parts[1] + parts[3] / 2)
    for down in [true, false] {
        let event = CGEvent(mouseEventSource: source, mouseType: down ? .leftMouseDown : .leftMouseUp,
                            mouseCursorPosition: point, mouseButton: .left)
        event?.post(tap: .cgAnnotatedSessionEventTap)
        usleep(60_000)
    }
    Thread.sleep(forTimeInterval: 0.3)
}

func frontmostApp() -> String {
    osa("tell application \"System Events\" to get name of first application process whose frontmost is true")
}

func setScratch(_ text: String) {
    let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    osa("tell application \"TextEdit\" to set text of document \"\(docName)\" to \"\(escaped)\"")
    Thread.sleep(forTimeInterval: 0.3)
}

func readScratch() -> String {
    Thread.sleep(forTimeInterval: 0.6)   // let the target finish handling events
    return osaRaw("tell application \"TextEdit\" to get text of document \"\(docName)\"")
}

/// The precondition, checked before EVERY case rather than assumed once.
///
/// Without this the probe reported "the clipboard path lost characters" when in
/// truth the window had lost focus and nothing was typed anywhere — a false
/// accusation against the app, from its own test. A check that cannot tell its
/// own failure from the app's is worse than no check.
func requireWorkingTarget(_ label: String) {
    focusScratch()
    let front = frontmostApp()
    guard front == "TextEdit" else {
        print("ABORT (\(label)): TextEdit is not frontmost — \(front) is. Nothing was measured.")
        finish(2)
    }
    // The control goes in through the SAME route the measurement uses — a
    // clipboard paste. Writing via AppleScript would prove only that AppleScript
    // works, while the window might still have no insertion point, and every
    // measurement would come back empty and look like total character loss.
    let control = "Kontrolle Größe ÄÖÜ"
    for attempt in 1...4 {
        setScratch("")
        pasteViaClipboard(control)
        if readScratch() == control { setScratch(""); return }
        if attempt == 4 {
            print("ABORT (\(label)): the window does not accept keystrokes — nothing was measured.")
            print("  control text never arrived after 4 attempts.")
            finish(2)
        }
        focusScratch()
    }
}

// --- The two mechanisms, copied from OutputService so the check exercises what
// --- the app actually does rather than an idealised version of it.


func typeDirectly(_ text: String) {
    for character in text {
        var utf16 = Array(character.utf16)
        guard !utf16.isEmpty else { continue }
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        down?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        up?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
        Thread.sleep(forTimeInterval: 0.005)
    }
}

func pasteViaClipboard(_ text: String) {
    let saved = NSPasteboard.general.string(forType: .string)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
    down?.flags = .maskCommand
    let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
    up?.flags = .maskCommand
    down?.post(tap: .cgAnnotatedSessionEventTap)
    up?.post(tap: .cgAnnotatedSessionEventTap)
    Thread.sleep(forTimeInterval: 0.5)
    if let saved { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(saved, forType: .string) }
}

/// Reports where the first difference is — "3 characters missing" is useless, the
/// position and the neighbours are what identify the mechanism.
func compare(_ expected: String, _ got: String) -> String? {
    if expected == got { return nil }
    let e = Array(expected), g = Array(got)
    var i = 0
    while i < min(e.count, g.count), e[i] == g[i] { i += 1 }
    let context = String(e[max(0, i - 12)..<min(e.count, i + 12)])
    return "differs at character \(i) of \(e.count) (got \(g.count)) — around: …\(context)…"
}

// --- Cases: short text is the one the old code typed directly, umlauts are what
// --- the user notices first, and long text is where a queue overruns.
let cases: [(name: String, text: String)] = [
    ("short (was the dangerous case)", "Größe prüfen, Straße!"),
    ("umlauts and punctuation", "Der Fluß fließt weiß — ÄÖÜ äöü ß, 0123456789. Grüße!"),
    ("long", String(repeating: "Die Prüfung läuft für Steneo, größer als dreißig Zeichen. ", count: 6)),
]

/// Send the text and read back what arrived.
///
/// NOTHING arriving is not character loss — lost characters leave the rest
/// behind. It means the window lost focus between the control paste and the
/// measurement, which happened on 19.11.2026 in the first seconds of a run
/// (0 of 21 on both routes, the next four cases exact). So an empty result is
/// re-established and measured once more; a second empty result, or any
/// partial one, stands as a failure.
func measured(_ label: String, _ text: String, _ send: (String) -> Void) -> String {
    requireWorkingTarget(label)
    send(text)
    let got = readScratch()
    guard got.isEmpty else { return got }
    print("note  \(label): nothing arrived (frontmost now: \(frontmostApp())) — focus was lost, measuring once more")
    requireWorkingTarget(label)
    send(text)
    return readScratch()
}

openScratch()

var clipboardFailures = 0
var typingFailures = 0

for (name, text) in cases {
    if let problem = compare(text, measured("clipboard · \(name)", text, pasteViaClipboard)) {
        print("FAIL  clipboard · \(name): \(problem)")
        clipboardFailures += 1
    } else {
        print("ok    clipboard · \(name) — \(text.count) characters exact")
    }

    if let problem = compare(text, measured("typing · \(name)", text, typeDirectly)) {
        print("LOSSY typing    · \(name): \(problem)")
        typingFailures += 1
    } else {
        print("ok    typing    · \(name) — \(text.count) characters exact")
    }
}

print("")
print("clipboard (what Auto uses): \(cases.count - clipboardFailures)/\(cases.count) exact")
print("direct typing (opt-in):     \(cases.count - typingFailures)/\(cases.count) exact")
if clipboardFailures > 0 {
    print("RESULT: FAILED — the path Auto uses lost characters. Do not ship.")
    finish(1)
}
print("RESULT: PASS — the path Auto uses is character-exact.")
finish(0)
