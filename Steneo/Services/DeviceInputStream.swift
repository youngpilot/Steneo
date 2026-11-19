import CoreAudio
import Foundation
import os

private let logger = Logger(subsystem: "com.youngpilot.Steneo", category: "AudioCapture")

/// One microphone, read directly from the device.
///
/// No AVAudioEngine in between. Measured on 19.11.2026, per start: about 15 ms
/// to set up against about 90 ms, and nine of nine starts delivered audio where
/// the engine managed seven of nine. It also removes a whole class of trouble
/// the engine brought along: formats cached from before a device was selected,
/// a hidden jump to the main queue, configuration notifications to react to.
///
/// What it cannot change is the device itself. A USB display microphone needs
/// about 450 ms before its first sample exists, the Mac's own about 35 ms. That
/// is what the bridge in `AudioCaptureService` is for.
final class DeviceInputStream: @unchecked Sendable {
    let device: AudioDevice
    /// The rate the samples arrive at.
    let sampleRate: Double

    private let lock = NSLock()
    private var procID: AudioDeviceIOProcID?
    private var beganAt = DispatchTime.now()
    private var firstBufferAfter: Double?
    private let firstBuffer = DispatchSemaphore(value: 0)

    /// How long this device took from `start` to its first buffer, in
    /// milliseconds. nil until one arrived.
    var startMilliseconds: Double? {
        lock.lock(); defer { lock.unlock() }
        return firstBufferAfter
    }

    /// nil when the device has no input format this class can read. The HAL
    /// presents every device as 32-bit float PCM; anything else is refused
    /// rather than misread.
    init?(device: AudioDevice) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(device.id, &address, 0, nil, &size, &format) == noErr,
              format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32,
              format.mSampleRate > 0
        else { return nil }
        self.device = device
        self.sampleRate = format.mSampleRate
    }

    deinit { stop() }

    /// Start the device. Blocks for as long as the hardware takes to start —
    /// which is the whole latency of a recording — so call it off the main
    /// thread. `deliver` receives channel 0 and the host time of its first
    /// frame, on `queue`.
    func start(on queue: DispatchQueue,
               deliver: @escaping @Sendable (_ samples: [Float], _ hostTime: UInt64) -> Void) -> Bool {
        lock.lock()
        beganAt = DispatchTime.now()
        lock.unlock()

        var created: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&created, device.id, queue) { [weak self] _, input, inputTime, _, _ in
            guard let self else { return }
            let samples = Self.firstChannel(of: input)
            guard !samples.isEmpty else { return }
            self.noteBuffer()
            // A buffer without a valid capture time is stamped with its arrival,
            // which is one IO cycle late. Close enough to join two microphones on.
            let stamp = inputTime.pointee
            deliver(samples, stamp.mFlags.contains(.hostTimeValid) ? stamp.mHostTime : mach_absolute_time())
        }
        guard status == noErr, let created else {
            logger.error("\(self.device.name, privacy: .public): no IO proc (OSStatus \(status, privacy: .public))")
            return false
        }
        let started = AudioDeviceStart(device.id, created)
        guard started == noErr else {
            AudioDeviceDestroyIOProcID(device.id, created)
            logger.error("\(self.device.name, privacy: .public) did not start (OSStatus \(started, privacy: .public))")
            return false
        }
        lock.lock()
        procID = created
        lock.unlock()
        return true
    }

    /// True once a buffer has arrived. A device that starts and delivers nothing
    /// has not started.
    func waitForFirstBuffer(timeout: TimeInterval) -> Bool {
        if startMilliseconds != nil { return true }
        return firstBuffer.wait(timeout: .now() + timeout) == .success
    }

    func stop() {
        lock.lock()
        let running = procID
        procID = nil
        lock.unlock()
        guard let running else { return }
        AudioDeviceStop(device.id, running)
        AudioDeviceDestroyIOProcID(device.id, running)
    }

    private func noteBuffer() {
        lock.lock()
        let isFirst = firstBufferAfter == nil
        if isFirst {
            firstBufferAfter = Double(DispatchTime.now().uptimeNanoseconds - beganAt.uptimeNanoseconds) / 1_000_000
        }
        lock.unlock()
        if isFirst { firstBuffer.signal() }
    }

    /// Channel 0 of the first buffer. A device hands over one buffer per stream,
    /// its channels interleaved; stepping by the buffer's own channel count reads
    /// the first channel whether there is one or several.
    static func firstChannel(of list: UnsafePointer<AudioBufferList>) -> [Float] {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let buffer = buffers.first, let data = buffer.mData else { return [] }
        let channels = max(1, Int(buffer.mNumberChannels))
        let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
        guard frames > 0 else { return [] }
        return firstChannel(of: UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self),
                                                    count: frames * channels),
                            channels: channels)
    }

    /// The pure half of the above, so the stride is tested without a device.
    static func firstChannel(of interleaved: UnsafeBufferPointer<Float>, channels: Int) -> [Float] {
        guard channels > 1 else { return Array(interleaved) }
        return stride(from: 0, to: interleaved.count - channels + 1, by: channels).map { interleaved[$0] }
    }
}
