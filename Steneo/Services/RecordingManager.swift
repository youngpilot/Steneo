import AppKit
import AVFoundation
import Foundation
import Observation
import os
import UniformTypeIdentifiers

private let logger = Logger(subsystem: "com.youngpilot.Steneo", category: "RecordingManager")

@Observable
@MainActor
final class RecordingManager {
    static let shared = RecordingManager()

    private let audioCaptureService = AudioCaptureService()
    private let transcriptionService = TranscriptionService()
    private let outputService = OutputService()
    private let hotkeyService = HotkeyService()
    private let systemAudio = SystemAudioService.shared
    let historyService = HistoryService.shared
    let recoveryStore = RecoveryStore.shared

    private(set) var isRecording = false
    private(set) var isStarting = false   // press registered, microphone opening (shows orange — arming)
    private(set) var isPostProcessing = false   // post-record on-device LLM pass (AI cleanup / formatting) running
    /// A self-contained test recording's transcript (onboarding "Try it") — shown in
    /// the onboarding window only, never pasted or saved.
    private(set) var testTranscript: String?
    private var isTestMode = false
    private(set) var isModelLoading = false
    private(set) var modelLoadError: String?
    private(set) var inputLevel: Float = 0.0   // smoothed mic level [0,1] for the meter
    private(set) var needsAccessibility = false
    private(set) var needsMicrophone = false
    private(set) var isTranscribingFile = false
    private(set) var fileTranscriptionName: String?
    /// A file transcription finished and is waiting to be seen — drives the green
    /// menubar badge. Cleared when the popover opens (or a new activity starts).
    private(set) var fileTranscriptionDone = false
    /// A recording produced no text and its audio was kept — drives the menubar
    /// badge, so the failure is visible instead of sitting in a closed popover.
    private(set) var hasRecoveryWaiting = false
    private(set) var statusMessage: StatusMessage?
    private var statusClearTask: Task<Void, Never>?
    private var recordingStartTime: Date?
    private var startTask: Task<Void, Never>?
    private var audioContinuation: AsyncStream<[Float]>.Continuation?
    /// Set when stop is pressed during the brief "starting" window. A half-started
    /// ASR can't be torn down cleanly mid-flight, so we let it come up and then
    /// stop it cleanly (honored in beginCapture).
    private var stopAfterStart = false
    /// When the shortcut was pressed, for timing the mute against the start sound.
    private var pressedAt = Date.distantPast
    /// How long the start sound needs to be heard. Its file is 0.56 s long, but
    /// measured, the tick is over after 40 ms and the rest is silence; the
    /// remainder here is the output's own delay. A microphone hears from about
    /// 230 ms, so the sound is gone before anything is recorded.
    private static let startSoundAudible: TimeInterval = 0.12
    /// Ends a recording whose microphone has gone deaf. Red must mean "your audio
    /// is being captured"; without this it could mean "the engine died and nobody
    /// noticed".
    private var watchdogTask: Task<Void, Never>?
    /// Set when the watchdog is the reason a recording ended, so the report names
    /// what actually happened instead of "no speech found".
    private var pendingFailureOverride: RecordingFailure?

    /// The microphone the last recording used, or the one the next would use.
    private(set) var microphoneName: String?
    /// Standing notice while recordings run on a fallback microphone. Cleared by
    /// the first start that needs no fallback — a transient status line would be
    /// gone long before anyone opens the menu after dictating.
    private(set) var microphoneNotice: String?

    /// What ended a recording. Logged with every stop: on 19.11.2026 two
    /// recordings ended within a second and nothing recorded by what.
    enum StopReason: String {
        case toggle = "shortcut or button"
        case released = "hold key released"
        case cancelledWhileStarting = "pressed again while starting"
        case silence = "silence timeout"
        case watchdog = "microphone went silent"
    }

    /// The output profile resolved when this recording STARTED. Resolved once, on
    /// purpose: the user can switch apps while speaking, and the text belongs to
    /// the app they were in when they pressed the shortcut.
    private(set) var activeProfile: OutputProfile = SettingsStore.shared.standardProfile

    /// The app a recording would go to right now — drives the per-app profile UI.
    var targetBundleID: String? { outputService.targetBundleID }
    func refreshTargetApp() { outputService.refreshTargetApp() }
    var targetAppName: String? { outputService.targetAppName }

