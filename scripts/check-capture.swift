// Release check C: the capture core against this Mac's real microphones.
//
// Built from the app's own source files (see check-capture.sh), so what runs
// here is what ships. It records the room for a few seconds. It plays nothing,
// changes no volume and switches no device.
//
// Why it exists: the unit tests that need a microphone are skipped, because the
// test host has no microphone access. Until this check, a rewritten capture
// core could pass every test without one buffer having come from hardware.
//
// Exit: 0 everything held · 1 something is broken · 2 nothing could be judged
// (no microphone access for the process running this).

import AVFoundation
import Accelerate
import Foundation

final class Outcome: @unchecked Sendable {
    private let lock = NSLock()
    private var _info: CaptureStartInfo?
    private var _liveAt: Date?
    private var _error: AudioCaptureError?
    private var _blocks = 0
    func started(_ info: CaptureStartInfo) { lock.lock(); _info = info; lock.unlock() }
    func live(_ error: AudioCaptureError?) { lock.lock(); _error = error; _liveAt = Date(); lock.unlock() }
    func block() { lock.lock(); _blocks += 1; lock.unlock() }
    var info: CaptureStartInfo? { lock.lock(); defer { lock.unlock() }; return _info }
    var liveAt: Date? { lock.lock(); defer { lock.unlock() }; return _liveAt }
    var error: AudioCaptureError? { lock.lock(); defer { lock.unlock() }; return _error }
    var blocks: Int { lock.lock(); defer { lock.unlock() }; return _blocks }
}

struct Recording {
    let liveAfter: Double          // ms from the start call to the first audio kept
    let info: CaptureStartInfo
    let seconds: Double            // what came out
    let expected: Double           // what should have: the time it ran
    let level: Float
    let blocks: Int
    let heartbeat: TimeInterval?
    let heard: (uid: String, milliseconds: Double)?
}

@main
enum CheckCapture {
    nonisolated(unsafe) static var failures = 0

    static func expect(_ condition: Bool, _ what: String) {
        print(condition ? "   ✓ \(what)" : "   ✗ \(what)")
        if !condition { failures += 1 }
    }

    static func level(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        return rms
    }

    /// One recording of `seconds`, from start call to hand-over.
    static func record(_ service: AudioCaptureService, preferred: String?, seconds: Double) -> Recording? {
        let outcome = Outcome()
        let live = DispatchSemaphore(value: 0), settled = DispatchSemaphore(value: 0)
        service.preferredDeviceUID = preferred
        service.onStarted = { outcome.started($0); settled.signal() }
        let pressed = Date()
        service.startCapture(onBuffer: { _ in outcome.block() }, onLevel: { _ in }) { error in
            outcome.live(error)
            live.signal()
        }
        guard live.wait(timeout: .now() + 6) == .success, let liveAt = outcome.liveAt else {
            expect(false, "the start reported back at all")
            service.stopCapture()
            return nil
        }
        if let error = outcome.error {
            expect(false, "a recording started (got: \(error.localizedDescription))")
            return nil
        }
        guard settled.wait(timeout: .now() + 6) == .success, let info = outcome.info else {
            expect(false, "the recording settled on a microphone")
            service.stopCapture()
            return nil
        }
        let remaining = seconds - Date().timeIntervalSince(pressed)
        if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
        let heartbeat = service.secondsSinceLastBuffer
        let heard = service.leadHearsAfter
        let stopped = Date()
        service.stopCapture()
        let taken = service.takeRecording()
        return Recording(liveAfter: liveAt.timeIntervalSince(pressed) * 1000, info: info,
                         seconds: Double(taken.samples.count) / taken.rate,
                         expected: stopped.timeIntervalSince(liveAt), level: level(taken.samples),
                         blocks: outcome.blocks, heartbeat: heartbeat, heard: heard)
    }

    /// What every recording has to satisfy, whatever microphone it ran on.
    static func judge(_ r: Recording, liveWithin: Double) {
        print(String(format: "   live after %.0f ms on %@, %.2f s recorded of %.2f s",
                     r.liveAfter, r.info.device.name, r.seconds, r.expected))
        expect(r.liveAfter < liveWithin, String(format: "live within %.0f ms", liveWithin))
        expect(abs(r.seconds - r.expected) < 0.15, "as long as the time it ran: no hole, nothing twice")
        expect(r.level > 0.000_001, "it holds sound, not zeros")
        expect(r.blocks > 0, "the level meter and the VAD were fed")
        expect((r.heartbeat ?? 9) < 0.3, "audio was still arriving at the end")
    }

    static func main() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        guard status == .authorized else {
            print("Check C could not run: this process has no microphone access (status \(status.rawValue)).")
            print("That says nothing about the build.")
            exit(2)
        }
        let snapshot = AudioDeviceResolver.snapshot()
        guard !snapshot.inputs.isEmpty else {
            print("Check C could not run: this Mac reports no microphone.")
            exit(2)
        }
        let builtIn = snapshot.inputs.first(where: \.isBuiltIn)
        let external = snapshot.inputs.first { !$0.isBuiltIn && !$0.isBluetooth }
        print("Microphones: " + snapshot.inputs.map(\.name).joined(separator: ", "))
        let service = AudioCaptureService()

        print("1. Automatic")
        if let r = record(service, preferred: nil, seconds: 1.5) {
            judge(r, liveWithin: builtIn == nil ? 1500 : 300)
            if builtIn != nil { expect(r.info.device.isBuiltIn, "with nothing measured, the Mac's own microphone is the fastest") }
            expect(r.heard != nil, "it is known when the microphone began to hear"
                   + (r.heard.map { String(format: " (after %.0f ms)", $0.milliseconds) } ?? ""))
        }

        if let external {
            print("2. A chosen microphone: \(external.name)")
            if let r = record(service, preferred: external.uid, seconds: 1.5) {
                // With a built-in microphone to bridge, a slow device must not delay the recording.
                judge(r, liveWithin: builtIn == nil ? 1500 : 300)
                expect(r.info.device.uid == external.uid, "the recording ended up on the chosen microphone")
            }

            if snapshot.inputs.count > 1 {
                print("3. The chosen microphone does not start")
                service.failNextStartForTesting = true
                if let r = record(service, preferred: external.uid, seconds: 1.2) {
                    judge(r, liveWithin: builtIn == nil ? 1500 : 300)
                    expect(r.info.device.uid != external.uid, "the recording runs on another microphone")
                    expect(r.info.failedNames.contains(external.name), "and says which one did not start")
                }
            }
        } else {
            print("2./3. skipped: no external microphone connected")
        }

        Thread.sleep(forTimeInterval: 0.3)   // let the last device close
        if failures == 0 {
            print("Check C passed.")
            exit(0)
        }
        print("Check C FAILED: \(failures) point(s) above.")
        exit(1)
    }
}
