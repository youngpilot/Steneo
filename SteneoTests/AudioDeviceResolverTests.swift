import CoreAudio
import XCTest
@testable import Steneo

/// The fallback chain that replaces "let AVAudioEngine pick something".
///
/// Every case below is a state that only appears when hardware disappears
/// mid-session — exactly what happened on 04.09.2026, and exactly what no test
/// machine reproduces on demand. So the chain is a pure function and these are
/// ordinary tests.
final class AudioDeviceResolverTests: XCTestCase {

    private func device(_ uid: String, name: String? = nil, inputs: Int = 1,
                        bluetooth: Bool = false, rate: Double = 48000) -> AudioDevice {
        AudioDevice(id: AudioDeviceID(abs(uid.hashValue % 1000)), uid: uid,
                    name: name ?? uid, inputChannels: inputs,
                    isBluetooth: bluetooth, sampleRate: rate)
    }

    private let display = "StudioDisplayMic-UID"
    private let scarlett = "Scarlett-UID"
    private let builtIn = "BuiltInMicrophoneDevice"

    private var machine: [AudioDevice] {
        [device(display), device(scarlett, inputs: 4), device(builtIn)]
    }

    func testPickedDeviceWins() {
        let r = AudioDeviceResolver.resolve(
            preferredUID: scarlett, available: machine,
            systemDefaultUID: display, builtInUID: builtIn)
        XCTAssertEqual(r?.device.uid, scarlett)
        XCTAssertEqual(r?.source, .chosen, "an explicit choice must beat the system default")
    }

    /// THE case. A USB re-enumeration gives the same microphone a new
    /// AudioDeviceID; anything that remembered the old one now points at nothing.
    /// Steneo asked for device 312 for over four hours.
    func testDeadIdentifierFallsBackToAMicrophoneThatExists() {
        let r = AudioDeviceResolver.resolve(
            preferredUID: "Gone-312", available: machine,
            systemDefaultUID: display, builtInUID: builtIn)
        XCTAssertEqual(r?.device.uid, builtIn, "a device that no longer exists must not fail the recording")
        XCTAssertEqual(r?.source, .builtIn)

        // A desktop Mac: no microphone of its own, the system's input is next.
        let desktop = AudioDeviceResolver.resolve(
            preferredUID: "Gone-312", available: [device(scarlett, inputs: 4), device(display)],
            systemDefaultUID: display, builtInUID: nil)
        XCTAssertEqual(desktop?.device.uid, display)
        XCTAssertEqual(desktop?.source, .systemDefault)
    }

    func testWithoutASystemDefaultTheBuiltInMicIsUsed() {
        let r = AudioDeviceResolver.resolve(
            preferredUID: nil, available: [device(builtIn)],
            systemDefaultUID: nil, builtInUID: builtIn)
        XCTAssertEqual(r?.source, .builtIn, "on a MacBook the machine's own mic is the floor of the chain")
    }

    /// The fallback Steneo actually hit was a device with `Input:No | Output:Yes`.
    /// An output-only device must never be selectable at all.
    func testOutputOnlyDevicesAreNeverChosen() {
        let speakers = device("Speakers-UID", inputs: 0)
        let r = AudioDeviceResolver.resolve(
            preferredUID: "Speakers-UID", available: [speakers, device(builtIn)],
            systemDefaultUID: "Speakers-UID", builtInUID: builtIn)
        XCTAssertEqual(r?.device.uid, builtIn, "an output-only device is not an input, however it is named")
    }

    func testAnyInputBeatsGivingUp() {
        let odd = device("SomeInterface-UID")
        let r = AudioDeviceResolver.resolve(
            preferredUID: "Gone", available: [odd],
            systemDefaultUID: "AlsoGone", builtInUID: "NoBuiltIn")
        XCTAssertEqual(r?.device.uid, odd.uid)
        XCTAssertEqual(r?.source, .other)
    }

    func testNoUsableInputIsReportedNotGuessed() {
        let r = AudioDeviceResolver.resolve(
            preferredUID: nil, available: [device("Speakers", inputs: 0)],
            systemDefaultUID: "Speakers", builtInUID: nil)
        XCTAssertNil(r, "no input at all is an error to report, not something to paper over")
    }

