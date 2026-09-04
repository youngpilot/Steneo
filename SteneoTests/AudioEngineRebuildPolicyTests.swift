import XCTest
@testable import Steneo

/// Brake, fuse and precondition for configuration-change notifications.
///
/// The measurement these tests exist for: on 04.09.2026 Steneo rebuilt its audio
/// engine 1727 times in ten minutes, 109 ms apart, for over four hours, because
/// the 1.4.1 handler rebuilt on every notification with no conditions at all.
final class AudioEngineRebuildPolicyTests: XCTestCase {

    private func decisions(_ policy: inout AudioEngineRebuildPolicy,
                           count: Int, spacing: TimeInterval, signatureChanged: Bool,
                           start: TimeInterval = 1000) -> [AudioEngineRebuildPolicy.Decision] {
        (0..<count).map { policy.decide(at: start + Double($0) * spacing, signatureChanged: signatureChanged) }
    }

    // MARK: - The precondition

    /// A notification that reports the state we are already in is not a reason to
    /// tear anything down. This alone would have prevented the storm.
    func testNothingHappensWhenNothingChanged() {
        var policy = AudioEngineRebuildPolicy()
        let d = decisions(&policy, count: 50, spacing: 0.109, signatureChanged: false)
        XCTAssertTrue(d.allSatisfy { $0 == .unchanged })
        XCTAssertFalse(policy.isCircuitOpen, "ignoring noise must not blow the fuse either")
    }

    func testARealChangeRebuilds() {
        var policy = AudioEngineRebuildPolicy()
        XCTAssertEqual(policy.decide(at: 1000, signatureChanged: true), .rebuild)
    }

    // MARK: - The brake

    func testASecondChangeTooSoonIsHeldBack() {
        var policy = AudioEngineRebuildPolicy(minimumInterval: 0.5)
        XCTAssertEqual(policy.decide(at: 1000.0, signatureChanged: true), .rebuild)
        XCTAssertEqual(policy.decide(at: 1000.1, signatureChanged: true), .tooSoon)
        XCTAssertEqual(policy.decide(at: 1000.4, signatureChanged: true), .tooSoon)
        XCTAssertEqual(policy.decide(at: 1000.6, signatureChanged: true), .rebuild,
                       "after the interval a real change must still get through — this is recovery, not a mute button")
    }

    // MARK: - The fuse

    func testRelentlessChangeBlowsTheFuseInsteadOfLoopingForever() {
        var policy = AudioEngineRebuildPolicy(minimumInterval: 0, burstLimit: 6, burstWindow: 5)
        let d = decisions(&policy, count: 200, spacing: 0.109, signatureChanged: true)
        XCTAssertEqual(d.filter { $0 == .rebuild }.count, 6, "the fuse caps the damage at the burst limit")
        XCTAssertTrue(policy.isCircuitOpen)
        XCTAssertTrue(d.suffix(100).allSatisfy { $0 == .circuitOpen }, "once open it stays open — no silent re-arming")
    }

    /// The storm as it was actually measured, replayed against the policy.
    func testTheMeasuredStormIsBounded() {
        var policy = AudioEngineRebuildPolicy()
        // 1727 notifications, 109 ms apart, each looking like a real change.
        let d = decisions(&policy, count: 1727, spacing: 0.109, signatureChanged: true)
        let rebuilds = d.filter { $0 == .rebuild }.count
        XCTAssertLessThanOrEqual(rebuilds, 10, "1727 notifications produced 1727 rebuilds; now at most a handful")
        XCTAssertTrue(policy.isCircuitOpen, "and the user has to be told, not left with a dead microphone")
    }

    /// Counter-check: this is what the 1.4.1 handler did. If the assertion below
    /// ever describes the shipped behaviour again, the tests above are decoration.
    func testTheOldUnconditionalBehaviourWouldFailTheseTests() {
        // The 1.4.1 handler, in one line: every notification rebuilds.
        let oldBehaviour: (Int) -> Int = { notifications in notifications }
        XCTAssertEqual(oldBehaviour(1727), 1727)

        var policy = AudioEngineRebuildPolicy()
        let new = decisions(&policy, count: 1727, spacing: 0.109, signatureChanged: true)
            .filter { $0 == .rebuild }.count
        XCTAssertLessThan(new, oldBehaviour(1727) / 100,
                          "the new policy must be at least two orders of magnitude quieter")
    }

    // MARK: - Recovery

    func testASuccessfulStartPutsTheFuseBack() {
        var policy = AudioEngineRebuildPolicy(minimumInterval: 0, burstLimit: 3, burstWindow: 5)
        _ = decisions(&policy, count: 20, spacing: 0.1, signatureChanged: true)
        XCTAssertTrue(policy.isCircuitOpen)

        policy.reset()
        XCTAssertFalse(policy.isCircuitOpen)
        XCTAssertEqual(policy.decide(at: 2000, signatureChanged: true), .rebuild,
                       "one bad stretch must not disable recovery for the rest of the session")
    }

    /// Changes spread out over time are normal life (docking, unplugging a
    /// headset) and must never blow the fuse.
    func testOccasionalDeviceChangesAreAllRebuilt() {
        var policy = AudioEngineRebuildPolicy()
        let d = decisions(&policy, count: 20, spacing: 30, signatureChanged: true)
        XCTAssertTrue(d.allSatisfy { $0 == .rebuild }, "a device change every 30 s is a user, not a storm")
        XCTAssertFalse(policy.isCircuitOpen)
    }
}
