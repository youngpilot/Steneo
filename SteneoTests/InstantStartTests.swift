import AVFoundation
import CoreAudio
import XCTest
@testable import Steneo

/// Nothing said at the start of a recording may be lost.
///
/// A microphone on a cable needs about 450 ms before its first sample exists.
/// Until 1.7 whatever was said in that time was gone. Now the Mac's own
/// microphone, live after about 35 ms, records until the other one delivers,
/// and the two are joined on the time stamp of the hand-over.
final class InstantStartTests: XCTestCase {

    private func device(_ uid: String, bluetooth: Bool = false, builtIn: Bool = false) -> AudioDevice {
        AudioDevice(id: AudioDeviceID(abs(uid.hashValue % 1000)), uid: uid, name: uid,
                    inputChannels: 1, isBluetooth: bluetooth, isBuiltIn: builtIn, sampleRate: 48_000)
    }

    private var display: AudioDevice { device("Studio Display Microphone") }
    private var macBook: AudioDevice { device("MacBook Pro Microphone", builtIn: true) }
    private var airPods: AudioDevice { device("AirPods Pro", bluetooth: true) }

    private func order(preferred: String? = nil, _ available: [AudioDevice], systemDefault: AudioDevice?,
                       excluding failed: Set<String> = []) -> [AudioDeviceResolver.Resolution] {
        let candidates = AudioDeviceResolver.candidates(
            preferredUID: preferred, available: available, systemDefaultUID: systemDefault?.uid,
            builtInUID: available.first(where: \.isBuiltIn)?.uid)
        return AudioDeviceResolver.attemptOrder(candidates, excluding: failed)
    }

    // MARK: - Who bridges

    func testTheMacsOwnMicrophoneBridgesForASlowerOne() {
        let bridge = AudioDeviceResolver.bridge(in: order([display, macBook], systemDefault: display))
        XCTAssertEqual(bridge?.device.uid, macBook.uid)
    }

    func testItBridgesForAChosenHeadsetToo() {
        let bridge = AudioDeviceResolver.bridge(in: order(preferred: airPods.uid, [airPods, macBook], systemDefault: macBook))
        XCTAssertEqual(bridge?.device.uid, macBook.uid, "a headset takes seconds to switch profiles")
    }

    func testNoBridgeWhenTheMacsOwnMicrophoneIsTheOneToRecordWith() {
        XCTAssertNil(AudioDeviceResolver.bridge(in: order([display, macBook], systemDefault: macBook)),
                     "it would bridge for itself")
        // The first choice just failed and is being passed over: the Mac's own is first now.
        XCTAssertNil(AudioDeviceResolver.bridge(in: order([display, macBook], systemDefault: display,
                                                          excluding: [display.uid])))
    }

    func testNoBridgeWithoutABuiltInMicrophone() {
        XCTAssertNil(AudioDeviceResolver.bridge(in: order([display], systemDefault: display)), "a desktop Mac has none")
        XCTAssertNil(AudioDeviceResolver.bridge(in: order([display, macBook], systemDefault: display,
                                                          excluding: [macBook.uid])),
                     "one that just failed is not something to lean on")
    }

    // MARK: - The hand-over

    func testTheClockConvertsBothWays() {
        let ticks = HostClock.ticks(0.5)
        XCTAssertEqual(HostClock.seconds(ticks), 0.5, accuracy: 0.000_001)
    }

    /// The bridge has recorded 30 ms past the moment the other microphone took
    /// over. Those 30 ms exist twice and must be said once.
    func testWhatBothMicrophonesHeardIsKeptOnce() {
        let start = HostClock.ticks(100)
        var bridge = CapturePiece(rate: 48_000)
        bridge.append([Float](repeating: 0.1, count: 4_800), at: start)            // 100 ms
        let handover = start + HostClock.ticks(0.070)
        let dropped = bridge.cut(at: handover)
        XCTAssertEqual(dropped, 1_440, accuracy: 2, "30 ms at 48 kHz")
        XCTAssertEqual(bridge.samples.count, 3_360, accuracy: 2, "70 ms stay")
    }

    func testAHandoverAfterTheBridgesLastSampleDropsNothing() {
        let start = HostClock.ticks(100)
        var bridge = CapturePiece(rate: 48_000)
        bridge.append([Float](repeating: 0.1, count: 4_800), at: start)
        XCTAssertEqual(bridge.cut(at: start + HostClock.ticks(0.120)), 0)
        XCTAssertEqual(bridge.samples.count, 4_800)
    }

    /// A time stamp that claims the other microphone started long before it
    /// did must not erase the first words. Twice is the better mistake.
    func testABrokenTimeStampCannotEraseTheStart() {
        let start = HostClock.ticks(100)
        var bridge = CapturePiece(rate: 48_000)
        bridge.append([Float](repeating: 0.1, count: 48_000), at: start)           // a full second
        let dropped = bridge.cut(at: 0)
        XCTAssertEqual(dropped, 12_000, "never more than a quarter of a second")
        XCTAssertEqual(bridge.samples.count, 36_000)
    }

