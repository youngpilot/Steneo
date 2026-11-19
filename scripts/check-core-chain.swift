import AppKit
import AVFoundation
import CoreAudio
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
/// ONE utterance, deliberately.
///
/// This check exists to prove the live chain — shortcut, microphone, model,
/// insertion — and one sentence proves it as well as two. Character fidelity for
/// short AND long text is check A's job, and check A needs no microphone, no
/// speaker and no quiet room. Two utterances doubled the minute this takes and
/// doubled the chances of a noisy room aborting a release, for no extra coverage.
///
/// Under 30 characters, because that is the length the old typing path dropped
/// letters at — if one sentence has to carry the check, it is that one.
let utterances: [(label: String, text: String)] = [
    ("short sentence", "Good morning everyone"),
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

let arguments = Array(CommandLine.arguments.dropFirst())
let useBuiltInSpeakers = arguments.contains("--use-speakers")
let confirmed = arguments.contains("--confirm") || ProcessInfo.processInfo.environment["STENEO_GATE_CONFIRM"] == "1"
let candidatePath = arguments.first(where: { !$0.hasPrefix("--") }) ?? "/Applications/Steneo.app"
let restoreInstalled = candidatePath != "/Applications/Steneo.app"

// This check takes the Mac over for about a minute: it changes the volume,
// speaks out loud, quits the running Steneo and moves focus to TextEdit. It ran
// four times unannounced on 04.09.2026 while the user was working. It does not
// start without being told to any more.
guard confirmed else {
    print("""
          Check B takes over this Mac for about a minute:
            · sets the output volume to 45 and speaks two sentences out loud
            · quits the running Steneo and starts the build under test instead
            · brings TextEdit to the front and types into it
          Everything is put back afterwards.

          It needs speakers — with headphones the microphone cannot hear the Mac
          and the check has nothing to measure.

          Run it with --confirm (or STENEO_GATE_CONFIRM=1) when the Mac is free.
          """)
    exit(3)
}

/// Read AFTER any output-device switch, because it belongs to whichever device
/// will actually be turned up — and because AppleScript returns `missing value`
/// for the volume of some devices, which is how it got left at 45 on 04.09.2026.
var savedVolume = ""
let savedSilence = defaultsRead("silenceMediaWhileRecording")
let savedPause = defaultsRead("pauseMediaApps")
/// Only put back what was actually taken. An abort in the preconditions used to
/// quit and relaunch the user's Steneo for no reason at all.
var changedSettings = false
var swappedApp = false
var restored = false
/// The output device as we found it, so a temporary switch to the speakers can
/// be undone — including on abort. Assigned at the moment of switching, not at
/// script start: top-level order in a script is a trap, and reading it too early
/// silently produced nil and left the user on the wrong output device.
var originalOutputDevice: AudioDeviceID?
var switchedOutput = false

func restoreEverything() {
    guard !restored else { return }
    restored = true
    guard changedSettings || swappedApp else { return }   // nothing was taken

    if swappedApp {
        osa("tell application \"Steneo\" to quit")
        Thread.sleep(forTimeInterval: 2)
        run("/usr/bin/pkill", ["-x", "Steneo"])
        run("/usr/bin/open", ["-a", "/Applications/Steneo.app"])
        print("· installed Steneo put back")
    }
    guard changedSettings else { return }

    if let savedSilence { run("/usr/bin/defaults", ["write", "com.youngpilot.Steneo", "silenceMediaWhileRecording", "-bool", savedSilence == "1" ? "true" : "false"]) }
    else { defaultsDelete("silenceMediaWhileRecording") }
    if let savedPause { run("/usr/bin/defaults", ["write", "com.youngpilot.Steneo", "pauseMediaApps", "-bool", savedPause == "1" ? "true" : "false"]) }
    else { defaultsDelete("pauseMediaApps") }

    // Read it back. The old version printed "volume restored" and left it at 45,
    // because a restore that is never checked is a hope, not a restore.
    if let wanted = Int(savedVolume) {
        osa("set volume output volume \(wanted)")
        Thread.sleep(forTimeInterval: 0.3)
        let now = Int(osa("output volume of (get volume settings)")) ?? -1
        if now == wanted {
            print("· settings and volume restored (volume \(wanted))")
        } else {
            print("· settings restored — WARNING: volume is \(now), it was \(wanted) before. Please set it back.")
        }
    } else {
        print("· settings restored — WARNING: the original volume could not be read, so it was not changed back.")
    }

    if switchedOutput, let original = originalOutputDevice {
        setDefaultOutputDevice(original)
        Thread.sleep(forTimeInterval: 0.5)
        let now = defaultOutputDevice()
        print(now == original
              ? "· output device back on \(deviceName(original))"
              : "· WARNING: could not switch the output device back to \(deviceName(original)). Please set it in Sound settings.")
    }
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    print(message)
    restoreEverything()
    exit(code)
}

// MARK: - Can this Mac even hear itself? (the check that was missing)
//
// On 04.09.2026 this gate reported "RESULT: FAILED — the core chain is broken"
// four times while the user was wearing AirPods. The spoken words went into his
// ears, the microphone heard nothing, and the script turned its own broken
// premise into an accusation against the app. A control run against the
// installed, working build failed identically — which is what finally proved the
// measurement was at fault, not the product.
//
// Same class as the three false alarms in check-insertion.swift. So the same
// answer: verify the precondition through the very path being measured, and
// abort loudly instead of blaming anything.

var sysObj: AudioObjectID { AudioObjectID(kAudioObjectSystemObject) }

func audioAddress(_ selector: AudioObjectPropertySelector,
                  _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func defaultOutputDevice() -> AudioDeviceID? {
    var addr = audioAddress(kAudioHardwarePropertyDefaultOutputDevice)
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(sysObj, &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
    return id
}

func deviceName(_ id: AudioDeviceID) -> String {
    var addr = audioAddress(kAudioObjectPropertyName)
    var size = UInt32(MemoryLayout<UnsafeMutableRawPointer>.size)
    var value: Unmanaged<CFString>?
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let value else { return "?" }
    return value.takeRetainedValue() as String
}

func deviceTransport(_ id: AudioDeviceID) -> UInt32 {
    var addr = audioAddress(kAudioDevicePropertyTransportType)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return 0 }
    return value
}

/// The built-in output reports which physical outlet it is using. 'hdpn' is the
/// headphone jack: audible to exactly one person, and not to the microphone.
func outputIsHeadphoneJack(_ id: AudioDeviceID) -> Bool {
    var addr = audioAddress(kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return false }
    return value == 0x68647063 /* 'hdpc' */ || value == 0x6864706E /* 'hdpn' */
}

func allAudioDeviceIDs() -> [AudioDeviceID] {
    var addr = audioAddress(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(sysObj, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(sysObj, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func outputChannels(_ id: AudioDeviceID) -> Int {
    var addr = audioAddress(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
    return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        .reduce(0) { $0 + Int($1.mNumberChannels) }
}

func defaultInputDevice() -> AudioDeviceID? {
    var addr = audioAddress(kAudioHardwarePropertyDefaultInputDevice)
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(sysObj, &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
    return id
}

/// Which speakers to measure through.
///
/// Preferably the ones in the same box as the microphone — a Studio Display's
/// speakers sit centimetres from its microphone, while the Mac's own speakers
/// have to carry across the desk and barely register. Otherwise the built-in
/// speakers, which are always there.
func speakersForMeasurement() -> AudioDeviceID? {
    let outputs = allAudioDeviceIDs().filter {
        outputChannels($0) > 0
            && !outputIsHeadphoneJack($0)
            && deviceTransport($0) != kAudioDeviceTransportTypeBluetooth
            && deviceTransport($0) != kAudioDeviceTransportTypeBluetoothLE
            && deviceTransport($0) != kAudioDeviceTransportTypeVirtual
            && deviceTransport($0) != kAudioDeviceTransportTypeAggregate
    }
    // "Studio Display-Mikrofon" and "Studio Display-Lautsprecher" share a prefix;
    // that shared prefix is the physical enclosure, which is what matters here.
    if let input = defaultInputDevice() {
        let inputName = deviceName(input)
        let prefix = inputName.split(separator: "-").first.map(String.init) ?? inputName
        if prefix.count >= 4, let sameBox = outputs.first(where: { deviceName($0).hasPrefix(prefix) }) {
            return sameBox
        }
    }
    return outputs.first { deviceTransport($0) == kAudioDeviceTransportTypeBuiltIn }
}

@discardableResult
func setDefaultOutputDevice(_ id: AudioDeviceID) -> Bool {
    var addr = audioAddress(kAudioHardwarePropertyDefaultOutputDevice)
    var value = id
    return AudioObjectSetPropertyData(sysObj, &addr, 0, nil,
                                      UInt32(MemoryLayout<AudioDeviceID>.size), &value) == noErr
}

/// Loudness of the default input over `seconds`, as RMS. No speaking, no
/// settings touched — this only listens.
func inputLoudness(seconds: TimeInterval, whileDoing action: (() -> Void)? = nil) -> Float? {
    let engine = AVAudioEngine()
    let format = engine.inputNode.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else { return nil }
    let lock = NSLock()
    var sumSquares: Double = 0
    var frames = 0
    engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
        guard let data = buffer.floatChannelData else { return }
        var local: Double = 0
        for i in 0..<Int(buffer.frameLength) { local += Double(data[0][i] * data[0][i]) }
        lock.lock(); sumSquares += local; frames += Int(buffer.frameLength); lock.unlock()
    }
    do { engine.prepare(); try engine.start() } catch { return nil }
    action?()
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    engine.stop()
    engine.inputNode.removeTap(onBus: 0)
    lock.lock(); defer { lock.unlock() }
    guard frames > 0 else { return nil }
    return Float((sumSquares / Double(frames)).squareRoot())
}

/// Refuse before touching a single setting if the sound cannot reach the mic.
func requireTheMicrophoneCanHearTheSpeaker() {
    // This check listens with its OWN process, and macOS hands a process without
    // microphone permission pure zeros instead of an error. On 19.11.2026 that
    // read as "room 0.0000, speaking 0.0000 — headphones?" when the truth was
    // that the app running this script had lost its permission.
    let permission = AVCaptureDevice.authorizationStatus(for: .audio)
    guard permission == .authorized else {
        fail("""
             ABORT: this check itself may not use the microphone (the app that runs it —
             Terminal, or Claude — has no microphone permission, so macOS feeds it silence).
             Allow it in System Settings > Privacy & Security > Microphone and run again.
             NOTHING WAS MEASURED — this says nothing about the build.
             """, code: 2)
    }
    // Asked to: put the sound where the microphone can hear it, and remember to
    // put it back. Without this the check simply refuses on any setup whose
    // output the mic cannot reach — headphones, an interface, a virtual device.
    if useBuiltInSpeakers, let speakers = speakersForMeasurement(), speakers != defaultOutputDevice() {
        originalOutputDevice = defaultOutputDevice()
        let from = originalOutputDevice.map(deviceName) ?? "?"
        if setDefaultOutputDevice(speakers) {
            switchedOutput = true
            changedSettings = true   // so restoreEverything actually runs
            Thread.sleep(forTimeInterval: 1.0)
            print("· output switched from \(from) to \(deviceName(speakers)) for the measurement")
        }
    }

    guard let out = defaultOutputDevice() else {
        fail("ABORT: no audio output device. Nothing was measured.", code: 2)
    }
    let name = deviceName(out)
    let transport = deviceTransport(out)
    if transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE {
        fail("""
             ABORT: audio output goes to a Bluetooth device (\(name)).
             This check speaks out loud and needs the microphone to hear it, so it cannot
             measure anything through headphones. Switch output to speakers and run it again.
             NOTHING WAS MEASURED — this says nothing about the app.
             """, code: 2)
    }
    if outputIsHeadphoneJack(out) {
        fail("""
             ABORT: audio output goes to the headphone jack (\(name)).
             NOTHING WAS MEASURED — this says nothing about the app.
             """, code: 2)
    }
    if transport == kAudioDeviceTransportTypeVirtual || transport == kAudioDeviceTransportTypeAggregate {
        fail("ABORT: audio output is a virtual device (\(name)), which the microphone cannot hear. Nothing was measured.", code: 2)
    }
    // Turn it up BEFORE listening. The first version measured at whatever volume
    // happened to be set, so quiet speakers looked exactly like headphones.
    savedVolume = osa("output volume of (get volume settings)")
    guard Int(savedVolume) != nil else {
        fail("""
             ABORT: macOS will not report the volume of \(name), so it cannot be turned up
             for the measurement or put back afterwards. Nothing was changed.
             """, code: 2)
    }
    changedSettings = true
    osa("set volume output volume 60")
    Thread.sleep(forTimeInterval: 0.5)

    // Device type is not proof. Measure it: how loud is the room, and how much
    // louder does it get when the Mac speaks? Real speakers are unmistakable;
    // leakage from a headset is not.
    // The floor over THREE short windows, taking the quietest. A single window
    // measured right after switching the output device catches the switch pop, a
    // notification, or someone saying a word — and a poisoned floor makes real
    // speakers look like headphones. That happened on the first run of this check
    // against 1.4.4: floor 0.0219 where the room was actually 0.0010.
    // Let the hardware settle first. Switching the output device and turning the
    // volume up both make noise of their own, and the floor is measured right
    // after — on 04.09.2026 that produced a floor of 0.0240 where the room was
    // actually 0.0010, which aborted a release for nothing.
    Thread.sleep(forTimeInterval: 1.5)
    var floors: [Float] = []
    for _ in 0..<3 {
        guard let sample = inputLoudness(seconds: 0.6) else {
            fail("ABORT: cannot read the microphone, so nothing can be measured.", code: 2)
        }
        floors.append(sample)
    }
    let quiet = floors.min() ?? 0

    // Two attempts: a passing car does not get to fail a release.
    var spoken: Float = 0
    var ratio: Float = 0
    for attempt in 1...2 {
        guard let heard = inputLoudness(seconds: 3.0, whileDoing: {
            run("/usr/bin/say", ["-r", "170", "Steneo microphone check"])
        }) else {
            fail("ABORT: cannot read the microphone, so nothing can be measured.", code: 2)
        }
        spoken = heard
        ratio = quiet > 0 ? heard / quiet : Float.infinity
        print(String(format: "· audibility: room %.4f, speaking %.4f (%.1fx)%@",
                     quiet, spoken, ratio, attempt == 1 ? "" : " [second attempt]"))
        if spoken >= 0.003 && ratio >= 3.0 { break }
        if attempt == 1 { print("· too close to the noise floor — measuring once more") }
    }
    // The ratio is the discriminator: headset leakage does not rise when the Mac
    // speaks (measured 0.7x through AirPods), real speakers do. The floor only
    // guards against an input that hears nothing at all.
    guard spoken >= 0.003, ratio >= 3.0 else {
        fail("""
             ABORT: the microphone does not hear the Mac speaking (room \(String(format: "%.4f", quiet)), \
             speaking \(String(format: "%.4f", spoken))).
             Headphones, a muted or very quiet output, or a microphone somewhere else.
             NOTHING WAS MEASURED — this says nothing about the app.
             """, code: 2)
    }
}

// MARK: - Preconditions, checked rather than assumed

let hotkeys = run("/usr/bin/defaults", ["read", "com.youngpilot.Steneo", "hotkeys"])
guard hotkeys.contains("doubleRightCmd") else {
    fail("ABORT: this check drives the double-press Right ⌘ shortcut, which is not enabled. Nothing was measured.", code: 2)
}

print("=== Check B · press, speak, text arrives ===")
print("· un-muting and speaking out loud; everything is restored afterwards")

// Before anything else: pick an output the microphone can hear, turn it up, and
// prove it actually arrives. Everything this touches is restored.
requireTheMicrophoneCanHearTheSpeaker()

defaultsWrite("silenceMediaWhileRecording", bool: false)   // otherwise Steneo mutes our own voice
defaultsWrite("pauseMediaApps", bool: false)

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
swappedApp = restoreInstalled
run("/usr/bin/open", ["-a", candidate])
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
    // LOCAL time. `ISO8601DateFormatter` emits UTC, and `log show --start` reads
    // whatever it is given as local — so on CEST every window silently began two
    // hours early and swept in evidence from earlier runs. On 04.09.2026 that
    // turned a denial from an hour before into "the microphone is denied" while
    // the recording under test was working perfectly.
    let sinceFormatter = DateFormatter()
    sinceFormatter.locale = Locale(identifier: "en_US_POSIX")
    sinceFormatter.timeZone = TimeZone.current
    sinceFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let since = sinceFormatter.string(from: started.addingTimeInterval(-2))
        .replacingOccurrences(of: "T", with: " ")
    let logText = run("/usr/bin/log", ["show", "--start", since, "--info",
                                       "--predicate", "subsystem == \"com.youngpilot.Steneo\"", "--style", "compact"])
    // The build under test lives at a different path than the installed app, so
    // macOS treats it as a different app for microphone access. Denied means this
    // check has nothing to measure — it says NOTHING about the build. Reporting it
    // as "the core chain is broken" is the same false accusation this gate has
    // already made four times in other forms.
    if logText.contains("Microphone access is denied") {
        fail("""
             ABORT: macOS denies the microphone to the build under test
             (\(candidate)).
             It is a different bundle path than the installed app, so it needs its own
             permission. Grant it in System Settings > Privacy & Security > Microphone,
             or run this check against /Applications/Steneo.app after installing.
             NOTHING WAS MEASURED — this says nothing about the build.
             """, code: 2)
    }
    let sawStart = logText.contains("Target app")
    let sawTranscript = logText.contains("final transcript")
    let sawInsert = logText.contains("insertText")

    let expected = words(spoken)
    let got = words(arrived)
    let hits = expected.intersection(got).count
    let recall = expected.isEmpty ? 0 : Double(hits) / Double(expected.count)

    if recall >= minimumRecall {
        print(String(format: "  arrived: \"%@\" — %.0f%% of the words", arrived, recall * 100))
    } else {
        // Only on failure is the stage breakdown worth the lines: it is the
        // difference between four very different causes.
        print("  shortcut fired: \(sawStart ? "yes" : "NO") · transcript: \(sawTranscript ? "yes" : "NO") · inserted: \(sawInsert ? "yes" : "NO")")
        print("  arrived (\(arrived.count) characters): \(arrived.isEmpty ? "—" : arrived)")
        print(String(format: "  word recall: %.0f%% (%d of %d)", recall * 100, hits, expected.count))
    }

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
    print("RESULT: PASS — press, speak, text arrives.")
} else {
    for f in failures { print("FAILED · \(f)") }
    print("RESULT: FAILED — the core chain is broken.")
    exit(1)
}
