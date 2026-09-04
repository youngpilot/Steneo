import AVFoundation
import XCTest
@testable import Steneo

/// Guards the failure Julian hit twice: the audio engine wedges on a stale input
/// format and every start afterwards fails with -10868 (format not supported),
/// forever, with nothing but a blinking menubar icon to show for it.
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

    // MARK: - The recovery policy (no microphone needed)

    func testRecoveryRebuildsBeforeRetrying() {
        var order: [String] = []
        let ok = AudioCaptureService.retryAfterRebuild(
            rebuild: { order.append("rebuild") },
            start: { order.append("start") },
            onError: { _ in order.append("error") })
        XCTAssertTrue(ok)
        XCTAssertEqual(order, ["rebuild", "start"], "rebuilding first is the whole point — retrying the same wedged engine changes nothing")
    }

    func testRecoveryGivesUpAfterOneRetry() {
        var starts = 0
        var reported: Error?
        let ok = AudioCaptureService.retryAfterRebuild(
            rebuild: {},
            start: { starts += 1; throw NSError(domain: NSOSStatusErrorDomain, code: -10868) },
            onError: { reported = $0 })
        XCTAssertFalse(ok)
        XCTAssertEqual(starts, 1, "one retry, not an endless loop against dead hardware")
        XCTAssertEqual((reported as NSError?)?.code, -10868, "the real reason must reach the log, not a generic failure")
    }

    /// The whole point of the fix: a start that fails must rebuild the engine and
    /// come back up, rather than reporting failure and leaving the app stuck.
    func testStartRecoversFromAWedgedEngine() throws {
        try requireMicrophone()
        let service = AudioCaptureService()

        // Positive control first: without the fault, this service starts. Without
        // it, a "recovered" result below could just mean nothing ever broke.
        XCTAssertNil(start(service, "baseline"), "baseline start must succeed")

        service.failNextStartForTesting = true
        XCTAssertNil(start(service, "recovery"), "a failed start must recover, not give up")
    }

    /// A hardware change must not leave the service unable to start again.
    func testConfigurationChangeDoesNotWedgeTheService() throws {
        try requireMicrophone()
        let service = AudioCaptureService()
        XCTAssertNil(start(service, "before"), "baseline start must succeed")

        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: nil)
        // The handler runs on the service's serial queue; give it a beat to land.
        Thread.sleep(forTimeInterval: 0.3)

        XCTAssertNil(start(service, "after"), "must still start after a configuration change")
    }

    // MARK: - The storm, against the real service

    /// Drains everything queued on the service's serial queue by posting one more
    /// notification and waiting for its handler to finish.
    private func settle(_ seconds: TimeInterval = 0.6) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }

    /// What actually happened on 04.09.2026: a flood of configuration-change
    /// notifications while the input was in fact unchanged. The 1.4.1 handler
    /// rebuilt on every single one.
    func testAFloodOfNotificationsAboutNothingRebuildsNothing() {
        let service = AudioCaptureService()
        for _ in 0..<200 {
            NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: nil)
        }
        settle()
        XCTAssertEqual(service.rebuildCountForTesting, 0,
                       "the input never changed; the old handler rebuilt 200 times")
    }

    /// And when the input really does keep changing, the fuse has to cap it and
    /// the user has to be told — not a microphone that quietly does nothing.
    func testRelentlessRealChangeIsCappedAndReported() throws {
        let service = AudioCaptureService()
        // Prime the input chain: with nothing built and nothing recording there
        // is deliberately nothing to rebuild, so an unprimed service would pass
        // this test by doing nothing at all.
        service.primeInputChainForTesting()
        try XCTSkipUnless(service.hasInputChainForTesting,
                          "this Mac gave the test runner no input format to build a chain from")

        let counter = Counter()
        service.signatureOverrideForTesting = { "device-\(counter.next())" }
        let told = expectation(description: "input reported unavailable")
        told.assertForOverFulfill = false
        service.onInputUnavailable = { _ in told.fulfill() }

        for _ in 0..<200 {
            NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: nil)
        }
        wait(for: [told], timeout: 5)
        settle()
        XCTAssertLessThanOrEqual(service.rebuildCountForTesting, 10,
                                 "200 real changes must not mean 200 rebuilds")
        XCTAssertGreaterThan(service.rebuildCountForTesting, 0,
                             "positive control: a real change must rebuild at least once")
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    }

}
