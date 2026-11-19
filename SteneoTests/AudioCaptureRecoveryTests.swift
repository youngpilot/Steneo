import AVFoundation
import XCTest
@testable import Steneo

/// A start that fails must not be the end of recording. This used to guard a
/// wedged AVAudioEngine; since 1.7 there is no engine, and what remains is the
/// promise itself: fail once, record anyway, and start again afterwards.
final class AudioCaptureRecoveryTests: XCTestCase {

    /// A pass here means nothing if the microphone isn't available to the test
    /// runner — the service would report `.microphoneDenied` long before reaching
    /// the code under test. Skip loudly instead of passing quietly.
    private func requireMicrophone() throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        try XCTSkipUnless(status == .authorized, "needs microphone access; got \(status.rawValue)")
    }

    /// The completion lands on the service's own queue, so the result crosses a
    /// concurrency boundary and needs a lock rather than a captured var.
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var value: AudioCaptureError??
        func set(_ v: AudioCaptureError?) { lock.lock(); value = .some(v); lock.unlock() }
        var result: AudioCaptureError?? { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func start(_ service: AudioCaptureService, _ label: String) -> AudioCaptureError? {
        let done = expectation(description: label)
        let box = Box()
        service.startCapture(onBuffer: { _ in }, onLevel: { _ in }) { error in
            box.set(error)
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        service.stopCapture()
        XCTAssertNotNil(box.result, "\(label): completion never fired")
        return box.result.flatMap { $0 }
    }

    /// A device that refuses must be passed over, not reported as the end.
    func testAStartThatFailsOnceStillRecords() throws {
        try requireMicrophone()
        let service = AudioCaptureService()

        // Positive control first: without the fault, this service starts. Without
        // it, a "recovered" result below could just mean nothing ever broke.
        XCTAssertNil(start(service, "baseline"), "baseline start must succeed")

        service.failNextStartForTesting = true
        XCTAssertNil(start(service, "recovery"), "a failed start must recover, not give up")
    }
}
