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
    /// The rate the device is running at right now. Part of the change
    /// signature: the same device switching rate is a real change, a repeated
    /// notification about the same rate is not.
    let sampleRate: Double

    var hasInput: Bool { inputChannels > 0 }

    /// Identity + current shape. Two readings with the same signature describe
    /// the same input, and rebuilding for them would be churn.
    var signature: String { "\(uid)|\(sampleRate)|\(inputChannels)" }
}

/// Resolves which microphone a recording should use — freshly, every time.
///
/// The resolution itself is a pure function over a device list so it can be
/// tested without hardware; only `current()` touches CoreAudio.
enum AudioDeviceResolver {

    /// Why the chosen device was chosen. Surfaced so a fallback is visible
    /// instead of silent.
    enum Source: String, Equatable, Sendable {
        case chosen = "chosen device"
        case systemDefault = "system default"
        case builtIn = "built-in microphone"
        case lastResort = "last remaining input"
    }

    struct Resolution: Equatable, Sendable {
        let device: AudioDevice
        let source: Source
    }

    /// The fallback chain, in order: the device the user picked (by UID) → the
    /// system default → the built-in microphone → anything with an input at all.
    /// Returns nil only when the machine has no usable input, which is a real
    /// error and must be reported, never swallowed.
    ///
    /// Pure on purpose: every branch here is a state that only shows up when
    /// hardware disappears mid-session, which no test machine reproduces on demand.
    static func resolve(
        preferredUID: String?,
        available: [AudioDevice],
        systemDefaultUID: String?,
        builtInUID: String?
    ) -> Resolution? {
        let usable = available.filter(\.hasInput)
        func find(_ uid: String?) -> AudioDevice? {
            guard let uid, !uid.isEmpty else { return nil }
            return usable.first { $0.uid == uid }
        }
        // An explicit choice always wins, Bluetooth included — it is the user's
        // headset and their decision.
        if let d = find(preferredUID) { return Resolution(device: d, source: .chosen) }
        // Everything below is Steneo choosing, and Steneo does not choose
        // Bluetooth: taking a headset as the microphone costs its playback
        // quality, which is a bad trade to make on someone's behalf.
        if let d = find(systemDefaultUID), !d.isBluetooth { return Resolution(device: d, source: .systemDefault) }
        if let d = find(builtInUID) { return Resolution(device: d, source: .builtIn) }
        if let d = usable.first(where: { !$0.isBluetooth }) { return Resolution(device: d, source: .lastResort) }
        // Nothing else exists: a Bluetooth microphone beats no recording at all.
        if let d = usable.first { return Resolution(device: d, source: .lastResort) }
        return nil
    }

    /// Resolve against the hardware as it is right now.
    static func current(preferredUID: String?) -> Resolution? {
        resolve(preferredUID: preferredUID,
                available: inputDevices(),
                systemDefaultUID: systemDefaultInput()?.uid,
                builtInUID: builtInMicrophone()?.uid)
    }

    // MARK: - CoreAudio

    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    private static func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// Every device that can record, in CoreAudio's order.
    static func inputDevices() -> [AudioDevice] {
        allDeviceIDs().compactMap(device(for:)).filter(\.hasInput)
    }

    static func systemDefaultInput() -> AudioDevice? {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown, let d = device(for: id), d.hasInput else { return nil }
        return d
    }

    /// The Mac's own microphone — the last stop before giving up, and the one
    /// device that is always there on a notebook.
    static func builtInMicrophone() -> AudioDevice? {
        let devices = allDeviceIDs().compactMap(device(for:)).filter(\.hasInput)
        if let d = devices.first(where: { transportType(for: $0.id) == kAudioDeviceTransportTypeBuiltIn }) {
            return d
        }
        // Transport type is the reliable signal; the UID spelling is the safety net.
        return devices.first { $0.uid.contains("BuiltInMicrophone") }
    }

    static func device(for id: AudioDeviceID) -> AudioDevice? {
        guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) else { return nil }
        return AudioDevice(
            id: id,
            uid: uid,
            name: stringProperty(id, kAudioObjectPropertyName) ?? uid,
            inputChannels: inputChannels(id),
            isBluetooth: isBluetoothTransport(transportType(for: id)),
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

    private static func isBluetoothTransport(_ type: UInt32?) -> Bool {
        guard let type else { return false }
        return type == kAudioDeviceTransportTypeBluetooth || type == kAudioDeviceTransportTypeBluetoothLE
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
