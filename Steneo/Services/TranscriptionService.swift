import AVFoundation
import FluidAudio
import Foundation
import NaturalLanguage
import Observation
import os

private let logger = Logger(subsystem: "com.youngpilot.Steneo", category: "Transcription")

@Observable
@MainActor
final class TranscriptionService {
    private(set) var isModelLoaded = false
    private(set) var isTranscribing = false
    /// Why the last recording produced no text, or nil if it produced text.
    /// Set once per recording in `stopTranscription`.
    private(set) var lastFailure: RecordingFailure?
    /// Whether the batch engine threw on the final pass — the difference between
    /// "heard nothing" and "the model failed", which used to be the same empty string.
    private var tailTranscribeThrew = false
    private(set) var currentText = ""
    private(set) var modelLoadingStep = ""

    private let textReplacement = TextReplacementService.shared
    private let voiceCommands = VoiceCommandService.shared

    // Shared FluidAudio components
    private var asrModels: UncheckedSendableBox<AsrModels>?
    private var batchAsr: AsrManager?        // ONE batch engine: live dictation (v2) + file transcription
    private var vadManager: VadManager?

    // --- Capture state (v2: buffer raw audio during recording, transcribe ONCE
    // at stop with the full-context batch engine — no streaming windows). This is
    // why short clips don't garble and the first words are never lost to ASR
    // warm-up: the model only runs at stop, on the complete audio.
    private var isCapturing = false                 // mic is live; buffer audio
    private var audioConsumer: Task<Void, Never>?   // lone, serial consumer of the audio stream

    // --- VAD state (auto-stop) ---
    private var vadBuffer: [Float] = []
    private var vadStreamState: VadStreamState = .initial()
    private var lastSpeechTime: Date?

    // --- Incremental segmentation (long recordings) ---
    // At a clear mid-recording pause, once the current segment is long enough, the
    // finished segment's raw audio is transcribed in the BACKGROUND. At stop only the
    // final tail is transcribed, so the stop→paste wait stays short regardless of
    // length. Boundaries fall on VAD silence (never mid-word), so accuracy holds.
    private var lastCutTime: Date?
    private var cutPending = false                    // at most one cut per silence period
    private var segmentIndex = 0
    private var segmentResults: [Int: String] = [:]   // cut index → transcribed text
    private var segmentTasks: [Task<Void, Never>] = []
    /// Injected by RecordingManager: hand over the raw audio recorded since the last cut.
    var segmentProvider: (() -> (samples: [Float], rate: Double))?
    private static let minSegmentSeconds: TimeInterval = 30   // only long recordings segment
    private static let cutSilenceSeconds: TimeInterval = 0.8  // a clear pause = safe cut point

    // Language detection + confidence (set from the batch result where available)
    private(set) var detectedLanguage = ""
    private(set) var lastConfidence: Float = 0
    private(set) var minTokenConfidence: Float = 0
    private(set) var avgTokenConfidence: Float = 0

    var onSilenceTimeout: (() -> Void)?

    // MARK: - Model Loading

    /// The one load in flight (or finished). A recording that ends before the
    /// model is ready waits on exactly this, instead of being refused at the
    /// shortcut: capturing audio has never needed the model, only the
    /// transcription at stop does.
    private var modelLoad: Task<Void, Error>?

    func loadModel() async throws {
        if let modelLoad { return try await modelLoad.value }
        let task = Task { @MainActor in try await self.performModelLoad() }
        modelLoad = task
        do {
            try await task.value
        } catch {
            modelLoad = nil   // a failed load may be retried
            throw error
        }
    }

    private func performModelLoad() async throws {
        modelLoadingStep = "Downloading ASR model… (1/2)"
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        asrModels = UncheckedSendableBox(models)

        // One batch engine powers both live dictation (transcribe at stop) and
        // file transcription — full context, best accuracy. Initialized up front
        // so stopping a recording transcribes immediately.
        let manager = AsrManager()
        try await manager.initialize(models: models)
        batchAsr = manager

        // VAD powers auto-stop and paragraph-break detection.
        modelLoadingStep = "Loading VAD model… (2/2)"
        vadManager = try await VadManager()

        modelLoadingStep = ""
        isModelLoaded = true
    }

    // MARK: - Start / Stop (live dictation → buffer, then ONE batch at stop)

