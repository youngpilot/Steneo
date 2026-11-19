import AppKit
import AVFoundation
import CoreAudio
import XCTest
@testable import Steneo

/// The microphone a recording runs on, when the obvious one will not start.
///
/// Until 1.6 the fallback only covered a device that was MISSING. A device that
/// was present and refused to start was retried once and then given up on, with
/// a working built-in microphone sitting unused — the recording never began.
/// None of these states can be produced on a healthy Mac on demand, so the
/// decisions are pure functions and these are ordinary tests.
final class MicrophoneFallbackTests: XCTestCase {

    private func device(_ uid: String, bluetooth: Bool = false, builtIn: Bool = false) -> AudioDevice {
        AudioDevice(id: AudioDeviceID(abs(uid.hashValue % 1000)), uid: uid, name: uid,
                    inputChannels: 1, isBluetooth: bluetooth, isBuiltIn: builtIn, sampleRate: 48_000)
    }

    private var display: AudioDevice { device("Studio Display Microphone") }
    private var scarlett: AudioDevice { device("Scarlett Solo") }
    private var macBook: AudioDevice { device("MacBook Pro Microphone", builtIn: true) }
    private var airPods: AudioDevice { device("AirPods Pro", bluetooth: true) }

    private func candidates(preferred: String? = nil, _ available: [AudioDevice], systemDefault: AudioDevice?) -> [AudioDeviceResolver.Resolution] {
        AudioDeviceResolver.candidates(
            preferredUID: preferred, available: available,
            systemDefaultUID: systemDefault?.uid,
            builtInUID: available.first(where: \.isBuiltIn)?.uid)
    }

    // MARK: - The order

    func testTheOrderIsChoiceThenSystemThenTheMacsOwnThenTheRest() {
        let list = candidates(preferred: scarlett.uid, [macBook, airPods, display, scarlett], systemDefault: display)
        XCTAssertEqual(list.map(\.device.uid), [scarlett.uid, display.uid, macBook.uid, airPods.uid])
        XCTAssertEqual(list.map(\.source), [.chosen, .systemDefault, .builtIn, .lastResort])
    }

    func testNoDeviceAppearsTwice() {
        // The built-in microphone is also the system default here.
        let list = candidates([macBook, scarlett], systemDefault: macBook)
        XCTAssertEqual(list.map(\.device.uid), [macBook.uid, scarlett.uid])
    }

    /// AirPods as the system input: the Mac's own microphone goes first, the
    /// headset stays available as the very last resort.
    func testBluetoothGoesLastUnlessItWasChosen() {
        let automatic = candidates([airPods, macBook], systemDefault: airPods)
        XCTAssertEqual(automatic.map(\.device.uid), [macBook.uid, airPods.uid])

        let chosen = candidates(preferred: airPods.uid, [airPods, macBook], systemDefault: macBook)
        XCTAssertEqual(chosen.first?.device.uid, airPods.uid, "an explicit choice is the user's decision")
    }

    // MARK: - THE case: present, but will not start

    func testADeviceThatWillNotStartHandsOverToTheMacsOwnMicrophone() {
        let order = AudioDeviceResolver.attemptOrder(candidates([display, macBook], systemDefault: display), excluding: [])
        var tried: [String] = []
        let outcome = AudioDeviceResolver.firstWorking(order) { candidate in
            tried.append(candidate.device.uid)
            return candidate.device.uid != self.display.uid      // the display microphone is dead
        }
        XCTAssertEqual(outcome.map { order[$0.index].device.uid }, macBook.uid)
        XCTAssertEqual(outcome?.failed.map(\.device.uid), [display.uid])
        XCTAssertEqual(tried, [display.uid, macBook.uid], "in order, each once, and no further once one works")
    }

