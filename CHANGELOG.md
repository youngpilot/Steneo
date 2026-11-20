# Changelog

All notable changes to Steneo. Dates are release dates; versions follow the app's `MARKETING_VERSION`.

## 1.7

### Added
- **Automatic now means the microphone that hears you soonest.** Until now *Automatic* followed the system's input, however slow. Measured here: a display microphone hears nothing for 450 ms after the shortcut, a USB interface for 540 ms, the Mac's own for about 220 ms. Whatever you said in that time was missing. *Automatic* now records with the fastest one, which on a MacBook is its own.
- **The time next to each microphone is now the time until it hears.** It used to count the first data a device delivered. The Mac's own microphone delivers after 60 ms and then hands over silence for another 170 while it starts up, so the old number flattered it. Steneo now looks at what arrives, not at whether something arrives.
- **A microphone you pick yourself no longer costs you the start.** If you choose a slower one, the Mac's own microphone records first and yours takes over the moment it delivers. The two are joined on their time stamps, so nothing is said twice and nothing is missing at the switch. On a Mac without a built-in microphone nothing changes.

### Changed
- **The menu is easier to read.** Its content sat on glass, and over a busy desktop the text was hard to make out. It now sits on a nearly opaque background, and the cards are a tint instead of a see-through material.
- **Settings, tidied.** Every explanation that was a paragraph is now one short line, with the rest in the tooltip. Settings that belong together are grouped. "Microphone" is no longer cut off, and the closed picker shows the name alone.
- **The microphone is read directly from the device.** The system's audio engine in between is gone, and with it the machinery that existed to survive its quirks. Opening a device is quicker by about 75 ms and has not failed to deliver once in testing, where the engine left about one start in five without audio.
- **Fallback order.** Behind a microphone you picked, the next one tried is the fastest, so the Mac's own. If yours never delivers, the recording simply stays there, where it has been running since the first moment.
- **Muting other audio waits for the start sound**, which takes a tenth of a second. The sound is over before any microphone hears, so it is never on a recording.

### Under the hood
- Releases now check the capture code against real microphones: a silent five-second run that records the room, plays nothing and switches nothing. The unit tests that need a microphone cannot run, because their host has no microphone access.
- Releases check the installed app by itself: it records a second of the room and transcribes a sentence that was written to a file, never played. No one has to dictate anything for a release any more.

### Known limits
- No microphone hears from the instant of the shortcut. With the Mac's own it is roughly a quarter of a second, where it used to be half a second and more.
- Stopping a recording within its first half second and starting the next one in the same instant makes that next one wait for the first microphone to finish starting.
- If a microphone dies in the middle of a recording, the recording ends after two seconds and keeps what it has. It does not move to another microphone.

## 1.6

### Added
- **Choose your microphone.** Settings → Recording → Microphone: *Automatic* follows the system input, or pick a specific device. The choice is stored by the device's permanent identifier, so it survives unplugging, and a device that is not connected right now stays selected.
- **A microphone that won't start no longer costs you the recording.** Steneo tries your chosen device, then the system input, then the Mac's own microphone, until one actually starts and delivers audio. Until now a device that was present but refused to start ended the recording before it began, with a working built-in microphone sitting unused.
- **Steneo tells you when it switched.** A notice in the menu names the microphone in use and the one that did not respond. It stays until a recording runs on your usual device again.

### Fixed
- **A press while the speech model was still loading was refused.** Capturing audio never needed the model, only the transcription at the end does. Steneo now records right away and waits for the model when you stop.
- **Holding F5 a moment too long stopped the recording right away.** The keyboard's auto-repeat counted as a second press, and it arrives faster than a recording takes to start.
- **Very short recordings were reported as "Transcription failed".** The speech model needs a full second of audio. Shorter recordings are now padded with silence, so a quick "Yes, fine." works. Below about a third of a second there is nothing to transcribe, and Steneo says "too short" without keeping a file.
- **Long recordings use far less memory.** Audio that was already transcribed in the background is released right away instead of being held until the end (up to 115 MB at ten minutes).