    /// Reset state and mark capture active — cheap + synchronous so the mic can
    /// start and buffer instantly.
    func beginCapturing() {
        currentText = ""
        vadBuffer = []
        vadStreamState = .initial()
        lastSpeechTime = Date()
        lastCutTime = Date()
        cutPending = false
        segmentIndex = 0
        segmentResults = [:]
        segmentTasks.forEach { $0.cancel() }
        segmentTasks = []
        detectedLanguage = ""
        lastConfidence = 0
        minTokenConfidence = 0
        avgTokenConfidence = 0
        lastFailure = nil
        tailTranscribeThrew = false
        isCapturing = true
    }

    /// Create the single, ordered audio pipeline and start its lone consumer.
    /// Returns the continuation the audio tap yields into. One ordered stream +
    /// one serial consumer = in-capture-order buffering, no races.
    func startAudioPipeline() -> AsyncStream<[Float]>.Continuation {
        audioConsumer?.cancel()
        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        audioConsumer = Task { @MainActor [weak self] in
            for await samples in stream {
                await self?.feed(samples)
            }
        }
        return continuation
    }

    /// Wait for the consumer to drain every remaining buffer after the
    /// continuation is finished, so the batch pass sees the complete audio.
    func awaitAudioConsumer() async {
        await audioConsumer?.value
        audioConsumer = nil
    }

    /// v2: no streaming session during recording — just confirm the batch engine
    /// is ready (so stop is fast). Audio is buffered by feed().
    func startTranscription() async {
        guard isCapturing else { return }
        // Deliberately no model check: if it is still loading, the audio is
        // recorded all the same and `batchEngine()` waits for it at stop.
        isTranscribing = true
    }

    /// Stop capture and transcribe the whole buffer in ONE batch pass (full
    /// context). Returns the final text.
    func stopTranscription(rawSamples: [Float], rate: Double) async -> String {
        isCapturing = false
        guard isTranscribing else { return currentText }
        isTranscribing = false
        // Finish any in-flight background segment transcriptions, then transcribe the
        // final tail (the WHOLE recording if no cut ever fired) and assemble in order.
        for task in segmentTasks { await task.value }
        tailTranscribeThrew = false
        // Timed on purpose. Measured 19.11.2026: ~65–100 ms for 3 s of audio, and a
        // model left idle is at most a few dozen ms slower — an A/B with a warm-up
        // run in the pause after speech gained 20 ms, so there is none.
        let transcribeBegan = Date()
        let tail = await rawTranscribe(rawSamples, rate: rate)
        let seconds = rate > 0 ? Double(rawSamples.count) / rate : 0
        logger.info("Transcribed \(seconds, format: .fixed(precision: 1), privacy: .public) s of audio in \(Date().timeIntervalSince(transcribeBegan) * 1000, format: .fixed(precision: 0), privacy: .public) ms")
        var ordered: [String] = []
        for i in 0..<segmentIndex { ordered.append(segmentResults[i] ?? "") }
        finalize(Self.assembleSegments(ordered, tail: tail))
        // Name the reason instead of returning a bare "". An empty string used to
        // be the single answer to four very different failures.
        // After a segment cut `rawSamples` is only the tail. A long recording must
        // not be called "too short" (or "no samples") because its tail is.
        lastFailure = RecordingFailure.classify(
            sampleCount: segmentIndex > 0 ? Int.max : rawSamples.count,
            minimumSamples: Self.minimumSamples(atRate: rate),
            asrThrew: tailTranscribeThrew,
            transcript: currentText)
        if let lastFailure {
            logger.error("Recording produced no text — stage \(lastFailure.rawValue, privacy: .public)")
        }
        return currentText
    }

    // MARK: - Batch transcription (live buffer + files share one engine)

    private func batchEngine() async throws -> AsrManager {
        if let batchAsr { return batchAsr }
        if asrModels == nil { try await loadModel() }   // still loading (or never started): wait for it
        if let batchAsr { return batchAsr }
        guard let asrModels else {
            throw NSError(domain: "Steneo", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Speech model isn't loaded yet."])
        }
        let manager = AsrManager()
        try await manager.initialize(models: asrModels.value)
        batchAsr = manager
        return manager
    }

    /// Transcribe one chunk of raw audio (a segment, or the whole recording) with the
    /// batch engine. ONE clean conversion (input rate → 16 kHz, like the file path) +
    /// de-stutter. Returns "" on too-short/failure. The word-replacement/voice-command
    /// pass runs ONCE on the assembled text (`finalize`), not per chunk.
    private func rawTranscribe(_ rawSamples: [Float], rate: Double) async -> String {
        let resampled = (rate <= 0 || rate == 16000) ? rawSamples : AudioResampler.resample(rawSamples, from: rate)
        guard let samples = Self.paddedForModel(resampled) else { return "" }   // too short to hold a word
        do {
            let asr = try await batchEngine()
            let result = try await asr.transcribe(samples, source: .microphone)
            let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return "" }
            return Self.removeTrailingStutter(trimmed)
        } catch {
            logger.error("Transcription failed: \(error.localizedDescription)")
            tailTranscribeThrew = true
            return ""
        }
    }

