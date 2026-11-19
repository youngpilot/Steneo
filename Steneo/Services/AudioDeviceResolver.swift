import CoreAudio
import Foundation
import os

private let logger = Logger(subsystem: "com.youngpilot.Steneo", category: "AudioDevice")

/// One input device as CoreAudio currently sees it.
///
/// `id` is deliberately NOT the identity: an `AudioDeviceID` is a transient
/// handle. Unplug a USB microphone and plug it back in and the same physical
/// device comes back under a different number. Steneo used to let AVAudioEngine
/// remember one of these; when it went stale the engine asked for a device that
/// no longer existed, fell back to something without an input, and every
/// recording failed with `'!dev'`. The stable identity is `uid`.
struct AudioDevice: Equatable, Identifiable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let inputChannels: Int
    /// Bluetooth microphones are a trap: the moment anything opens them as an
    /// input, macOS drops the headset out of high-quality playback into the
    /// bidirectional call profile. Recording through AirPods therefore wrecks
    /// the music you are listening to on the same AirPods.
    let isBluetooth: Bool
    /// The Mac's own microphone: always there on a notebook, needs no cable and
    /// no driver, and is therefore the floor every fallback ends on.
    let isBuiltIn: Bool
    /// The rate the device is running at right now. Part of the change
    /// signature: the same device switching rate is a real change, a repeated
    /// notification about the same rate is not.
    let sampleRate: Double

    init(id: AudioDeviceID, uid: String, name: String, inputChannels: Int,
         isBluetooth: Bool, isBuiltIn: Bool = false, sampleRate: Double) {
        self.id = id
        self.uid = uid
        self.name = name
        self.inputChannels = inputChannels
        self.isBluetooth = isBluetooth
        self.isBuiltIn = isBuiltIn
        self.sampleRate = sampleRate
    }

    var hasInput: Bool { inputChannels > 0 }

    /// Identity + current shape. Two readings with the same signature describe
    /// the same input, and rebuilding for them would be churn.
    var signature: String { "\(uid)|\(sampleRate)|\(inputChannels)" }
}

/// Resolves which microphone a recording should use — freshly, every time.
///
/// Everything that decides is a pure function over a device list, so it can be
/// tested without hardware; only `snapshot()` touches CoreAudio.
enum AudioDeviceResolver {

    /// Why a device is in the running. Surfaced so a fallback is visible instead
    /// of silent.
    enum Source: String, Equatable, Sendable {
        case chosen = "chosen device"
        case systemDefault = "system default"
        case builtIn = "built-in microphone"
        case other = "other input"
        case lastResort = "last remaining input"
    }

    struct Resolution: Equatable, Sendable {
        let device: AudioDevice
        let source: Source
    }

    /// The input hardware at one moment, read in ONE pass. A start used to
    /// enumerate every device six times over.
    struct Snapshot: Equatable, Sendable {
        let inputs: [AudioDevice]
        let systemDefaultUID: String?

        var builtInUID: String? {
            // Transport type is the reliable signal; the UID spelling is the safety net.
            (inputs.first(where: \.isBuiltIn) ?? inputs.first { $0.uid.contains("BuiltInMicrophone") })?.uid
        }

        /// Which devices exist and which one the system prefers. When this is
        /// unchanged, a device that just failed has no reason to work now.
        var fingerprint: String {
            inputs.map(\.uid).sorted().joined(separator: ",") + "|" + (systemDefaultUID ?? "-")
        }
    }

    /// A device that did not start, and the hardware state it failed in.
    struct Failure: Equatable, Sendable {
        let uid: String
        let at: TimeInterval
        let fingerprint: String
    }

    /// How long a failed device is passed over while nothing about the hardware
    /// changes. Long enough that a broken device does not cost every recording
    /// its timeout, short enough that one that recovered on its own comes back.
    static let failureMemory: TimeInterval = 120

    // MARK: - Deciding (pure)