### Under the hood
- Every start logs where its time went. The finding so far: some external microphones need several hundred milliseconds to start, the Mac's own a few dozen. If a fast start matters most, pick the Mac's microphone.
- Every stop logs what caused it.
- The app is inert while it hosts its own unit tests: no global shortcut, no sounds.

## 1.4.5

### Fixed
- **A red microphone now always means your audio is actually being captured.** If the audio engine died underneath a running recording — a device pulled out, a failed recovery after the input changed — nothing noticed. The icon stayed red and you kept talking into a recording that was capturing nothing. Steneo now watches the audio actually arriving and ends the recording within two seconds if it stops, says so, and keeps whatever was captured before that.
- **Recording could capture nothing at all, silently.** Since 1.4.3 Steneo names the input device explicitly before each recording — and selecting it renegotiates the hardware, so a microphone the system was running at 44.1 kHz comes back at 48 kHz. Steneo kept asking the audio engine for the format it had *before* that, listened on the wrong one, and received not a single audio buffer. The start sound played, the icon went red, and the recording was empty. Measured: zero frames in a second where the correct format gives 48 000. This affected 1.4.3 and 1.4.4.
- **A rare hang is gone.** Reading the recorded audio made the app wait on its audio thread, while the audio thread could need the main thread to finish — the two could wait for each other for ever. It needed a device change to land at the same moment as a recording stopping, which is exactly the situation the rest of this release is about. Found by a test that hung instead of failing; the rule is now checked in the source before every release.

## 1.4.4

### Fixed
- **A recording can no longer disappear without a word.** If a recording produced no text — a dead microphone, a model failure, or simply no speech — Steneo used to do *nothing at all*: no text, no history entry, no message, no error, and the audio was thrown away. It looked exactly as though the recording had never happened. Now the reason is named, said out loud, and the audio is kept.

### Added
- **Kept recordings.** When a recording ends with nothing, its audio stays on disk (the last ten) and appears at the top of the menu with the reason it failed. **Try again** runs it through transcription a second time, and there is a button to show it in Finder or delete it. The menubar mic turns blue until you have looked.
- **Failures now have names** in the log — `no-samples`, `too-short`, `asr-error`, `empty-result`, `engine-start` — instead of one silent empty result standing in for all five.

## 1.4.3

### Fixed
- **The microphone no longer goes deaf after a device is unplugged.** Steneo used to let macOS pick the input device implicitly, which meant the audio engine remembered a device *number*. Those numbers are temporary: unplug a USB microphone or let a display re-enumerate, and the same microphone comes back as a different number. The remembered one then pointed at nothing, the engine fell back to a device with no input at all, and every recording failed the moment it started — the start sound played and the menubar mic went straight back to white. Steneo now names the input device explicitly, by its permanent identifier, and resolves it fresh at every single recording: your chosen device, then the system default, then the Mac's own microphone. A device that disappears no longer takes recording with it.
- **The recovery from 1.4.1 could turn into a loop of its own.** It rebuilt the audio input on *every* configuration message from the system, with nothing to stop it. In one measured case that ran at nine rebuilds per second for over four hours and made the microphone unusable. Rebuilding now happens only when the input has genuinely changed, at most twice a second, and gives up with a visible message instead of looping — and it comes back by itself as soon as a recording succeeds.
- **Steneo no longer touches your audio hardware when it isn't recording.** It used to warm up the audio engine at launch and keep it warm between recordings. Warming it opens an input device, and an open input device pulls a Bluetooth headset out of high-quality playback into the mono call profile — which is why AirPods could sound wrong for as long as Steneo was simply *running*. The microphone is now opened when a recording starts and released the moment it stops. Idle Steneo holds nothing. The first moment of a recording costs about 200 ms more, which is what the orange arming icon covers.
- **Bluetooth headsets are never chosen as the microphone on your behalf.** If your AirPods are the system's default input, Steneo quietly uses the Mac's own microphone instead, so recording never degrades what you are listening to. Pick the headset explicitly and Steneo uses it — that is your call to make, not its.
- **"No microphone found" is now something Steneo says.** A Mac with no usable input used to produce a generic engine failure; it now names the actual problem.

