#if DEBUG
import AVFoundation
import FluidAudio
import Foundation

/// The gate for speaker recognition (1.6.0): does diarization actually put words
/// on the right speaker?
///
/// Lives in the app target because that is where FluidAudio is linked — the test
/// bundle is hosted by the app and must not link the package a second time. DEBUG
/// only, so none of this reaches a release build. If the measurement passes, this
/// is also the skeleton the real feature grows from.
enum DiarizationMeasurement {

    struct Turn {
        let url: URL
        let speaker: String
    }

    struct Report {
        let turns: Int
        let seconds: Double
        let trueSpeakers: Int
        let detectedSpeakers: Int
        let tokensScored: Int
        let tokensUnassigned: Int
        let accuracy: Double
        /// Echoed back so a run can never be read as testing settings it never got.
        let config: String

        var summary: String {
            String(format: "%.1f%% of %d tokens on the right speaker (%d unassigned) · %d/%d speakers · %.1fs · %@",
                   accuracy * 100, tokensScored, tokensUnassigned, detectedSpeakers, trueSpeakers, seconds, config)
        }
    }

    /// Concatenates the turns into one recording (keeping the ground truth by
    /// construction), diarizes it, transcribes it, and scores every token.
    static func run(turns: [Turn], expectedSpeakers: Int? = nil, threshold: Float? = nil) async throws -> Report {
        let rate = 16000.0
        let converter = AudioConverter()
        var samples: [Float] = []
        var truth: [(start: Double, end: Double, speaker: String)] = []
        for turn in turns {
            let clip = try converter.resampleAudioFile(turn.url)
            let start = Double(samples.count) / rate
            samples.append(contentsOf: clip)
            truth.append((start, Double(samples.count) / rate, turn.speaker))
        }

        let models = try await DiarizerModels.downloadIfNeeded()
        var config = DiarizerConfig()
        if let expectedSpeakers { config.numClusters = expectedSpeakers }
        if let threshold { config.clusteringThreshold = threshold }
        let diarizer = DiarizerManager(config: config)
        diarizer.initialize(models: consume models)
        let segments = try diarizer.performCompleteDiarization(samples, sampleRate: Int(rate)).segments

        let wav = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("steneo-measure-\(UUID().uuidString).wav")
        try writeWAV(samples, rate: rate, to: wav)
        defer { try? FileManager.default.removeItem(at: wav) }

        let asr = AsrManager()
        try await asr.initialize(models: try await AsrModels.downloadAndLoad())
        let asrResult = try await asr.transcribe(wav, source: .system)
        let timings = asrResult.tokenTimings ?? []

        func trueSpeaker(at t: Double) -> String? { truth.first { t >= $0.start && t < $0.end }?.speaker }
        func label(at t: Double) -> String? {
            segments.first { t >= Double($0.startTimeSeconds) && t < Double($0.endTimeSeconds) }?.speakerId
        }

        // Diarizer labels are arbitrary. Each is mapped to the true speaker it
        // overlaps most, otherwise a perfect result would score as wrong purely
        // because the labels came out in a different order.
        var overlap: [String: [String: Int]] = [:]
        for token in timings {
            let mid = (token.startTime + token.endTime) / 2
            guard let t = trueSpeaker(at: mid), let l = label(at: mid) else { continue }
            overlap[l, default: [:]][t, default: 0] += 1
        }
        let mapping = overlap.mapValues { $0.max { $0.value < $1.value }!.key }

        var correct = 0, scored = 0, unassigned = 0
        for token in timings where !token.token.trimmingCharacters(in: .whitespaces).isEmpty {
            let mid = (token.startTime + token.endTime) / 2
            guard let t = trueSpeaker(at: mid) else { continue }
            scored += 1
            guard let l = label(at: mid) else { unassigned += 1; continue }
            if mapping[l] == t { correct += 1 }
        }

        return Report(
            turns: turns.count,
            seconds: Double(samples.count) / rate,
            trueSpeakers: Set(truth.map(\.speaker)).count,
            detectedSpeakers: Set(segments.map(\.speakerId)).count,
            tokensScored: scored,
            tokensUnassigned: unassigned,
            accuracy: scored > 0 ? Double(correct) / Double(scored) : 0,
            config: "clusters=\(config.numClusters) threshold=\(config.clusteringThreshold)")
    }

    private static func writeWAV(_ samples: [Float], rate: Double, to url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ])
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buffer)
    }
}
#endif
