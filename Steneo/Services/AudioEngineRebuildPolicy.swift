import Foundation

/// Decides whether a configuration-change notification should actually rebuild
/// the audio input.
///
/// This exists because the 1.4.1 recovery had no such decision: it rebuilt on
/// EVERY notification. On 04.09.2026 that ran at nine rebuilds per second for
/// over four hours (measured: 1727 in ten minutes, 109 ms apart), because each
/// fresh engine asked for a device that no longer existed and posted the next
/// notification while failing over. A reaction to a fault needs three things or
/// it becomes the fault: a brake, a fuse, and a precondition.
///
/// Pure and time-injected so all three are testable without an audio device —
/// none of these states can be produced on demand on a healthy machine.
struct AudioEngineRebuildPolicy: Equatable {

    enum Decision: Equatable {
        /// Rebuild the input chain.
        case rebuild
        /// Nothing actually changed — the precondition.
        case unchanged
        /// Too soon after the last rebuild — the brake.
        case tooSoon
        /// Too many rebuilds in too short a window — the fuse. The input is
        /// declared unavailable and REPORTED; it is not retried until something
        /// resets the policy.
        case circuitOpen
    }

    /// At most one rebuild per this interval.
    var minimumInterval: TimeInterval = 0.5
    /// More than this many rebuilds inside `burstWindow` blows the fuse.
    var burstLimit: Int = 6
    var burstWindow: TimeInterval = 5.0

    private(set) var isCircuitOpen = false
    private var lastRebuild: TimeInterval?
    /// Change-triggered ATTEMPTS, not executed rebuilds. Counting only what got
    /// through would let a throttled loop run for ever at two rebuilds a second:
    /// slower than the storm we measured, and just as endless.
    private var recentAttempts: [TimeInterval] = []

    /// Spelled out because the private stored properties above would otherwise
    /// make the memberwise initialiser private too, and the tests need to dial
    /// these knobs.
    init(minimumInterval: TimeInterval = 0.5, burstLimit: Int = 6, burstWindow: TimeInterval = 5.0) {
        self.minimumInterval = minimumInterval
        self.burstLimit = burstLimit
        self.burstWindow = burstWindow
    }

    /// `signatureChanged` is the precondition: the caller compares the resolved
    /// input device and its format against the last one it built for. A
    /// notification that reports the state we are already in is not a reason to
    /// tear anything down.
    mutating func decide(at now: TimeInterval, signatureChanged: Bool) -> Decision {
        if isCircuitOpen { return .circuitOpen }
        guard signatureChanged else { return .unchanged }

        // The fuse counts attempts, before the brake — otherwise a loop that the
        // brake slows down would never trip it, and a slow endless loop is still
        // an endless loop.
        recentAttempts.append(now)
        recentAttempts.removeAll { now - $0 > burstWindow }
        if recentAttempts.count > burstLimit {
            isCircuitOpen = true
            return .circuitOpen
        }

        if let last = lastRebuild, now - last < minimumInterval { return .tooSoon }
        lastRebuild = now
        return .rebuild
    }

    /// Called when capture starts successfully: the input works again, so the
    /// fuse goes back in. Without this a single bad stretch would disable
    /// recovery for the rest of the app's life.
    mutating func reset() {
        isCircuitOpen = false
        lastRebuild = nil
        recentAttempts = []
    }
}