## 1.4.2

### Fixed
- **Dictation no longer drops individual letters.** Short text used to be typed character by character, and when the receiving app couldn't keep up it silently swallowed some — "Deutsch" arriving as "Dutsch". That path was narrowed to short text back in 0.8.5 instead of being removed, so it kept happening to anyone dictating a few words at a time. **Auto** now always inserts through the clipboard, which is atomic and cannot lose characters, no matter how long the text is. **Direct Typing** is still there if you deliberately pick it — for apps that block pasting — and now says plainly what it costs.

## 1.4.1

### Fixed
- **Recording could stop working until you restarted the app.** After the audio input changed underneath it — a different microphone becoming the default, an interface waking up, the Mac coming back from sleep — the audio engine kept the *old* device's format and every attempt to record then failed instantly: the start sound played, the menubar mic flashed, and nothing happened. It never recovered on its own. Steneo now follows input-device changes as they happen, and rebuilds the audio engine from scratch if a start still fails, so a recording that can work does work.
- **A failed start is no longer silent.** If the microphone genuinely can't be opened, Steneo says so instead of quietly turning the mic icon back to white.

## 1.4.0

### Added
- **App profiles — dictation adapts to where the text goes.** Steneo now picks its text-output settings from the app you're dictating into. **Standard** is your existing Text Output settings and still applies everywhere by default; alongside it there are four ready-made profiles you can edit: **Note** and **Email** (fillers dropped, paragraphs), **Chat** (fillers dropped, no restructuring) and **Code** (strictly verbatim, pasted atomically so an editor's autocompletion can't mangle it).
- **Assign a profile in one click.** The top of the menu shows the app in front and which profile it will use — pick another one there and that app keeps it. Settings → App Profiles lists every assignment and lets you edit each profile.

- **One switch for the whole feature.** Settings → App Profiles → *Use app profiles*. Turned off, every app uses Standard again and the row disappears from the menu — your assignments are kept, not deleted, so it's a pause rather than a purge.

Nothing changes until you assign a profile: existing setups keep running on Standard exactly as before. The profile is decided the moment you press the shortcut, so switching apps mid-sentence can't change how your text comes out.

## 1.3.2

### Fixed
- **Double-press shortcuts no longer fire on ordinary key combinations.** The detector counted *every* press of the modifier key — including the ⌘ of shortcuts like ⌘C, ⌘V or ⌘Z. Any two of those within 400 ms silently started a recording, and the next deliberate double-press then stopped that phantom recording instead of starting yours: the menubar mic flashed and nothing was dictated. A press now only counts when the modifier is tapped **alone** — no other key, no click, no second modifier, and released again quickly. Holding the key is no longer a tap either.
- **Reinstalling the shortcut no longer doubles it.** Retrying after a failed model load installed a second set of key monitors, so every key event was handled twice. The old monitors are now removed first.

## 1.3.1

### Changed
- **Reworked first-run onboarding** — shorter and clearer: permissions are requested up front (so the app stops nagging for them later), a built-in **test recording** lets you try it immediately, and a screen explains the menubar mic colors and the three ways to start/stop. Deeper features moved to optional "expert" screens you can skip.
- **Instant recording feedback** — the menubar mic turns **orange the instant you press** (arming), then red the moment it's actually capturing, so a press always gives immediate feedback.
- **Renamed to Steneo throughout** — the app's internal identifier is now `com.youngpilot.Steneo`. **One-time:** if you used an earlier build, macOS will ask you to re-grant Microphone & Accessibility and your settings reset to defaults — a clean slate.