    /// Every usable input, in the order it should be tried: the device the user
    /// picked (by UID) → every other wired input, the one that starts fastest
    /// first → Bluetooth, last.
    ///
    /// "Automatic" therefore means the microphone with the least delay. A
    /// device's delay is what was measured for it (`startTimes`, milliseconds by
    /// UID). Unmeasured, the Mac's own counts as fastest, because it is, and
    /// anything else as slowest, with the system default ahead among equals.
    ///
    /// A LIST, not a single answer, because "the right device" can be present
    /// and still refuse to start. Until 1.6 that case retried the same device
    /// once and gave up, with a working built-in microphone sitting unused.
    static func candidates(
        preferredUID: String?,
        available: [AudioDevice],
        systemDefaultUID: String?,
        builtInUID: String?,
        startTimes: [String: Double] = [:]
    ) -> [Resolution] {
        let usable = available.filter(\.hasInput)
        var result: [Resolution] = []
        func add(_ device: AudioDevice?, _ source: Source) {
            guard let device, !result.contains(where: { $0.device.uid == device.uid }) else { return }
            result.append(Resolution(device: device, source: source))
        }
        func find(_ uid: String?) -> AudioDevice? {
            guard let uid, !uid.isEmpty else { return nil }
            return usable.first { $0.uid == uid }
        }
        // An explicit choice always comes first, Bluetooth included — it is the
        // user's headset and their decision.
        add(find(preferredUID), .chosen)
        // Everything below is Steneo choosing, and Steneo does not choose
        // Bluetooth while anything else exists: taking a headset as the
        // microphone costs its playback quality, which is a bad trade to make on
        // someone's behalf.
        func isBuiltIn(_ d: AudioDevice) -> Bool { d.isBuiltIn || d.uid == builtInUID }
        func delay(_ d: AudioDevice) -> Double { startTimes[d.uid] ?? (isBuiltIn(d) ? 0 : .infinity) }
        let wired = usable.enumerated().filter { !$0.element.isBluetooth }.sorted { a, b in
            let (da, db) = (delay(a.element), delay(b.element))
            if da != db { return da < db }
            let (sa, sb) = (a.element.uid == systemDefaultUID, b.element.uid == systemDefaultUID)
            return sa != sb ? sa : a.offset < b.offset
        }
        for (_, d) in wired {
            add(d, isBuiltIn(d) ? .builtIn : d.uid == systemDefaultUID ? .systemDefault : .other)
        }
        // Nothing else worked or exists: a Bluetooth microphone beats no recording.
        for d in usable { add(d, .lastResort) }
        return result
    }

    /// The first candidate. Returns nil only when the machine has no usable
    /// input, which is a real error and must be reported, never swallowed.
    static func resolve(
        preferredUID: String?,
        available: [AudioDevice],
        systemDefaultUID: String?,
        builtInUID: String?,
        startTimes: [String: Double] = [:]
    ) -> Resolution? {
        candidates(preferredUID: preferredUID, available: available, systemDefaultUID: systemDefaultUID,
                   builtInUID: builtInUID, startTimes: startTimes).first
    }

    /// Which recent failures still count: same hardware state, and recent.
    static func activeFailures(_ failures: [Failure], now: TimeInterval, fingerprint: String) -> Set<String> {
        Set(failures.filter { $0.fingerprint == fingerprint && now - $0.at < failureMemory }.map(\.uid))
    }

    /// The order in which to actually try: candidates that failed recently are
    /// passed over — unless that would leave nothing — and the first choice gets
    /// one last attempt after everything else failed, so a Mac with a single
    /// microphone still recovers from a hiccup.
    static func attemptOrder(_ candidates: [Resolution], excluding failed: Set<String>) -> [Resolution] {
        let fresh = candidates.filter { !failed.contains($0.device.uid) }
        let base = fresh.isEmpty ? candidates : fresh
        guard let first = base.first else { return [] }
        return base + [first]
    }

    /// The microphone that records while the first choice is still starting:
    /// the Mac's own, live after about 35 ms where a USB microphone needs 450.
    /// nil when it is the first choice itself, or when there is none (a desktop
    /// Mac, a closed lid) or it is being passed over.
    static func bridge(in order: [Resolution]) -> Resolution? {
        guard let first = order.first, !first.device.isBuiltIn else { return nil }
        return order.first { $0.device.isBuiltIn }
    }

    /// Walk the order until one attempt succeeds. Returns the winner's position
    /// and everything that failed before it, or nil when nothing worked.
    static func firstWorking<T>(_ order: [T], attempt: (T) -> Bool) -> (index: Int, failed: [T])? {
        var failed: [T] = []
        for (index, candidate) in order.enumerated() {
            if attempt(candidate) { return (index, failed) }
            failed.append(candidate)
        }
        return nil
    }

    /// The devices ranked ahead of the winner that are not being used because
    /// they failed — just now, or recently enough to be passed over. Counting
    /// only the attempts of THIS start would announce a fallback once and then
    /// fall silent while every following recording still runs on it.
    static func outranked(by winner: AudioDevice, in candidates: [Resolution], unusable: Set<String>) -> [String] {
        guard let rank = candidates.firstIndex(where: { $0.device.uid == winner.uid }) else { return [] }
        return candidates.prefix(rank).filter { unusable.contains($0.device.uid) }.map(\.device.name)
    }

    /// What to tell the user when the recording is not running on the microphone
    /// they would expect. nil when there is nothing to say — Steneo quietly
    /// preferring the Mac's microphone over a Bluetooth headset is policy, not news.
    static func notice(used: AudioDevice, source: Source, failedNames: [String], preferredName: String?) -> String? {
        if let failed = failedNames.first(where: { $0 != used.name }) {
            return "Recording with \(used.name) – \(failed) didn't respond."
        }
        if let preferredName, !preferredName.isEmpty, source != .chosen {
            return "Recording with \(used.name) – \(preferredName) isn't connected."
        }
        return nil
    }