    /// Counter-check. This is what 1.4.5 did: the same device twice, then give
    /// up. If this ever describes the shipped start again, the test above is
    /// decoration.
    func testRetryingTheSameDeviceWasNotAFallback() {
        let old = [display, display]                              // "rebuild once, retry once"
        let outcome = AudioDeviceResolver.firstWorking(old) { $0.uid != self.display.uid }
        XCTAssertNil(outcome, "two attempts on a dead device are still no recording")
    }

    func testNothingWorkingIsReportedNotGuessed() {
        let order = AudioDeviceResolver.attemptOrder(candidates([display, macBook], systemDefault: display), excluding: [])
        XCTAssertNil(AudioDeviceResolver.firstWorking(order) { _ in false })
    }

    /// A Mac with a single microphone has nothing to fall back to — so a hiccup
    /// gets one more try instead of a failed recording.
    func testTheFirstChoiceGetsOneLastAttempt() {
        let order = AudioDeviceResolver.attemptOrder(candidates([scarlett], systemDefault: scarlett), excluding: [])
        XCTAssertEqual(order.map(\.device.uid), [scarlett.uid, scarlett.uid])
        var attempts = 0
        let outcome = AudioDeviceResolver.firstWorking(order) { _ in attempts += 1; return attempts == 2 }
        XCTAssertEqual(outcome?.index, 1, "the second attempt on the only device must count")
    }

    // MARK: - Remembering what failed

    /// The second recording after a failure does not even attempt the broken
    /// device — and must still say that it is running on the fallback.
    func testAFallbackKeepsBeingAnnouncedWhileItLasts() {
        let all = candidates([display, macBook], systemDefault: display)
        XCTAssertEqual(AudioDeviceResolver.outranked(by: macBook, in: all, unusable: [display.uid]),
                       [display.name], "passed over counts exactly like failed just now")
        XCTAssertEqual(AudioDeviceResolver.outranked(by: display, in: all, unusable: [display.uid]), [],
                       "the first choice working after a hiccup is not a fallback")
        XCTAssertEqual(AudioDeviceResolver.outranked(by: macBook, in: all, unusable: []), [],
                       "ranked lower for a healthy reason (a Bluetooth default, say) is not a failure")
    }

    func testAFailedDeviceIsPassedOverWhileNothingChanged() {
        let failures = [AudioDeviceResolver.Failure(uid: display.uid, at: 1000, fingerprint: "A")]
        let passedOver = AudioDeviceResolver.activeFailures(failures, now: 1030, fingerprint: "A")
        let order = AudioDeviceResolver.attemptOrder(candidates([display, macBook], systemDefault: display), excluding: passedOver)
        XCTAssertEqual(order.first?.device.uid, macBook.uid,
                       "a device that just failed must not cost every recording its timeout again")
    }

    func testAHardwareChangeGivesEveryDeviceAFreshChance() {
        let failures = [AudioDeviceResolver.Failure(uid: display.uid, at: 1000, fingerprint: "A")]
        XCTAssertTrue(AudioDeviceResolver.activeFailures(failures, now: 1030, fingerprint: "B").isEmpty,
                      "replugging the device changes the fingerprint — it has to be tried again")
    }

    func testAFailureIsForgottenAfterAWhile() {
        let failures = [AudioDeviceResolver.Failure(uid: display.uid, at: 1000, fingerprint: "A")]
        let later = 1000 + AudioDeviceResolver.failureMemory + 1
        XCTAssertTrue(AudioDeviceResolver.activeFailures(failures, now: later, fingerprint: "A").isEmpty,
                      "a device that recovered on its own must come back without a replug")
    }

    func testPassingEverythingOverIsNotAnOption() {
        let all = candidates([display, macBook], systemDefault: display)
        let order = AudioDeviceResolver.attemptOrder(all, excluding: [display.uid, macBook.uid])
        XCTAssertEqual(order.first?.device.uid, display.uid, "with everything marked failed, everything is tried anyway")
    }