## 1.3.0

### Added
- **On-device text formatting (opt-in)** — after dictation, optionally restructure your text right on your Mac: **Paragraphs** (breaks at topic shifts, wording kept) or **Bullets** (a clean list). Settings → Text Output → Format. Uses Apple's on-device model (needs Apple Intelligence, macOS 26+); falls back to leaving the text unchanged.
- **Push-to-talk** — a new **Hold** activation mode: hold your shortcut to record, release to stop. Settings → General → Activation. (Works best with F5 or a Space combo.)

### Changed
- **Long recordings transcribe as you go** — finished parts are transcribed in the background at natural pauses, so the wait when you stop stays short no matter how long you spoke. Short recordings are unchanged.
- **App icon fixed** — Steneo now shows its icon in Finder and on the disk image (the icon images were the wrong size, so none was being bundled).
- **Cleaner settings** — removed the Model Boosting toggle (it had no effect in the current engine; your Wrong → Right corrections still apply every time) and some status text that never appeared.

## 1.2.0

### Added
- **On-device text cleanup (opt-in)** — after dictation Steneo can tidy your text, right on your Mac. Pick in **Settings → Text Output → Cleanup**: **Rules** drops spoken fillers (um, äh) instantly and never changes your wording (safe in any language); **AI** uses Apple's on-device model for a smarter pass (also light grammar; can rephrase); **Off** keeps it verbatim. Nothing is ever sent anywhere. (Smart formatting — paragraphs, bullet lists, "→ email / Slack", tone — is planned for a later version.)

### Changed
- **More reliable & accurate transcription** — your whole recording is now transcribed in one full-context pass the moment you stop, instead of in live windows. This fixes words lost at the very start of a recording and garbled short clips, and improves overall accuracy. The text appears (and is pasted) when you stop.
- **Renamed Stenote → Steneo.** Same app, same on-device engine — only the name. Your settings, history, and permissions carry over (the underlying identifier is unchanged).
- **Instant, honest recording feedback** — the start sound fires the instant you press, and the mic turns red only once it's actually capturing, so a red mic always means you're being recorded. The app no longer gets throttled when idle (App Nap), so the first press after a quiet spell is immediate too.
- **Menubar icon states & clearer file drop** — a deep-red mic while recording, a warm-**yellow** mic while transcribing an audio file, **green** when a file result is ready. Dragging an audio file onto the popover now shows a clear warm-yellow "drop to transcribe" target, so it's obvious the file will be picked up.

## 1.0.0

The 1.0 release — still 100% on-device and private, now with file transcription, encrypted history, a clearer level meter, and dictation stats.

### Added
- **Transcribe audio files** — drag a file onto the popover, pick one with the waveform button in the menubar header, or transcribe an audio file from the clipboard. Files run through the batch speech engine; the text is copied and saved to History.
- **Words-per-minute** — your dictation pace is tracked per recording and shown as an average (`~140 wpm avg`) in the footer stats. File imports and very short or implausibly slow/fast clips are excluded so the number stays honest.
- **Clearer level meter** — the recording waveform is now a boxed strip of bars that reads as an input-level meter: bars rise with your voice and turn orange when you're too loud.
- **Menubar feedback** — the mic icon gently pulses while recording, and a short status line confirms file transcriptions ("Saved to history · copied") or surfaces errors.

### Changed
- **Transcription history is now encrypted at rest** (AES-GCM, key held in the macOS Keychain). Existing plaintext history is migrated automatically on first launch. Recorded audio is still never written to disk.
- Reworked the audio level pipeline to feed the meter directly, dropping the old raw-sample buffer — less memory and less work while recording.

### Internal
- Added a unit-test target (27 tests) covering the streaming-window invariant (the guard behind the 0.8.6 fix), trailing-stutter removal, the AES-GCM primitive, and WPM eligibility.

## 0.8.7

