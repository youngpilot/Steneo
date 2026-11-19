import AVFoundation

/// Converts a finished mono signal to another sample rate in ONE pass.
///
/// One pass, because a converter warms its filter up at the start of whatever
/// it is given: converting buffer by buffer puts that warm-up into every
/// buffer and garbles short clips. Its own file, with nothing but AVFoundation
/// behind it, so the capture code can be built and checked without the speech
/// model.
enum AudioResampler {
    static func resample(_ samples: [Float], from inRate: Double, to outRate: Double = 16000) -> [Float] {
        guard !samples.isEmpty, inRate > 0, inRate != outRate,
              let inFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inRate, channels: 1, interleaved: false),
              let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outRate, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: inFmt, to: outFmt),
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(samples.count))
        else { return samples }
        inBuf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { inBuf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }

        let outCap = AVAudioFrameCount((Double(samples.count) * outRate / inRate).rounded(.up)) + 4096
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outCap) else { return samples }
        var error: NSError?
        var fed = false
        conv.convert(to: outBuf, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return inBuf
        }
        guard error == nil, outBuf.frameLength > 0 else { return samples }
        return Array(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength)))
    }
}