    /// The model refuses anything under one second of 16 kHz audio ("Invalid
    /// audio data provided"). A spoken "Ja, passt." is shorter than that, and
    /// until 1.6 it was reported as a failed transcription. So short audio is
    /// padded with silence up to the second the model needs — from 0.3 s on,
    /// below which there is no room for a word and nothing is attempted.
    nonisolated static let modelMinimumSamples = 16_000
    nonisolated static let shortestSpeechSamples = 4_800
    nonisolated static func paddedForModel(_ samples: [Float]) -> [Float]? {
        guard samples.count >= shortestSpeechSamples else { return nil }
        guard samples.count < modelMinimumSamples else { return samples }
        return samples + [Float](repeating: 0, count: modelMinimumSamples - samples.count)
    }

    /// A recording shorter than this that produced no text is simply "too
    /// short" — almost always a shortcut pressed twice — not a failure worth
    /// keeping audio for. One second, at any input rate.
    nonisolated static func minimumSamples(atRate rate: Double) -> Int {
        rate > 0 ? Int(rate.rounded(.up)) : modelMinimumSamples
    }

    /// Apply the shared text pipeline (word replacements + voice commands) ONCE over
    /// the full assembled transcript, detect language, and set `currentText`.
    private func finalize(_ combined: String) {
        let trimmed = combined.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { currentText = ""; return }
        var corrected = postProcess(trimmed)
        corrected = Self.removeTrailingStutter(corrected)   // catch any replacement-induced trailing repeat
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(corrected)
        if let lang = recognizer.dominantLanguage?.rawValue {
            detectedLanguage = String(lang.prefix(2))
        }
        currentText = corrected
        logger.info("final transcript (\(corrected.count) chars): \(corrected.prefix(120))…")
    }