    func testEmptyPreferenceMeansAutomatic() {
        for empty in [nil, ""] as [String?] {
            let r = AudioDeviceResolver.resolve(
                preferredUID: empty, available: machine,
                systemDefaultUID: display, builtInUID: builtIn)
            XCTAssertEqual(r?.source, .builtIn, "\(String(describing: empty)) must not count as a choice")
        }
    }

    // MARK: - Automatic is the microphone with the least delay

    private func automatic(_ available: [AudioDevice], systemDefault: String?, builtIn: String?,
                           times: [String: Double]) -> [String] {
        AudioDeviceResolver.candidates(preferredUID: nil, available: available, systemDefaultUID: systemDefault,
                                       builtInUID: builtIn, startTimes: times).map(\.device.uid)
    }

    func testAutomaticTakesTheFastestMeasuredMicrophone() {
        XCTAssertEqual(automatic(machine, systemDefault: display, builtIn: builtIn,
                                 times: [display: 450, scarlett: 540, builtIn: 60]),
                       [builtIn, display, scarlett])
    }

    /// The Mac's own is not first by decree: something measured faster wins.
    func testAFasterExternalMicrophoneBeatsTheMacsOwn() {
        XCTAssertEqual(automatic(machine, systemDefault: display, builtIn: builtIn,
                                 times: [scarlett: 20, builtIn: 60, display: 450]).first, scarlett)
    }

    /// Counter-check: the system's own choice no longer decides. Until 1.7 the
    /// system default went first, however slow.
    func testTheSystemDefaultDoesNotOutrankAFasterMicrophone() {
        XCTAssertNotEqual(automatic(machine, systemDefault: display, builtIn: builtIn,
                                    times: [display: 450, builtIn: 60]).first, display)
    }

    func testUnmeasuredTheMacsOwnCountsAsFastestAndTheSystemDefaultIsNext() {
        XCTAssertEqual(automatic(machine, systemDefault: scarlett, builtIn: builtIn, times: [:]),
                       [builtIn, scarlett, display])
        XCTAssertEqual(automatic(machine, systemDefault: scarlett, builtIn: builtIn, times: [display: 450]),
                       [builtIn, display, scarlett], "a measured device ranks ahead of one nobody has timed")
    }

    func testOnADesktopMacTheFastestExternalOneWins() {
        let desktop = [device(display), device(scarlett, inputs: 4)]
        XCTAssertEqual(automatic(desktop, systemDefault: display, builtIn: nil, times: [display: 450, scarlett: 300]).first,
                       scarlett)
        XCTAssertEqual(automatic(desktop, systemDefault: display, builtIn: nil, times: [:]).first, display,
                       "nothing measured: the system's input")
    }

    func testAChoiceStillBeatsTheFastest() {
        let list = AudioDeviceResolver.candidates(
            preferredUID: display, available: machine, systemDefaultUID: scarlett, builtInUID: builtIn,
            startTimes: [display: 450, scarlett: 540, builtIn: 60])
        XCTAssertEqual(list.map(\.device.uid), [display, builtIn, scarlett],
                       "the chosen one first, and behind it the fastest: the Mac's own is the fallback")
    }

    // MARK: - The line under the picker

    func testTheCaptionSaysOnlyWhatThePickerDoesNot() {
        XCTAssertEqual(AudioDeviceResolver.usageCaption(chosenName: nil, inUse: "MacBook Pro Microphone"),
                       "Using MacBook Pro Microphone, the fastest to start.")
        XCTAssertNil(AudioDeviceResolver.usageCaption(chosenName: "Scarlett Solo", inUse: "Scarlett Solo"),
                     "the picker already says it")
        XCTAssertEqual(AudioDeviceResolver.usageCaption(chosenName: "Scarlett Solo", inUse: "MacBook Pro Microphone"),
                       "Using MacBook Pro Microphone instead.")
        XCTAssertEqual(AudioDeviceResolver.usageCaption(chosenName: nil, inUse: nil), "No microphone found.")
    }