    var currentText: String { transcriptionService.currentText }
    var isModelLoaded: Bool { transcriptionService.isModelLoaded }
    var modelLoadingStep: String { transcriptionService.modelLoadingStep }
    var detectedLanguage: String { transcriptionService.detectedLanguage }
    var lastConfidence: Float { transcriptionService.lastConfidence }
    var minTokenConfidence: Float { transcriptionService.minTokenConfidence }
    var avgTokenConfidence: Float { transcriptionService.avgTokenConfidence }
    var isVocabModelLoading: Bool { transcriptionService.isVocabModelLoading }
    var vocabModelLoadFailed: Bool { transcriptionService.vocabModelLoadFailed }

    /// Preload the CTC vocabulary model when the user enables Model Boosting,
    /// so it's ready before the next recording.
    func prepareVocabularyBoosting() {
        Task { await transcriptionService.ensureVocabModelsLoaded() }
    }

    private init() {
        hotkeyService.onToggle = { [weak self] in
            self?.toggle()
        }
        // Push-to-talk (Hold activation mode): press starts, release stops.
        hotkeyService.onPress = { [weak self] in
            self?.startRecording()
        }
        hotkeyService.onRelease = { [weak self] in
            guard let self else { return }
            if self.isRecording {
                Task { await self.stopRecording(reason: .released) }
            } else if self.isStarting {
                self.stopAfterStart = true   // released during start-up → honored once live
            }
        }

        audioCaptureService.onStarted = { [weak self] info in
            Task { @MainActor in self?.captureStarted(info) }
        }

        // Wire silence timeout → auto-stop
        transcriptionService.onSilenceTimeout = { [weak self] in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                await self.stopRecording(reason: .silence)
                SoundFeedback.playStop()
            }
        }
    }

    func setup() async {
        logger.info("Setup starting — registering hotkey")
        // The unit-test host is this whole app, running next to the installed
        // one on the developer's Mac. It must never answer the shortcut.
        if !AppEnvironment.isRunningTests { hotkeyService.start() }
        outputService.startTrackingAppActivations()
        needsAccessibility = !AXIsProcessTrusted()
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        needsMicrophone = (micStatus == .denied || micStatus == .restricted)
        isModelLoading = true
        modelLoadError = nil
        do {
            logger.info("Loading models...")
            try await transcriptionService.loadModel()
            logger.info("Models loaded successfully")
        } catch {
            modelLoadError = error.localizedDescription
            logger.error("Failed to load model: \(error.localizedDescription)")
        }
        isModelLoading = false

        // Decode the feedback sounds up front so the first start/stop chirp has
        // no load latency.
        SoundFeedback.preload()

        // No audio warm-up. Touching the input node opens a device, and an open
        // input device drags a Bluetooth headset into the mono call profile —
        // which made simply having Steneo running degrade the user's AirPods.
        // The device is opened when a recording starts and given back when it ends.

        // Daily update check (no-op in Manual mode; connectivity-driven, at most
        // one GET per 24h). Touching the singleton also starts its net monitor.
        UpdateService.shared.maybeAutoCheck()
    }

    func toggle() {
        if isRecording {
            Task { await stopRecording(reason: .toggle) }
        } else if isStarting {
            // Stop pressed during the start window — honor it the instant
            // the recording is actually live (beginCapture checks this flag).
            stopAfterStart = true
        } else {
            startRecording()
        }
    }

    /// Start a one-off TEST recording for onboarding: records, transcribes, and
    /// publishes `testTranscript` instead of pasting/saving. Triggers the microphone
    /// permission prompt if it hasn't been asked yet.
    func startTestRecording() {
        guard !isRecording, !isStarting else { return }
        isTestMode = true
        testTranscript = nil
        startRecording()
    }

    func startRecording() {
        guard !isRecording, !isStarting else { return }
        // A model that is still loading does NOT block recording: capture needs
        // no model, and the transcription at stop waits for it. Only a load that
        // failed outright has nothing to wait for.
        if let modelLoadError, !transcriptionService.isModelLoaded {
            showStatus("Speech model couldn't be loaded: \(modelLoadError)", isError: true)
            return
        }

        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if micStatus == .denied || micStatus == .restricted {
            needsMicrophone = true
            return
        }

        // Instant acknowledgement the moment the shortcut registers — the start
        // sound — while the microphone is being opened.
        pressedAt = Date()
        stopAfterStart = false
        pendingFailureOverride = nil
        fileTranscriptionDone = false   // a new recording supersedes a stale "ready" badge
        isStarting = true
        needsMicrophone = false
        SoundFeedback.playStart()

        // Resolve the output profile for the app we're dictating into, before the
        // prewarm — so we warm the model this recording will actually use.
        let profile = SettingsStore.shared.profile(forBundleID: outputService.targetBundleID)
        activeProfile = profile
        let targetID = outputService.targetBundleID ?? "—"
        logger.info("Target app \(targetID, privacy: .public) → profile \(profile.name, privacy: .public)")

        // In AI mode, warm the on-device model now so cleanup is fast at stop.
        if profile.cleanupMode == .ai { TextCleanupService.shared.prewarm() }
        if profile.formatMode != .none { FormattingService.shared.prewarm(mode: profile.formatMode) }

        outputService.rememberSourceApp()
        outputService.activeInsertionMode = profile.insertionMode
        let preferredMicrophone = SettingsStore.shared.preferredInputUID
        audioCaptureService.preferredDeviceUID = preferredMicrophone.isEmpty ? nil : preferredMicrophone
        audioCaptureService.startTimes = SettingsStore.shared.inputStartTimes
        // Let the transcription service pull finished segments' raw audio for
        // background transcription during long recordings.
        transcriptionService.segmentProvider = { [audioCaptureService] in audioCaptureService.takeSegment() }
        transcriptionService.beginCapturing()   // hold audio until ASR is ready
        startTask = Task { @MainActor in await transcriptionService.startTranscription() }

        // beginCapture opens the microphone off the main thread and returns
        // immediately; we flip to red only once audio is actually being kept.
        beginCapture()
    }

    private func beginCapture() {
        guard isStarting, !isRecording else { return }

        // Single ordered audio path: the capture yields into one stream that one
        // serial consumer drains in capture order (no per-buffer Tasks, no race).
        let continuation = transcriptionService.startAudioPipeline()
        audioContinuation = continuation
        // We enter the recording state — and turn the icon red — only once audio
        // is actually being kept, so "red == recording" with no lost first words.
        audioCaptureService.startCapture(
            onBuffer: { samples in continuation.yield(samples) },
            onLevel: { [weak self] level in
                Task { @MainActor in
                    // Ignore callbacks enqueued before stop so a late one can't
                    // overwrite the inputLevel reset.
                    guard let self, self.isRecording else { return }
                    // Asymmetric ballistics: fast attack, slow release.
                    let alpha: Float = level > self.inputLevel ? 0.6 : 0.2
                    self.inputLevel += alpha * (level - self.inputLevel)
                }
            },
            completion: { [weak self] error in
                Task { @MainActor in self?.captureCompleted(error) }
            }
        )
    }

    /// Called on the main actor once the capture reports a result.
    private func captureCompleted(_ error: AudioCaptureError?) {
        if let error { captureFailed(error); return }
        // Torn down during start-up (stop pressed, etc.) — stop the capture that
        // just went live instead of entering the recording state.
        guard isStarting, !isRecording else {
            audioCaptureService.stopCapture()
            audioContinuation?.finish()
            audioContinuation = nil
            return
        }

        isStarting = false
        isRecording = true   // RED == recording — only now that the mic is live
        recordingStartTime = Date()
        needsAccessibility = !AXIsProcessTrusted()
        startDeafnessWatchdog()

        // Stop was pressed during startup — bring it down cleanly now (before
        // muting media, so there's no audible blip).
        if stopAfterStart {
            stopAfterStart = false
            Task { await stopRecording(reason: .cancelledWhileStarting) }
            return
        }

        if SettingsStore.shared.silenceMediaWhileRecording {
            muteOnceTheStartSoundIsHeard()
        }
        if SettingsStore.shared.pauseMediaApps {
            systemAudio.pauseMediaApps()
        }
        // Prefix/suffix are pasted together with the full text when recording stops.
    }

    /// Muting the output also mutes Steneo's own start sound. Since 1.7 the
    /// recording is live about 65 ms after the press, where it used to take
    /// half a second — muting right then would swallow the sound that says
    /// "recording". So the mute waits the moment that sound needs.
    private func muteOnceTheStartSoundIsHeard() {
        let remaining = Self.startSoundAudible - Date().timeIntervalSince(pressedAt)
        guard remaining > 0.01 else { systemAudio.muteOutput(); return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard let self, self.isRecording, SettingsStore.shared.silenceMediaWhileRecording else { return }
            self.systemAudio.muteOutput()
        }
    }

    private func captureFailed(_ error: AudioCaptureError) {
        isStarting = false
        stopAfterStart = false
        audioCaptureService.stopCapture()
        audioContinuation?.finish()
        audioContinuation = nil
        if error == .microphoneDenied {
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            needsMicrophone = (status == .denied || status == .restricted)
        } else if error == .noInputDevice {
            showStatus("No microphone found — check your input device", isError: true)
        } else {
            // Never fail silently again: without this the mic just blinked and
            // went back to white, which reads as "the shortcut is broken".
            showStatus("Microphone unavailable — check your input device", isError: true)
            logger.error("Empty recording (\(RecordingFailure.engineStart.rawValue, privacy: .public)) — nothing to keep")
        }
        logger.error("Capture failed: \(error.localizedDescription)")
    }

    func stopRecording(reason: StopReason = .toggle) async {
        guard isRecording else { return }
        let ran = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        logger.info("Recording stopped after \(ran, format: .fixed(precision: 1), privacy: .public) s — \(reason.rawValue, privacy: .public)")
        watchdogTask?.cancel()
        watchdogTask = nil
        // "Automatic" ranks microphones by this number. Known only once a
        // recording has run for most of a second.
        if let heard = audioCaptureService.leadHearsAfter {
            SettingsStore.shared.inputStartTimes[heard.uid] = heard.milliseconds
        }
        audioCaptureService.stopCapture()
        isRecording = false
        inputLevel = 0.0
        // Always restore — each is a no-op if it wasn't applied (also handles a
        // setting being toggled off mid-recording).
        systemAudio.restoreOutput()
        systemAudio.resumeMediaApps()
        SoundFeedback.playStop()

        // Ensure the ASR finished starting before we feed the tail / finish.
        await startTask?.value
        startTask = nil

        // Close the ordered audio pipeline and wait for the lone consumer to
        // feed every remaining buffer (in capture order) into the ASR before we
        // finish — deterministic, no fixed-timeout drain.
        audioContinuation?.finish()
        audioContinuation = nil
        await transcriptionService.awaitAudioConsumer()

        // ONE clean conversion of the whole raw recording (like the file path) —
        // no per-buffer resampler warm-up that garbled short clips.
        let recorded = audioCaptureService.takeRecording()
        if !transcriptionService.isModelLoaded { showStatus("Loading speech model…") }
        var finalText = await transcriptionService.stopTranscription(rawSamples: recorded.samples, rate: recorded.rate)

        // Onboarding test recording: surface the raw transcript in the window only —
        // never paste, clean up, format, or save to history.
        if isTestMode {
            isTestMode = false
            testTranscript = finalText.isEmpty
                ? "Didn't catch that — try again, a little closer to the mic."
                : finalText
            return
        }

        // Capture duration BEFORE optional cleanup so WPM reflects speaking time,
        // not the cleanup pass.
        let duration = recordingStartTime.map { Date().timeIntervalSince($0) }

        // Optional on-device post-processing: cleanup (lexical) then formatting
        // (structure). Both run locally, never leave the Mac, and fall back to the
        // input on any failure. The menubar mic pulses warm-yellow while an LLM pass
        // runs (AI cleanup or any format mode).
        let cleanupMode = activeProfile.cleanupMode
        let formatMode = activeProfile.formatMode
        let willPostProcess = cleanupMode == .ai || formatMode != .none
        if willPostProcess { isPostProcessing = true }
        defer { if willPostProcess { isPostProcessing = false } }

        if cleanupMode != .off, !finalText.isEmpty {
            if cleanupMode == .ai { showStatus("Cleaning up…") }
            finalText = await TextCleanupService.shared.cleanup(finalText, mode: cleanupMode)
        }
        if formatMode != .none, !finalText.isEmpty {
            showStatus("Formatting…")
            finalText = await FormattingService.shared.format(finalText, mode: formatMode)
        }

        // A watchdog stop that still produced text is not a failure to report.
        if !finalText.isEmpty { pendingFailureOverride = nil }

        // Paste the COMPLETE transcript (with prefix/suffix) once — reliable,
        // with no chunk-boundary artifacts from incremental pasting.
        var output = finalText
        if !output.isEmpty {
            let prefix = activeProfile.prefixText
            let suffix = activeProfile.suffixText
            if !prefix.isEmpty { output = prefix + " " + output }
            if !suffix.isEmpty { output = output + " " + suffix }

            outputService.insertText(output)
            historyService.addEntry(output, duration: duration)
        } else {
            let reason = pendingFailureOverride ?? transcriptionService.lastFailure ?? .emptyResult
            pendingFailureOverride = nil
            await noteEmptyRecording(reason: reason, samples: recorded.samples, rate: recorded.rate)
        }

        // Wait for all pending pastes to complete before ending session.
        // doPaste uses async DispatchQueue drains (scheduleDrain +20ms, activate +60ms)
        // so isPasting stays true until the full chain completes.
        for i in 0..<30 {
            if !outputService.hasPendingOutput { break }
            outputService.flushPendingText()
            try? await Task.sleep(for: .milliseconds(10))
            if i == 29 {
                logger.warning("Paste drain timeout — ending session anyway")
            }
        }

        // If Accessibility is off we couldn't type anywhere — leave the transcript
        // on the clipboard so the user can paste it, and keep it there (don't restore).
        if !output.isEmpty, !AXIsProcessTrusted() {
            outputService.suppressClipboardRestore = true
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(output, forType: .string)
        }

        outputService.endSession()
    }

    /// Watch the audio actually arriving, and end the recording if it stops.
    ///
    /// A microphone can die under a live recording — a device pulled, a hub that
    /// loses power. Nothing else notices: `isRecording` stays true and the icon
    /// stays red over a microphone that hears nothing.
    private func startDeafnessWatchdog() {
        watchdogTask?.cancel()
        let startedAt = Date()
        watchdogTask = Task { @MainActor [weak self] in
            let watchdog = DeafMicrophoneWatchdog()
            var reportedFirstBuffer = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, let self, self.isRecording else { return }
                let gap = self.audioCaptureService.secondsSinceLastBuffer
                // Log the first observed gap once per recording. The watchdog rests
                // entirely on this number moving, and the unit test that proves it
                // needs a microphone the test runner does not always have — so the
                // shipping build says it out loud instead.
                if !reportedFirstBuffer, let gap {
                    reportedFirstBuffer = true
                    logger.info("Audio is arriving — first heartbeat gap \(gap, format: .fixed(precision: 3), privacy: .public)s")
                }
                let verdict = watchdog.verdict(
                    secondsSinceLastBuffer: gap,
                    secondsSinceStart: Date().timeIntervalSince(startedAt))
                guard verdict == .deaf else { continue }
                logger.error("No audio for \(watchdog.silenceLimit, privacy: .public)s while recording — the microphone went deaf; stopping")
                self.pendingFailureOverride = .microphoneWentSilent
                // Clear first: stopRecording cancels this task, and being
                // cancelled mid-stop would skip its paste drain.
                self.watchdogTask = nil
                await self.stopRecording(reason: .watchdog)
                return
            }
        }
    }

    /// A recording that produced nothing must never just disappear: keep the
    /// audio, name the reason, and say so where it can be seen.
    private func noteEmptyRecording(reason: RecordingFailure, samples: [Float], rate: Double) async {
        let kept = await recoveryStore.save(samples: samples, rate: rate, reason: reason)
        logger.error("Empty recording (\(reason.rawValue, privacy: .public)) — \(kept == nil ? "nothing kept" : "audio kept", privacy: .public)")
        showStatus(reason.message, isError: reason != .tooShort)
        if kept != nil { hasRecoveryWaiting = true }
    }

    /// Transcribe a kept recording again — same path as any dropped audio file,
    /// so there is no second transcription route to keep working.
    func retryRecovered(_ recording: RecoveredRecording) {
        hasRecoveryWaiting = false
        transcribeFile(recording.url)
    }

    // MARK: - File transcription

    /// Transcribe an audio file (drag-drop / picker / clipboard) with the batch
    /// engine. A file has no source app to type into, so the result is copied to
    /// the clipboard and saved to History (no auto-typing). Disabled while a live
    /// recording is in flight.
    func transcribeFile(_ url: URL) {
        guard !isRecording, !isStarting, !isTranscribingFile,
              transcriptionService.isModelLoaded else { return }
        statusMessage = nil
        fileTranscriptionDone = false
        isTranscribingFile = true
        fileTranscriptionName = url.lastPathComponent
        Task { @MainActor in
            defer { isTranscribingFile = false; fileTranscriptionName = nil }
            do {
                let text = try await transcriptionService.transcribeFile(url: url)
                guard !text.isEmpty else {
                    showStatus("No speech found in that file.", isError: true)
                    return
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                historyService.addEntry(text)
                SoundFeedback.playStop()
                showStatus("Saved to history · copied")
                fileTranscriptionDone = true   // green menubar badge until the popover is opened
            } catch {
                showStatus(error.localizedDescription, isError: true)
                logger.error("File transcription failed: \(error.localizedDescription)")
            }
        }
    }

    /// Transcribe an audio file currently on the clipboard (a copied file), if any.
    func transcribeAudioFromClipboard() {
        guard let url = Self.audioFileURLOnPasteboard() else {
            showStatus("No audio file on the clipboard.", isError: true)
            return
        }
        transcribeFile(url)
    }

    /// Called when the popover opens — clears the green "transcription ready"
    /// menubar badge (the user has come to look).
    func markWindowOpened() {
        fileTranscriptionDone = false
        hasRecoveryWaiting = false
        refreshMicrophone()
    }

    /// Which microphone a recording would use right now. Property reads only —
    /// this opens no device, so it is safe while idle.
    func refreshMicrophone() {
        guard !isRecording, !isStarting else { return }
        let settings = SettingsStore.shared
        let preferred = settings.preferredInputUID
        microphoneName = AudioDeviceResolver.current(preferredUID: preferred.isEmpty ? nil : preferred,
                                                     startTimes: settings.inputStartTimes)?.device.name
    }

    /// A recording went live: remember the microphone, and say so if it is not
    /// the one the user would expect.
    private func captureStarted(_ info: CaptureStartInfo) {
        microphoneName = info.device.name
        let settings = SettingsStore.shared
        let notice = AudioDeviceResolver.notice(
            used: info.device, source: info.source, failedNames: info.failedNames,
            preferredName: settings.preferredInputUID.isEmpty ? nil : settings.preferredInputName)
        if let notice, notice != microphoneNotice { showStatus(notice, isError: true) }
        microphoneNotice = notice
    }

    /// Show a transient one-line status (auto-dismissed). Errors linger a little
    /// longer so they can be read. One line, no queue — replaces any prior message.
    func showStatus(_ text: String, isError: Bool = false) {
        statusMessage = StatusMessage(text: text, isError: isError)
        statusClearTask?.cancel()
        statusClearTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(isError ? 4.0 : 2.5))
            guard !Task.isCancelled else { return }
            statusMessage = nil
        }
    }

    /// The first audio file URL on the general pasteboard, if any.
    static func audioFileURLOnPasteboard() -> URL? {
        let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        return urls.first { url in
            (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .audio) ?? false
        }
    }

}

/// A transient, auto-dismissed status line shown in the popover.
struct StatusMessage: Equatable {
    let text: String
    let isError: Bool
}

// MARK: - Sound Feedback

@MainActor
enum SoundFeedback {
    // Cache + reuse the NSSound instances so the first chirp has no decode
    // latency and a press never waits on a fresh named-sound lookup.
    private static let startSound = NSSound(named: "Tink")
    private static let stopSound = NSSound(named: "Bottle")

    static func playStart() { restart(startSound) }
    static func playStop() { restart(stopSound) }

    /// Force the sounds to decode up front (call once at launch).
    static func preload() { _ = startSound; _ = stopSound }

    private static func restart(_ sound: NSSound?) {
        guard !AppEnvironment.isRunningTests, let sound else { return }
        if sound.isPlaying { sound.stop() }   // allow rapid re-trigger
        sound.play()
    }
}
