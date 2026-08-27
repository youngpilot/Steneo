import AppKit
import Foundation

/// Check B of the release gate: press the shortcut, speak, text arrives.
///
/// This is the chain the product IS, and between 1.3.1 and 1.5.1 nobody ran it
/// once — three releases went out on a pipeline that verified notarisation and
/// Gatekeeper while the app quietly stopped inserting text. Unit tests cannot see
/// it: the chain crosses a hotkey monitor, an audio engine, a speech model, and
/// another process.
///
/// It is deliberately disruptive: it un-mutes, raises the volume, speaks out loud
/// and moves the mouse. Every setting it touches is restored, including on abort.
///
/// It also reports WHERE the chain broke by reading Steneo's own log, because
/// "no text arrived" has four very different causes and guessing between them is
/// what cost days.

/// Two utterances, and the SHORT one is not decoration.
///
/// The first version of this gate spoke only a long sentence — and a long
/// sentence goes through the clipboard, which was never the broken path. It
/// passed against the very build that was dropping characters. A gate that
/// cannot catch the bug it was built for is not a gate.
///
/// Under 30 characters is what the old code typed key by key, so that is where
/// the failure lives.
let utterances: [(label: String, text: String)] = [
    ("short (under 30 characters — the path that dropped letters)", "Good morning everyone"),
    ("long (goes through the clipboard)", "The quick brown fox jumps over the lazy dog near the river bank"),
]
let minimumRecall = 0.5   // set before the first run: half the words must survive

// MARK: - Small helpers

let source = CGEventSource(stateID: .hidSystemState)

@discardableResult
func run(_ path: String, _ args: [String], trim: Bool = true) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    try? p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    var out = String(data: data, encoding: .utf8) ?? ""
    if trim { out = out.trimmingCharacters(in: .whitespacesAndNewlines) }
    else if out.hasSuffix("\n") { out.removeLast() }
    return out
}

@discardableResult
func osa(_ script: String, trim: Bool = true) -> String { run("/usr/bin/osascript", ["-e", script], trim: trim) }
func defaultsRead(_ key: String) -> String? {
    let v = run("/usr/bin/defaults", ["read", "com.youngpilot.Steneo", key])
    return v.contains("does not exist") || v.isEmpty ? nil : v
}
func defaultsWrite(_ key: String, bool value: Bool) {
    run("/usr/bin/defaults", ["write", "com.youngpilot.Steneo", key, "-bool", value ? "true" : "false"])
}
func defaultsDelete(_ key: String) { run("/usr/bin/defaults", ["delete", "com.youngpilot.Steneo", key]) }

// MARK: - Restore whatever we change, whatever happens

let candidatePath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/Applications/Steneo.app"
let restoreInstalled = candidatePath != "/Applications/Steneo.app"

let savedVolume = osa("output volume of (get volume settings)")
let savedSilence = defaultsRead("silenceMediaWhileRecording")
let savedPause = defaultsRead("pauseMediaApps")
var restored = false

func restoreEverything() {
    guard !restored else { return }
    restored = true
    if restoreInstalled {
        osa("tell application \"Steneo\" to quit")
        Thread.sleep(forTimeInterval: 2)
        run("/usr/bin/pkill", ["-x", "Steneo"])
        run("/usr/bin/open", ["-a", "/Applications/Steneo.app"])
        print("· installed Steneo put back")
    }
    if let savedSilence { run("/usr/bin/defaults", ["write", "com.youngpilot.Steneo", "silenceMediaWhileRecording", "-bool", savedSilence == "1" ? "true" : "false"]) }
    else { defaultsDelete("silenceMediaWhileRecording") }
    if let savedPause { run("/usr/bin/defaults", ["write", "com.youngpilot.Steneo", "pauseMediaApps", "-bool", savedPause == "1" ? "true" : "false"]) }
    else { defaultsDelete("pauseMediaApps") }
    if let v = Int(savedVolume) { osa("set volume output volume \(v)") }
    print("· settings and volume restored")
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    print(message)
    restoreEverything()
    exit(code)
}

// MARK: - Preconditions, checked rather than assumed

let hotkeys = run("/usr/bin/defaults", ["read", "com.youngpilot.Steneo", "hotkeys"])
guard hotkeys.contains("doubleRightCmd") else {
    fail("ABORT: this check drives the double-press Right ⌘ shortcut, which is not enabled. Nothing was measured.", code: 2)
}

print("=== Check B · press, speak, text arrives ===")
print("· un-muting and speaking out loud; everything is restored afterwards")

defaultsWrite("silenceMediaWhileRecording", bool: false)   // otherwise Steneo mutes our own voice
defaultsWrite("pauseMediaApps", bool: false)
osa("set volume output volume 45")

// Which bundle is under test. As a release gate this MUST be the freshly built
// app, not whatever happens to be installed — otherwise the gate blesses a
// different binary than the one being shipped. Two copies cannot run at once
// (both would grab the shortcut and cancel each other out), so the installed one
// is stopped for the duration and put back at the end.
let candidate = candidatePath
print("· testing bundle: \(candidate)")

osa("tell application \"Steneo\" to quit")
Thread.sleep(forTimeInterval: 3)
run("/usr/bin/pkill", ["-x", "Steneo"])
Thread.sleep(forTimeInterval: 1)
run("/usr/bin/open", ["-a", candidate])
print("· waiting for the speech model to load")
Thread.sleep(forTimeInterval: 22)
guard !run("/usr/bin/pgrep", ["-x", "Steneo"]).isEmpty else {
    fail("ABORT: Steneo is not running. Nothing was measured.", code: 2)
}