    func testTheFingerprintFollowsTheHardware() {
        let base = AudioDeviceResolver.Snapshot(inputs: [display, macBook], systemDefaultUID: display.uid)
        XCTAssertEqual(base.fingerprint,
                       AudioDeviceResolver.Snapshot(inputs: [macBook, display], systemDefaultUID: display.uid).fingerprint,
                       "the order CoreAudio lists devices in is not a change")
        XCTAssertNotEqual(base.fingerprint,
                          AudioDeviceResolver.Snapshot(inputs: [macBook], systemDefaultUID: macBook.uid).fingerprint)
        XCTAssertNotEqual(base.fingerprint,
                          AudioDeviceResolver.Snapshot(inputs: [display, macBook], systemDefaultUID: macBook.uid).fingerprint,
                          "switching the system input is a change")
    }

    // MARK: - Saying so

    func testAFallbackIsAnnouncedWithBothNames() {
        let text = AudioDeviceResolver.notice(used: macBook, source: .builtIn,
                                              failedNames: [display.name], preferredName: nil)
        XCTAssertEqual(text, "Recording with MacBook Pro Microphone – Studio Display Microphone didn't respond.")
    }

    func testAChosenDeviceThatIsUnpluggedIsNamed() {
        let text = AudioDeviceResolver.notice(used: display, source: .systemDefault,
                                              failedNames: [], preferredName: "Scarlett Solo")
        XCTAssertEqual(text, "Recording with Studio Display Microphone – Scarlett Solo isn't connected.")
    }

    func testNothingIsSaidWhenNothingHappened() {
        XCTAssertNil(AudioDeviceResolver.notice(used: display, source: .systemDefault, failedNames: [], preferredName: nil))
        XCTAssertNil(AudioDeviceResolver.notice(used: scarlett, source: .chosen, failedNames: [], preferredName: "Scarlett Solo"))
        // Preferring the Mac's microphone over a headset is policy, not news.
        XCTAssertNil(AudioDeviceResolver.notice(used: macBook, source: .builtIn, failedNames: [], preferredName: nil))
        // The only device hiccuped once and then worked: nothing was switched.
        XCTAssertNil(AudioDeviceResolver.notice(used: scarlett, source: .systemDefault,
                                                failedNames: [scarlett.name], preferredName: nil))
    }

    // MARK: - The start time next to the name

    func testThePickerShowsHowLongAMicrophoneNeeds() {
        XCTAssertEqual(AudioDeviceResolver.startLabel(name: "Studio Display", milliseconds: 443.4, isBluetooth: false),
                       "Studio Display · ~440 ms")
        XCTAssertEqual(AudioDeviceResolver.startLabel(name: "MacBook Pro", milliseconds: 35.2, isBluetooth: false),
                       "MacBook Pro · ~40 ms")
        XCTAssertEqual(AudioDeviceResolver.startLabel(name: "Scarlett", milliseconds: nil, isBluetooth: false), "Scarlett",
                       "an unmeasured device shows no invented number")
        XCTAssertEqual(AudioDeviceResolver.startLabel(name: "AirPods", milliseconds: nil, isBluetooth: true),
                       "AirPods · Bluetooth")
    }

    // MARK: - Short recordings

    func testAShortAnswerIsPaddedToWhatTheModelNeeds() throws {
        let spoken = [Float](repeating: 0.25, count: 11_200)          // 0.7 s at 16 kHz
        let padded = try XCTUnwrap(TranscriptionService.paddedForModel(spoken))
        XCTAssertEqual(padded.count, TranscriptionService.modelMinimumSamples)
        XCTAssertEqual(Array(padded.prefix(spoken.count)), spoken, "the speech itself must be untouched")
        XCTAssertTrue(padded.dropFirst(spoken.count).allSatisfy { $0 == 0 }, "and what is added is silence")
    }

    func testThereHasToBeRoomForAWord() {
        XCTAssertNil(TranscriptionService.paddedForModel([Float](repeating: 0.25, count: 1_600)),
                     "a tenth of a second is a slipped key, not speech")
    }

