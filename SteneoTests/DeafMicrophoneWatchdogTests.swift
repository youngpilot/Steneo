import AVFoundation
import XCTest
@testable import Steneo

/// Red has to mean "your audio is being captured".
///
/// Before 1.4.5 it could also mean "the engine died two minutes ago and nobody
/// noticed": `isRecording` stayed true, the icon stayed red, and the user kept
/// talking into a recording that captured nothing.
final class DeafMicrophoneWatchdogTests: XCTestCase {

    private let watchdog = DeafMicrophoneWatchdog(grace: 2.0, silenceLimit: 2.0)

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    private final class ErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: AudioCaptureError?
        func set(_ v: AudioCaptureError?) { lock.lock(); stored = v; lock.unlock() }
        var value: AudioCaptureError? { lock.lock(); defer { lock.unlock() }; return stored }
    }

    // MARK: - The warm-up must not be cut off

    func testNoBufferYetIsFineDuringTheWarmUp() {
        for elapsed in [0.0, 0.5, 1.5, 2.0] {
            XCTAssertEqual(watchdog.verdict(secondsSinceLastBuffer: nil, secondsSinceStart: elapsed), .hearing,
                           "cutting a recording off during the engine warm-up would be worse than the bug (\(elapsed)s)")
        }
    }

    func testABufferThatNeverArrivesIsADeafMicrophone() {
        XCTAssertEqual(watchdog.verdict(secondsSinceLastBuffer: nil, secondsSinceStart: 2.1), .deaf)
        XCTAssertEqual(watchdog.verdict(secondsSinceLastBuffer: nil, secondsSinceStart: 30), .deaf)
    }

    // MARK: - Mid-recording

    /// Buffers land roughly every 85 ms at 4096 frames, so an ordinary pause in
    /// speech never looks like this — the tap is still delivering silence.
    func testAudioArrivingIsAlwaysFine() {
        for gap in [0.0, 0.085, 0.5, 1.9, 2.0] {
            XCTAssertEqual(watchdog.verdict(secondsSinceLastBuffer: gap, secondsSinceStart: 60), .hearing,
                           "a \(gap)s gap is a pause in speech, not a dead tap")
        }
    }

    func testAStalledTapIsCaught() {
        XCTAssertEqual(watchdog.verdict(secondsSinceLastBuffer: 2.1, secondsSinceStart: 60), .deaf)
        XCTAssertEqual(watchdog.verdict(secondsSinceLastBuffer: 120, secondsSinceStart: 300), .deaf)
    }

    /// Long silences are exactly when this matters: the engine dies and there is
    /// no speech to make it obvious.
    func testTheGraceDoesNotProtectALaterStall() {
        XCTAssertEqual(watchdog.verdict(secondsSinceLastBuffer: 5, secondsSinceStart: 1.0), .deaf,
                       "the grace covers the first buffer, not every later one")
    }

    // MARK: - What follows

    func testAWatchdogStopIsReportedAsItself() {
        let reason = RecordingFailure.microphoneWentSilent
        XCTAssertTrue(reason.hasRecoverableAudio, "whatever was captured before the mic died is worth keeping")
        XCTAssertFalse(reason.message.contains("No speech"), "a dead microphone must not be reported as silence")
    }

    // MARK: - The heartbeat it reads, against the real service

    /// Positive control: the whole watchdog rests on this value moving. If the
    /// heartbeat never updates, every test above measures an invention.
    func testTheHeartbeatStartsEmptyAndFillsWhileCapturing() throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        try XCTSkipUnless(status == .authorized, "needs microphone access; got \(status.rawValue)")

        let service = AudioCaptureService()
        XCTAssertNil(service.secondsSinceLastBuffer, "nothing has been captured yet")

        let live = expectation(description: "capture started")
        let failure = ErrorBox()
        // Count the callbacks too. Without this, "the heartbeat is nil" cannot be
        // told apart from "no audio ever arrived" — two very different faults.
        let buffers = Counter()
        service.startCapture(onBuffer: { _ in buffers.bump() }, onLevel: { _ in }) { error in
            failure.set(error)
            live.fulfill()
        }
        wait(for: [live], timeout: 10)
        // Assert the start, do not assume it: a start that failed would leave the
        // heartbeat empty for a reason that has nothing to do with the heartbeat.
        try XCTSkipIf(failure.value != nil,
                      "capture would not start here (\(String(describing: failure.value))) — nothing to measure")

        // The heartbeat moves with the device's first buffer, the VAD block
        // follows about 80 ms later: wait for both.
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline, service.secondsSinceLastBuffer == nil || buffers.value == 0 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertGreaterThan(buffers.value, 0,
                             "capture started but no audio ever reached the VAD — the watchdog would fire on every recording")
        let gap = try XCTUnwrap(service.secondsSinceLastBuffer,
                                "buffers arrived (\(buffers.value)) but the heartbeat never moved")
        XCTAssertLessThan(gap, 1.0, "buffers land every ~10 ms; a full second of gap means nothing is feeding it")
        service.stopCapture()
    }
}