    /// Join finished segments (in cut order) + the final tail, dropping empties.
    /// Pure → unit-tested.
    static func assembleSegments(_ segments: [String], tail: String) -> String {
        (segments + [tail]).filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: - File transcription (batch)

    /// Transcribe an audio file (any length) with the batch ASR — full context,
    /// internal chunking. Applies word corrections, but NOT the dictation
    /// voice-commands (which don't fit arbitrary recordings).
    func transcribeFile(url: URL) async throws -> String {
        let asr = try await batchEngine()
        let result = try await asr.transcribe(url, source: .system)
        let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return textReplacement.applyReplacements(to: trimmed)
    }

    // MARK: - Audio Input (single ordered consumer)

    /// Feed ONE block of 16 kHz audio to the VAD, in capture order. Called only by
    /// the lone consumer in `startAudioPipeline()`, so calls never overlap or reorder.
    private func feed(_ samples: [Float]) async {
        guard isCapturing, !samples.isEmpty else { return }
        // This is the block-by-block converted audio — used ONLY to drive VAD
        // auto-stop (which tolerates resampler artifacts). The ASR uses the
        // recording itself, converted in ONE pass (AudioCaptureService.takeRecording).
        await processVadSamples(samples)
    }

    // MARK: - VAD Processing

    private func processVadSamples(_ samples: [Float]) async {
        guard let vadManager else { return }

        vadBuffer.append(contentsOf: samples)

        let chunkSize = VadManager.chunkSize
        while vadBuffer.count >= chunkSize {
            let chunk = Array(vadBuffer[0..<chunkSize])
            vadBuffer.removeFirst(chunkSize)

            do {
                let vadConfig = VadSegmentationConfig(
                    minSpeechDuration: 0.25,         // Default 0.15 — filter click noises
                    minSilenceDuration: 0.75,        // Used only for auto-stop + paragraph-break timing
                    speechPadding: 0.15,             // Default 0.1 — prevent clipped word edges
                    silenceThresholdForSplit: 0.25,  // Default 0.3 — more sensitive to true silence
                    negativeThresholdOffset: 0.12    // Default 0.15 — faster speech-end detection
                )
                let result = try await vadManager.processStreamingChunk(
                    chunk,
                    state: vadStreamState,
                    config: vadConfig
                )
                vadStreamState = result.state

                if result.state.triggered {
                    lastSpeechTime = Date()
                    cutPending = false
                }

                // Background-transcribe a finished segment at a clear mid-recording pause.
                maybeCutSegment()

                // Auto-stop after prolonged silence
                let timeout = SettingsStore.shared.autoStopTimeout
                if timeout != .off,
                   let lastSpeech = lastSpeechTime,
                   Date().timeIntervalSince(lastSpeech) >= TimeInterval(timeout.rawValue) {
                    onSilenceTimeout?()
                    return
                }
            } catch {
                // VAD error — continue
            }
        }
    }

    /// Fire a segment cut when we're in a clear pause and the current segment is long
    /// enough to be worth transcribing on its own (only long recordings trigger this).
    private func maybeCutSegment() {
        guard segmentProvider != nil, !cutPending, !vadStreamState.triggered,
              let lastSpeech = lastSpeechTime, let lastCut = lastCutTime else { return }
        let now = Date()
        guard now.timeIntervalSince(lastSpeech) >= Self.cutSilenceSeconds,
              now.timeIntervalSince(lastCut) >= Self.minSegmentSeconds else { return }
        cutPending = true
        cutSegment()
    }

    /// Snapshot the raw audio since the last cut and transcribe it in the background;
    /// the result is reassembled in order at stop.
    private func cutSegment() {
        guard let provider = segmentProvider else { return }
        let segment = provider()
        lastCutTime = Date()
        let index = segmentIndex
        segmentIndex += 1
        let task = Task { @MainActor [weak self] in
            let text = await self?.rawTranscribe(segment.samples, rate: segment.rate) ?? ""
            self?.segmentResults[index] = text
            logger.info("segment \(index) transcribed (\(text.count) chars)")
        }
        segmentTasks.append(task)
    }

    // MARK: - Text pipeline

    /// Replacements + (if enabled) voice commands + emoji — applied to the final
    /// batch transcript.
    private func postProcess(_ text: String) -> String {
        voiceCommands.process(textReplacement.applyReplacements(to: text))
    }

    /// Encoder-window geometry (kept for its unit tests + as documentation of the
    /// Parakeet 15 s / 240,000-sample input cap). Unused by the v2 batch path — the
    /// batch engine does its own internal context-preserving chunking — but retained
    /// so the invariant stays documented and tested for any future streaming work.
    struct StreamingWindow: Equatable {
        let chunkSeconds: Double
        let leftContextSeconds: Double
        let rightContextSeconds: Double
        let capSeconds: Double

        /// The full window assembled and fed to the encoder per step.
        var windowSeconds: Double { leftContextSeconds + chunkSeconds + rightContextSeconds }

        /// Clamp the desired knobs so `windowSeconds <= cap` always holds.
        static func clamped(desiredChunk: Double = 11.0,
                            desiredLeftContext: Double = 2.0,
                            rightContext: Double = 1.5,
                            cap: Double = 14.5) -> StreamingWindow {
            let chunk = min(desiredChunk, max(0, cap - rightContext))
            let maxLeft = max(0, cap - chunk - rightContext)
            let left = min(desiredLeftContext, maxLeft)
            return StreamingWindow(chunkSeconds: chunk,
                                   leftContextSeconds: left,
                                   rightContextSeconds: rightContext,
                                   capSeconds: cap)
        }
    }

    /// Detect and remove ASR stutter where the last 1-2 words are repeated.
    /// e.g. "hello world world" → "hello world". Pure + `static` so it's unit-tested.
    static func removeTrailingStutter(_ text: String) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)

        func normalize(_ word: String) -> String {
            word.lowercased().filter { !$0.isPunctuation }
        }

        // Check 2-word stutter first: "... w1 w2 w1 w2"
        if words.count >= 4 {
            let tailOriginal = Array(words.suffix(2))
            let tail = tailOriginal.map { normalize($0) }
            let before = words.dropLast(2).suffix(2).map { normalize($0) }
            // Keep capitalized repeats — likely a real proper noun ("New York, New York").
            let looksLikeProperNoun = tailOriginal.allSatisfy { $0.first?.isUppercase == true }
            if tail == before, tail.allSatisfy({ !$0.isEmpty }), !looksLikeProperNoun {
                logger.info("Stutter removed (2-word): '\(words.suffix(2).joined(separator: " "))'")
                return words.dropLast(2).joined(separator: " ")
            }
        }

        // Check 1-word stutter: "... w w" (min 3 chars to avoid false positives like "I I")
        if words.count >= 2 {
            let last = normalize(words[words.count - 1])
            let prev = normalize(words[words.count - 2])
            if last == prev && last.count >= 3 {
                logger.info("Stutter removed (1-word): '\(words.last!)'")
                return words.dropLast().joined(separator: " ")
            }
        }

        return text
    }
}