    func testOrdinaryRecordingsAreLeftAlone() {
        let long = [Float](repeating: 0.25, count: 48_000)
        XCTAssertEqual(TranscriptionService.paddedForModel(long)?.count, 48_000)
    }

    // MARK: - A held key is one press

    private func keyDown(repeating: Bool) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: repeating, keyCode: 96))
    }

    /// F5 held past the repeat delay used to toggle a second time — and with the
    /// delay (450 ms) shorter than a start (615 ms), that ended the recording
    /// the instant it began.
    func testAKeyBeingHeldIsNotPressedAgain() throws {
        XCTAssertTrue(HotkeyService.isFreshPress(try keyDown(repeating: false)))
        XCTAssertFalse(HotkeyService.isFreshPress(try keyDown(repeating: true)))
    }

    // MARK: - Against the real microphone

    private final class StartBox: @unchecked Sendable {
        private let lock = NSLock()
        private var info: CaptureStartInfo?
        private var error: AudioCaptureError??
        func set(_ value: CaptureStartInfo) { lock.lock(); info = value; lock.unlock() }
        func set(_ value: AudioCaptureError?) { lock.lock(); error = .some(value); lock.unlock() }
        var started: CaptureStartInfo? { lock.lock(); defer { lock.unlock() }; return info }
        var failure: AudioCaptureError? { lock.lock(); defer { lock.unlock() }; return error.flatMap { $0 } }
    }

    /// A start that fails on its first attempt must still end in a recording,
    /// and must say which microphone it ended on.
    func testAFailedFirstAttemptStillEndsInARecording() throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        try XCTSkipUnless(status == .authorized, "needs microphone access; got \(status.rawValue)")

        let service = AudioCaptureService()
        let box = StartBox()
        // Two moments since 1.7: audio is kept (the bridge may already be
        // recording), and later the microphone it ends up on is known.
        let settled = expectation(description: "final microphone known")
        service.onStarted = { box.set($0); settled.fulfill() }
        service.failNextStartForTesting = true
        let done = expectation(description: "start finished")
        service.startCapture(onBuffer: { _ in }, onLevel: { _ in }) { error in
            box.set(error)
            done.fulfill()
        }
        wait(for: [done], timeout: 15)
        if box.failure == nil { wait(for: [settled], timeout: 15) }
        service.stopCapture()

        XCTAssertNil(box.failure, "one failed attempt must not be the end of the recording")
        let info = try XCTUnwrap(box.started, "a start that succeeded has to say what it runs on")
        XCTAssertTrue(info.device.hasInput)
        if AudioDeviceResolver.inputDevices().count > 1 {
            XCTAssertEqual(info.failedNames.count, 1, "the device that failed has to be on record")
        } else {
            XCTAssertTrue(info.failedNames.isEmpty, "one microphone, retried: nothing was switched")
        }
    }

    // MARK: - Recording does not wait for the model

    /// Capturing audio never needed the speech model, only the transcription at
    /// stop does. Until 1.6 a press while the model was still loading was simply
    /// refused. Now the recording runs and the stop waits for the model.
    @MainActor
    func testARecordingMadeBeforeTheModelIsReadyIsStillTranscribed() async {
        let service = TranscriptionService()
        XCTAssertFalse(service.isModelLoaded, "precondition: nothing is loaded yet")

        service.beginCapturing()
        await service.startTranscription()
        let audio = (0..<32_000).map { sinf(Float($0) * 0.03) * 0.05 }      // 2 s, no words in it
        _ = await service.stopTranscription(rawSamples: audio, rate: 16_000)

        XCTAssertTrue(service.isModelLoaded, "stopping has to bring the model up, not give up on it")
        XCTAssertNotEqual(service.lastFailure, .asrError, "the model was only late, it did not fail")
        XCTAssertNotNil(service.lastFailure, "and a tone is still no speech — the stop really ran through the model")
    }
}