    // MARK: - Bluetooth is never chosen for you

    /// Recording through AirPods drops them out of high-quality playback into
    /// the mono call profile — so whatever you were listening to turns to mush.
    /// Steneo must never make that trade on the user's behalf.
    func testBluetoothIsNotPickedEvenWhenItIsTheSystemDefault() {
        let airpods = device("AirPods-UID", name: "AirPods Pro", bluetooth: true)
        let r = AudioDeviceResolver.resolve(
            preferredUID: nil, available: [airpods, device(builtIn)],
            systemDefaultUID: airpods.uid, builtInUID: builtIn)
        XCTAssertEqual(r?.device.uid, builtIn)
        XCTAssertEqual(r?.source, .builtIn, "the Mac's own microphone costs the user nothing")
    }

    /// But an explicit choice is an explicit choice.
    func testBluetoothIsUsedWhenTheUserAsksForIt() {
        let airpods = device("AirPods-UID", name: "AirPods Pro", bluetooth: true)
        let r = AudioDeviceResolver.resolve(
            preferredUID: airpods.uid, available: [airpods, device(builtIn)],
            systemDefaultUID: builtIn, builtInUID: builtIn)
        XCTAssertEqual(r?.device.uid, airpods.uid)
        XCTAssertEqual(r?.source, .chosen, "the user's headset is the user's decision")
    }

    /// A headset beats no recording at all.
    func testBluetoothIsStillBetterThanNothing() {
        let airpods = device("AirPods-UID", bluetooth: true)
        let r = AudioDeviceResolver.resolve(
            preferredUID: nil, available: [airpods],
            systemDefaultUID: airpods.uid, builtInUID: nil)
        XCTAssertEqual(r?.device.uid, airpods.uid, "with nothing else present, recording still has to work")
    }

    // MARK: - The change signature

    func testSignatureDistinguishesWhatMatters() {
        let base = device(display)
        XCTAssertEqual(base.signature, device(display).signature, "the same device twice is not a change")
        XCTAssertNotEqual(base.signature, device(builtIn).signature, "a different device is a change")
        XCTAssertNotEqual(base.signature, device(display, rate: 44100).signature, "a rate switch is a change")
        XCTAssertNotEqual(base.signature, device(display, inputs: 2).signature, "a channel-count switch is a change")
    }

    /// The signature must NOT be the AudioDeviceID: that is the transient handle
    /// whose staleness caused the whole failure.
    func testSignatureIgnoresTheTransientIdentifier() {
        let a = AudioDevice(id: 107, uid: display, name: "Mic", inputChannels: 1,
                            isBluetooth: false, sampleRate: 48000)
        let b = AudioDevice(id: 312, uid: display, name: "Mic", inputChannels: 1,
                            isBluetooth: false, sampleRate: 48000)
        XCTAssertEqual(a.signature, b.signature, "the same microphone under a new number is still the same microphone")
    }

    // MARK: - Against the real machine

    /// Positive control: without this, every test above could pass against a
    /// resolver that never finds anything on real hardware.
    func testResolvesSomethingOnThisMachine() throws {
        let inputs = AudioDeviceResolver.inputDevices()
        try XCTSkipIf(inputs.isEmpty, "this Mac reports no audio input device")
        let r = try XCTUnwrap(AudioDeviceResolver.current(preferredUID: nil),
                             "a machine with an input must resolve to one")
        XCTAssertTrue(r.device.hasInput)
        XCTAssertFalse(r.device.uid.isEmpty, "the UID is the identity — it must never be empty")
        XCTAssertGreaterThan(r.device.sampleRate, 0)
    }

    func testADeadPreferenceStillResolvesOnThisMachine() throws {
        try XCTSkipIf(AudioDeviceResolver.inputDevices().isEmpty, "this Mac reports no audio input device")
        let r = try XCTUnwrap(AudioDeviceResolver.current(preferredUID: "Definitely-Not-A-Device-312"))
        XCTAssertNotEqual(r.source, .chosen, "a dead preference must not be honoured")
        XCTAssertTrue(r.device.hasInput, "and it must still land on something that can record")
    }
}