    /// The one line under the picker, and only when it says something the
    /// picker does not: which microphone "Automatic" landed on, or that the
    /// chosen one is not the one in use. `chosenName` is nil for Automatic.
    static func usageCaption(chosenName: String?, inUse: String?) -> String? {
        guard let inUse else { return "No microphone found." }
        guard let chosenName, !chosenName.isEmpty else { return "Using \(inUse), the fastest to start." }
        return chosenName == inUse ? nil : "Using \(inUse) instead."
    }

    /// A microphone's name with the time it needs before it records, for the
    /// picker. Rounded to 10 ms: the figure varies by that much between starts,
    /// and "430" against "40" is the comparison that matters.
    static func startLabel(name: String, milliseconds: Double?, isBluetooth: Bool) -> String {
        if let milliseconds { return "\(name) · ~\(Int((milliseconds / 10).rounded()) * 10) ms" }
        return isBluetooth ? "\(name) · Bluetooth" : name
    }

    // MARK: - CoreAudio

    /// How long this device takes from "start" to its first audio, in
    /// milliseconds — measured on the device itself, below AVAudioEngine. This
    /// is hardware time: 19.11.2026 gave ~450 ms for a USB display microphone and
    /// ~35 ms for the MacBook's own, and no software on top makes it shorter.
    /// Opens the device for that long, so it is called once per device, on
    /// request, never for Bluetooth. Blocks; call it off the main thread.
    static func measureStart(of device: AudioDevice, timeout: TimeInterval = 3) -> Double? {
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var fired = false
            func fire() -> Bool { lock.lock(); defer { lock.unlock() }; if fired { return false }; fired = true; return true }
        }
        let once = Once()
        let arrived = DispatchSemaphore(value: 0)
        var procID: AudioDeviceIOProcID?
        let created = AudioDeviceCreateIOProcIDWithBlock(&procID, device.id, nil) { _, input, _, _, _ in
            if input.pointee.mNumberBuffers > 0, once.fire() { arrived.signal() }
        }
        guard created == noErr, let procID else { return nil }
        defer { AudioDeviceDestroyIOProcID(device.id, procID) }
        let began = DispatchTime.now()
        guard AudioDeviceStart(device.id, procID) == noErr else { return nil }
        defer { AudioDeviceStop(device.id, procID) }
        guard arrived.wait(timeout: .now() + timeout) == .success else { return nil }
        return Double(DispatchTime.now().uptimeNanoseconds - began.uptimeNanoseconds) / 1_000_000
    }

    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    private static func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// The hardware as it is right now. Property reads only: this opens no device.
    static func snapshot() -> Snapshot {
        let inputs = allDeviceIDs().compactMap(inputDevice(for:))
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let hasDefault = AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &id) == noErr
            && id != kAudioObjectUnknown
        return Snapshot(inputs: inputs,
                        systemDefaultUID: hasDefault ? inputs.first { $0.id == id }?.uid : nil)
    }

    static func candidates(preferredUID: String?, in snapshot: Snapshot,
                           startTimes: [String: Double] = [:]) -> [Resolution] {
        candidates(preferredUID: preferredUID, available: snapshot.inputs, systemDefaultUID: snapshot.systemDefaultUID,
                   builtInUID: snapshot.builtInUID, startTimes: startTimes)
    }

    /// Every device that can record, in CoreAudio's order.
    static func inputDevices() -> [AudioDevice] { snapshot().inputs }

    /// Resolve against the hardware as it is right now.
    static func current(preferredUID: String?, startTimes: [String: Double] = [:]) -> Resolution? {
        candidates(preferredUID: preferredUID, in: snapshot(), startTimes: startTimes).first
    }

    /// nil for anything that cannot record — checked first, so output-only
    /// devices cost one property read instead of six.
    private static func inputDevice(for id: AudioDeviceID) -> AudioDevice? {
        let channels = inputChannels(id)
        guard channels > 0, let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) else { return nil }
        let transport = transportType(for: id)
        return AudioDevice(
            id: id,
            uid: uid,
            name: stringProperty(id, kAudioObjectPropertyName) ?? uid,
            inputChannels: channels,
            isBluetooth: transport == kAudioDeviceTransportTypeBluetooth
                || transport == kAudioDeviceTransportTypeBluetoothLE,
            isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn,
            sampleRate: nominalSampleRate(id))
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &size) == noErr, size > 0
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<UnsafeMutableRawPointer>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func transportType(for id: AudioDeviceID) -> UInt32? {
        var addr = address(kAudioDevicePropertyTransportType)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func nominalSampleRate(_ id: AudioDeviceID) -> Double {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0
        else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