Robustness pass on the recording pipeline:
- A **stop pressed during the brief start-up window** is now honored instead of ignored.
- The audio resampler is reset between recordings, so a new recording never inherits the previous session's filter state.
- The streaming window size is clamped at runtime (not just a debug assert), so it can never exceed the speech model's input limit regardless of future tuning — a permanent guard against the 0.8.6 class of bug.
- An empty final transcript no longer leaves a stale preview fragment behind.

## 0.8.6

### Fixed
- **Long recordings no longer lose the middle.** The streaming recognizer assembled each window as left-context + chunk + right-context = 15.5 s, which exceeds the speech model's fixed 15 s input. Every middle window overflowed and was silently discarded, so only the start and end of a long dictation survived. The window now fits the model with margin (and is clamped so it can never regress). Audio is also delivered to the recognizer through a single in-order pipeline (no out-of-order or overlapping buffers), and pre-roll buffering is bounded, so memory stays flat on arbitrarily long recordings.

## 0.8.5

### Fixed
- **Dropped characters in the output** (e.g. "Deutsch" → "Dutsch", "sauber" → "saubr"). After the switch to whole-text paste, a full sentence was typed key-by-key with no gap, overrunning the target app's event queue so it silently dropped letters. Sentences now insert atomically via the clipboard; the direct-typing path (short snippets / Direct Typing mode) is paced and runs off the main thread so it stays reliable without freezing the UI.

## 0.8.4

### Added
- **Instant start** — pressing the shortcut reacts immediately: amber mic icon + sound the moment it registers, while the (reused, pre-warmed) audio engine spins up. Audio captured during start-up is buffered and fed to the recognizer, so no words are lost.
- **Whole-text paste at stop** — the complete transcript is inserted once when you finish, instead of word-by-word during recording. No more chunk-boundary glitches; the popover still shows a live preview.
- **Individually toggleable voice commands** — turn New line / New paragraph / Period / Comma / Question mark / Exclamation / Colon / Semicolon on or off independently. Paragraph breaks are now the explicit "new paragraph" command (reliable with whole-text paste).
- **Emoji by voice** (opt-in) — say a word next to "emoji", e.g. "smile emoji" → 😊, "emoji fire" → 🔥. Curated, on-device, no model.
- **Microphone warning** in the menubar when access is denied, with a one-click Grant — instead of silently capturing nothing.
- **Recordings per page** and a longer silence range (default 1 min, plus 2 min / 5 min).

### Fixed
- **Crash** when typing characters above U+FFFF (emoji, some CJK) in direct-typing mode — now encoded as UTF-16.
- **Media pause** (Spotify/Apple Music) runs off the main thread, so the first recording isn't delayed by the Automation prompt; the prompt is also front-loaded in onboarding.
- **Recording no longer dies silently** on input-device changes; **clipboard fully preserved** (images/files/rich text) with restore gated on pasting completing.
- If Accessibility is off, the transcript is left on the clipboard (and always saved to history) instead of vanishing.
- "New York, New York" and similar real repetition is no longer trimmed as a stutter.

### Changed
- VoiceOver labels on icon-only controls; clearer Accessibility-grant guidance in onboarding.
- Removed the unreliable automatic pause-based paragraph break (use the "new paragraph" command).
- README documents local data-at-rest and build-from-source signing.

## 0.8.3

- Settings polish: app-wide hover feedback; hovering a category lifts the whole card; bigger, consistent expand/collapse hit area; blue underlined GitHub links.
- Word Corrections: accurate Model-Boosting guidance; boost-only words under 4 letters are caught with a tip.

## 0.8.2

- Fixed **Launch at Login** (the toggle did nothing due to a state-tracking bug).
- Onboarding polish: clear button hovers, a "click a text field first" step, no stray focus ring.

## 0.8.1

- Guided first-run setup (permissions, shortcut, preferences).
- Polished menubar UI.

## 0.8.0

- Renamed **Talkman → Stenote**.