    func testALongRecordingIsTrimmedInStepsNotOnEveryBuffer() {
        var piece = CapturePiece(rate: 1_000)
        piece.append([Float](repeating: 0, count: 10_400), at: 0)
        piece.keepLast(seconds: 10, slack: 0.5)
        XCTAssertEqual(piece.samples.count, 10_400, "still inside the slack")
        piece.append([Float](repeating: 0, count: 200), at: 0)
        piece.keepLast(seconds: 10, slack: 0.5)
        XCTAssertEqual(piece.samples.count, 10_000)
    }

    // MARK: - One recording out of two microphones

    func testTwoMicrophonesBecomeOneSignalAtSixteenKilohertz() {
        let bridge = (0..<4_410).map { sinf(Float($0) * 0.05) * 0.2 }               // 100 ms at 44.1 kHz
        let lead = (0..<48_000).map { sinf(Float($0) * 0.05) * 0.2 }                // 1 s at 48 kHz
        let joined = AudioCaptureService.assemble([(bridge, 44_100), (lead, 48_000)])
        XCTAssertEqual(Double(joined.count), 1.1 * 16_000, accuracy: 200, "1.1 s, give or take the filters' edges")
    }

    func testARecordingAlreadyAtSixteenKilohertzIsHandedOverUntouched() {
        let samples = (0..<16_000).map { Float($0) }
        XCTAssertEqual(AudioCaptureService.assemble([(samples, 16_000)]), samples)
        XCTAssertEqual(AudioCaptureService.assemble([([], 48_000), (samples, 16_000)]), samples, "an empty piece adds nothing")
        XCTAssertTrue(AudioCaptureService.assemble([]).isEmpty)
    }

    // MARK: - Reading a device's buffer

    func testOnlyTheFirstChannelIsRead() {
        let stereo: [Float] = [1, -1, 2, -2, 3, -3]
        stereo.withUnsafeBufferPointer {
            XCTAssertEqual(DeviceInputStream.firstChannel(of: $0, channels: 2), [1, 2, 3])
        }
        let mono: [Float] = [1, 2, 3]
        mono.withUnsafeBufferPointer {
            XCTAssertEqual(DeviceInputStream.firstChannel(of: $0, channels: 1), [1, 2, 3])
        }
    }

    // MARK: - Against the real microphones

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var info: CaptureStartInfo?
        private var liveAt: Date?
        private var error: AudioCaptureError?
        func started(_ value: CaptureStartInfo) { lock.lock(); info = value; lock.unlock() }
        func live(_ value: AudioCaptureError?) { lock.lock(); error = value; liveAt = Date(); lock.unlock() }
        var result: (info: CaptureStartInfo?, liveAt: Date?, error: AudioCaptureError?) {
            lock.lock(); defer { lock.unlock() }
            return (info, liveAt, error)
        }
    }

    /// The claim itself, on this Mac's hardware: the recording is live long
    /// before the slower microphone is, and what comes out is as long as the
    /// time that passed — no hole where the two were joined, nothing twice.
    /// Records the room for about two seconds. Plays nothing, switches nothing.
    func testARecordingIsLiveBeforeItsMicrophoneIsAndLosesNothing() throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        try XCTSkipUnless(status == .authorized, "needs microphone access; got \(status.rawValue)")
        let snapshot = AudioDeviceResolver.snapshot()
        let order = AudioDeviceResolver.attemptOrder(AudioDeviceResolver.candidates(preferredUID: nil, in: snapshot),
                                                     excluding: [])
        let bridge = AudioDeviceResolver.bridge(in: order)
        try XCTSkipIf(bridge == nil, "nothing to bridge here: the Mac's own microphone is the first choice, or there is none")

        let service = AudioCaptureService()
        let box = Box()
        let live = expectation(description: "first audio kept")
        let settled = expectation(description: "final microphone known")
        service.onStarted = { box.started($0); settled.fulfill() }
        let pressed = Date()
        service.startCapture(onBuffer: { _ in }, onLevel: { _ in }) { error in
            box.live(error)
            live.fulfill()
        }
        wait(for: [live], timeout: 5)
        XCTAssertNil(box.result.error)
        let liveAt = try XCTUnwrap(box.result.liveAt)
        wait(for: [settled], timeout: 10)
        Thread.sleep(forTimeInterval: 1.0)
        let stopped = Date()
        service.stopCapture()
        let recording = service.takeRecording()

        let info = try XCTUnwrap(box.result.info)
        let liveAfter = liveAt.timeIntervalSince(pressed)
        let expected = stopped.timeIntervalSince(liveAt)
        let recorded = Double(recording.samples.count) / recording.rate
        print("InstantStart: live after \(Int(liveAfter * 1000)) ms, on \(info.device.name) (own start \(Int(info.startMilliseconds)) ms), recorded \(recorded) s of \(expected) s")

        XCTAssertLessThan(liveAfter, 0.3, "the bridge exists to be live at once")
        XCTAssertEqual(recording.rate, 16_000)
        XCTAssertEqual(recorded, expected, accuracy: 0.15,
                       "the recording has to be as long as the time it ran: a hole or a repeat at the hand-over shows here")
    }
}
