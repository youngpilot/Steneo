import AVFoundation
import Foundation
import Observation
import os

private let logger = Logger(subsystem: "com.youngpilot.Steneo", category: "Recovery")

/// One recording that produced no text and was kept instead of being discarded.
struct RecoveredRecording: Identifiable, Equatable, Sendable {
    let url: URL
    let date: Date
    let reason: RecordingFailure

    var id: URL { url }
}

/// Keeps the audio of recordings that produced nothing, so a failure is
/// recoverable instead of gone.
///
/// The point is not the files. The point is that a recording can no longer
/// disappear without a trace: whatever went wrong upstream, the audio is on disk
/// and can be transcribed again by hand.
@Observable
@MainActor
final class RecoveryStore {
    static let shared = RecoveryStore()

    private(set) var entries: [RecoveredRecording] = []

    /// Ten is enough to cover a bad stretch and small enough that nobody has to
    /// think about disk space: a minute of 48 kHz mono is about 5 MB.
    static let keepCount = 10

    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory
        refresh()
    }

    private static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Steneo/Recovered", isDirectory: true)
    }

    // MARK: - Naming (pure, so the round trip is testable)

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        // Lexical order == chronological order, which is what pruning relies on.
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return f
    }()

    static func fileName(date: Date, reason: RecordingFailure) -> String {
        "\(stamp.string(from: date))_\(reason.rawValue).wav"
    }

    static func parse(fileName: String) -> (date: Date, reason: RecordingFailure)? {
        guard fileName.hasSuffix(".wav") else { return nil }
        let base = String(fileName.dropLast(4))
        // The reason is the part after the LAST underscore; the timestamp itself
        // contains none, but a future reason with one must not break parsing.
        guard let separator = base.lastIndex(of: "_") else { return nil }
        let stampPart = String(base[base.startIndex..<separator])
        let reasonPart = String(base[base.index(after: separator)...])
        guard let date = stamp.date(from: stampPart),
              let reason = RecordingFailure(rawValue: reasonPart) else { return nil }
        return (date, reason)
    }

    /// Which files to remove so only the newest `keeping` remain. Pure: pruning
    /// deletes user data, so its rule is tested rather than trusted.
    static func namesToPrune(_ names: [String], keeping: Int) -> [String] {
        let recovered = names.filter { parse(fileName: $0) != nil }
        guard recovered.count > keeping else { return [] }
        // Names sort chronologically by construction; newest last.
        return Array(recovered.sorted().dropLast(keeping))
    }

    // MARK: - Store

    /// Async because the write is: ten minutes of 48 kHz audio is a ~57 MB file,
    /// and this runs at the end of a recording, when the app is on the main actor
    /// and the user is waiting to see something happen.
    @discardableResult
    func save(samples: [Float], rate: Double, reason: RecordingFailure, date: Date = Date()) async -> URL? {
        guard reason.hasRecoverableAudio, !samples.isEmpty, rate > 0 else { return nil }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(Self.fileName(date: date, reason: reason))
            let payload = UncheckedSendableBox(samples)
            try await Task.detached(priority: .utility) {
                try Self.writeWAV(samples: payload.value, rate: rate, to: url)
            }.value
            prune()
            refresh()
            logger.info("Kept \(samples.count, privacy: .public) samples for recovery (\(reason.rawValue, privacy: .public))")
            return url
        } catch {
            logger.error("Could not keep the recording: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func delete(_ recording: RecoveredRecording) {
        try? FileManager.default.removeItem(at: recording.url)
        refresh()
    }

    func deleteAll() {
        for entry in entries { try? FileManager.default.removeItem(at: entry.url) }
        refresh()
    }

    func refresh() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        entries = names.compactMap { name in
            guard let parsed = Self.parse(fileName: name) else { return nil }
            return RecoveredRecording(url: directory.appendingPathComponent(name),
                                      date: parsed.date, reason: parsed.reason)
        }
        .sorted { $0.date > $1.date }
    }

    private func prune() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in Self.namesToPrune(names, keeping: Self.keepCount) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// 16-bit mono WAV at the capture rate — readable by anything, including
    /// Steneo's own file transcription, which is what "try again" runs.
    nonisolated static func writeWAV(samples: [Float], rate: Double, to url: URL) throws {
        guard let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: rate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat,
                                            frameCapacity: AVAudioFrameCount(samples.count))
        else { throw CocoaError(.fileWriteUnknown) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer {
            buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count)
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: buffer)
    }
}