// MARK: - A target that can actually receive text

let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("steneo-core-chain.txt")
let docName = scratch.lastPathComponent
try? "".write(to: scratch, atomically: true, encoding: .utf8)
osa("tell application \"TextEdit\" to open POSIX file \"\(scratch.path)\"")

func frontmost() -> String { osa("tell application \"System Events\" to get name of first application process whose frontmost is true") }
func readDoc() -> String { osa("tell application \"TextEdit\" to get text of document \"\(docName)\"", trim: false) }
func setDoc(_ text: String) { osa("tell application \"TextEdit\" to set text of document \"\(docName)\" to \"\(text)\""); Thread.sleep(forTimeInterval: 0.3) }

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
    let point = CGPoint(x: parts[0] + parts[2] / 2, y: parts[1] + parts[3] / 2)
    for down in [true, false] {
        CGEvent(mouseEventSource: source, mouseType: down ? .leftMouseDown : .leftMouseUp,
                mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cgAnnotatedSessionEventTap)
        usleep(60_000)
    }
    Thread.sleep(forTimeInterval: 0.3)
}

func focusTarget() {
    for attempt in 1...6 {
        osa("tell application \"TextEdit\" to activate")
        if attempt > 2 { osa("tell application \"System Events\" to set frontmost of process \"TextEdit\" to true") }
        Thread.sleep(forTimeInterval: 0.6)
        if frontmost() == "TextEdit" { clickIntoDocument(); return }
    }
}

/// The same positive control as check A: prove the window takes keystrokes before
/// blaming the app for text that never arrives.
func requireWritableTarget() {
    let control = "Kontrolle"
    for attempt in 1...4 {
        focusTarget()
        setDoc("")
        let saved = NSPasteboard.general.string(forType: .string)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(control, forType: .string)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: down)
            e?.flags = .maskCommand
            e?.post(tap: .cgAnnotatedSessionEventTap)
        }
        Thread.sleep(forTimeInterval: 0.6)
        if let saved { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(saved, forType: .string) }
        if readDoc() == control { setDoc(""); return }
        if attempt == 4 {
            fail("ABORT: the target window does not accept keystrokes — nothing was measured.", code: 2)
        }
    }
}

requireWritableTarget()

// MARK: - The chain

func doubleTapRightCommand() {
    for _ in 0..<2 {
        let down = CGEvent(keyboardEventSource: source, virtualKey: 54, keyDown: true)!
        down.type = .flagsChanged; down.flags = [.maskCommand]; down.post(tap: .cghidEventTap)
        usleep(60_000)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 54, keyDown: true)!
        up.type = .flagsChanged; up.flags = []; up.post(tap: .cghidEventTap)
        usleep(150_000)
    }
}

func words(_ s: String) -> Set<String> {
    Set(s.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count > 2 })
}

var failures: [String] = []

for (label, spoken) in utterances {
    print("")
    print("— \(label)")
    requireWritableTarget()
    let started = Date()
    doubleTapRightCommand()
    Thread.sleep(forTimeInterval: 1.5)
    print("· speaking: \"\(spoken)\"")
    run("/usr/bin/say", ["-r", "170", spoken])
    Thread.sleep(forTimeInterval: 1.0)
    doubleTapRightCommand()
    Thread.sleep(forTimeInterval: 15)

    let arrived = readDoc()
    let since = String(ISO8601DateFormatter().string(from: started.addingTimeInterval(-2)).prefix(19))
        .replacingOccurrences(of: "T", with: " ")
    let logText = run("/usr/bin/log", ["show", "--start", since, "--info",
                                       "--predicate", "subsystem == \"com.youngpilot.Steneo\"", "--style", "compact"])
    let sawStart = logText.contains("Target app")
    let sawTranscript = logText.contains("final transcript")
    let sawInsert = logText.contains("insertText")

    let expected = words(spoken)
    let got = words(arrived)
    let hits = expected.intersection(got).count
    let recall = expected.isEmpty ? 0 : Double(hits) / Double(expected.count)

    print("  shortcut fired: \(sawStart ? "yes" : "NO") · transcript: \(sawTranscript ? "yes" : "NO") · inserted: \(sawInsert ? "yes" : "NO")")
    print("  arrived (\(arrived.count) characters): \(arrived.isEmpty ? "—" : arrived)")
    print(String(format: "  word recall: %.0f%% (%d of %d)", recall * 100, hits, expected.count))

    if !sawStart { failures.append("\(label): the shortcut never started a recording") }
    else if !sawTranscript { failures.append("\(label): recording ran but produced no transcript") }
    else if !sawInsert { failures.append("\(label): transcript existed but nothing was inserted") }
    else if arrived.isEmpty { failures.append("\(label): Steneo inserted, nothing reached the window") }
    else if recall < minimumRecall {
        failures.append(String(format: "%@: only %.0f%% of the words survived (bar: %.0f%%) — arrived: %@",
                               label, recall * 100, minimumRecall * 100, arrived))
    }
}

osa("tell application \"TextEdit\" to close document \"\(docName)\" saving no")
try? FileManager.default.removeItem(at: scratch)
restoreEverything()

print("")
if failures.isEmpty {
    print("RESULT: PASS — press, speak, text arrives, short and long.")
} else {
    for f in failures { print("FAILED · \(f)") }
    print("RESULT: FAILED — the core chain is broken.")
    exit(1)
}
