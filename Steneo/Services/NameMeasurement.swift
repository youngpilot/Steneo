#if DEBUG
import AVFoundation
import FluidAudio
import Foundation

/// The gate for a names list (1.9): does vocabulary boosting put proper names
/// right, and what does it break while doing so?
///
/// A names list is only worth shipping if it fixes names WITHOUT rewriting
/// ordinary words into them, in German as well as in English. The model that
/// does the checking is an English one, so German is the open question.
///
/// Silent: the sentences are written to files by `say -o` and never played.
/// Synthetic voices are easier to recognise than people, so this measures the
/// effect of the list and its side effects, not absolute accuracy.
///
/// Lives in the app target because that is where FluidAudio is linked. DEBUG
/// only, so none of it reaches a release build.
enum NameMeasurement {

    static let names = ["Steneo", "Salesfive", "Spielvibe", "Schiemann", "Anthropic",
                        "TodayTag", "RapidRock", "Mülllotse", "FluidAudio", "Airtable"]

    struct Sentence {
        let voice: String
        let text: String
        /// The name it contains. nil for a control: an ordinary sentence, some
        /// of them with words that sound like a name on the list.
        let name: String?
    }

    static let sentences: [Sentence] = [
        .init(voice: "Anna", text: "Ich habe Steneo heute den ganzen Tag benutzt.", name: "Steneo"),
        .init(voice: "Anna", text: "Bei Salesfive war ich früher Senior Lead.", name: "Salesfive"),
        .init(voice: "Anna", text: "Spielvibe empfiehlt Brettspiele für jeden Abend.", name: "Spielvibe"),
        .init(voice: "Anna", text: "Bitte schick die Rechnung an Julian Schiemann.", name: "Schiemann"),
        .init(voice: "Anna", text: "Das neue Modell von Anthropic ist sehr gut.", name: "Anthropic"),
        .init(voice: "Anna", text: "TodayTag zeigt, was heute in der Geschichte passiert ist.", name: "TodayTag"),
        .init(voice: "Anna", text: "Der Mülllotse sagt mir, wann der Müll abgeholt wird.", name: "Mülllotse"),
        .init(voice: "Anna", text: "Die Daten liegen in Airtable und nicht im Repository.", name: "Airtable"),
        .init(voice: "Samantha", text: "I have been using Steneo all day today.", name: "Steneo"),
        .init(voice: "Samantha", text: "I used to work as a senior lead at Salesfive.", name: "Salesfive"),
        .init(voice: "Samantha", text: "Spielvibe recommends board games for every evening.", name: "Spielvibe"),
        .init(voice: "Samantha", text: "Please send the invoice to Julian Schiemann.", name: "Schiemann"),
        .init(voice: "Samantha", text: "The new model from Anthropic is very good.", name: "Anthropic"),
        .init(voice: "Samantha", text: "RapidRock is a sound board for the stage.", name: "RapidRock"),
        .init(voice: "Samantha", text: "FluidAudio runs the speech model on this Mac.", name: "FluidAudio"),
        .init(voice: "Samantha", text: "The records live in Airtable and not in the repository.", name: "Airtable"),

        .init(voice: "Anna", text: "Die Stereoanlage im Wohnzimmer ist kaputt.", name: nil),
        .init(voice: "Anna", text: "Wir spielen heute Abend ein Brettspiel.", name: nil),
        .init(voice: "Anna", text: "Der Zug fährt auf der Schiene nach Berlin.", name: nil),
        .init(voice: "Anna", text: "Heute ist ein schöner Tag zum Segeln.", name: nil),
        .init(voice: "Anna", text: "Der Müll wird am Dienstag abgeholt.", name: nil),
        .init(voice: "Anna", text: "Im Vertrieb haben wir fünf neue Kunden gewonnen.", name: nil),
        .init(voice: "Anna", text: "Die Luft ist heute sehr klar und kalt.", name: nil),
        .init(voice: "Anna", text: "Ich schreibe morgen den Bericht fertig.", name: nil),
        .init(voice: "Samantha", text: "The stereo in the living room is broken.", name: nil),
        .init(voice: "Samantha", text: "We closed five sales this week.", name: nil),
        .init(voice: "Samantha", text: "Anthropology is the study of human societies.", name: nil),
        .init(voice: "Samantha", text: "Today I tagged all the photos from the trip.", name: nil),
        .init(voice: "Samantha", text: "The river runs rapid over the rock.", name: nil),
        .init(voice: "Samantha", text: "The fluid in the audio cable is a joke.", name: nil),
        .init(voice: "Samantha", text: "Please put the air filter on the table.", name: nil),
        .init(voice: "Samantha", text: "I will finish the report tomorrow morning.", name: nil),
    ]

    /// One sentence as 16 kHz mono, written by `say` and read back. Never played.
    static func synthesize(_ sentence: Sentence, into directory: URL) throws -> [Float] {
        let file = directory.appendingPathComponent(UUID().uuidString + ".aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", sentence.voice, "-o", file.path, sentence.text]
        try say.run()
        say.waitUntilExit()
        let audio = try AVAudioFile(forReading: file)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat,
                                            frameCapacity: AVAudioFrameCount(audio.length)) else { return [] }
        try audio.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        return AudioResampler.resample(samples, from: audio.processingFormat.sampleRate)
    }

    private static func milliseconds(since start: Date) -> Double { Date().timeIntervalSince(start) * 1000 }

    /// One sentence through the app's own transcription, the path a recording
    /// takes when it stops.
    @MainActor
    private static func dictate(_ samples: [Float], with service: TranscriptionService) async -> String {
        service.beginCapturing()
        await service.startTranscription()
        return await service.stopTranscription(rawSamples: samples, rate: 16_000)
    }

    /// Runs every sentence through the SDK directly — no list, the list as the
    /// SDK ships it, the list without its acoustic rescue — and through the
    /// app's own transcription with and without the list. Returns a report.
    @MainActor
    static func run() async throws -> String {
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        let asr = AsrManager(models: models)
        let ctc = try await CtcModels.downloadAndLoad(variant: .ctc110m)
        let vocabulary = CustomVocabularyContext(terms: names.map { CustomVocabularyTerm(text: $0) })
        let standard = try await VocabularyBoostingSession(vocabulary: vocabulary, ctcModels: ctc)
        let cautious = try await VocabularyBoostingSession(
            vocabulary: vocabulary, ctcModels: ctc,
            config: VocabularyRescorer.Config(spotterRescueEnabled: false))

        // The app's own code, once without names and once with this list. Neither
        // reads or writes the person's settings.
        let appWithoutNames = TranscriptionService()
        appWithoutNames.listedNames = { [] }
        let app = TranscriptionService()
        app.listedNames = { names }
        app.prepareNames()
        await app.namesSettled()
        guard app.namesState == .ready else { return "The names model did not load: \(app.namesState)" }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("steneo-names-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var lines: [String] = []
        var hits = (plain: 0, standard: 0, cautious: 0, shipped: 0, of: 0)
        var broken = (standard: 0, cautious: 0, shipped: 0, of: 0)
        var time = (plain: 0.0, standard: 0.0, cautious: 0.0, shipped: 0.0, appPlain: 0.0, audio: 0.0)

        for sentence in sentences {
            let samples = try synthesize(sentence, into: directory)
            time.audio += Double(samples.count) / 16_000

            var decoder = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
            var began = Date()
            let result = try await asr.transcribe(samples, decoderState: &decoder)
            time.plain += milliseconds(since: began)
            let timings = result.tokenTimings ?? []

            began = Date()
            let a = await standard.rescore(text: result.text, tokenTimings: timings, audioSamples: samples)
            time.standard += milliseconds(since: began)
            began = Date()
            let b = await cautious.rescore(text: result.text, tokenTimings: timings, audioSamples: samples)
            time.cautious += milliseconds(since: began)
            let withList = a?.text ?? result.text
            let withCautiousList = b?.text ?? result.text

            // What ships: the app's own transcription, with the list and without.
            began = Date()
            let appPlain = await dictate(samples, with: appWithoutNames)
            time.appPlain += milliseconds(since: began)
            began = Date()
            let shipped = await dictate(samples, with: app)
            time.shipped += milliseconds(since: began)

            let language = sentence.voice == "Anna" ? "DE" : "EN"
            if let name = sentence.name {
                hits.of += 1
                if result.text.contains(name) { hits.plain += 1 }
                if withList.contains(name) { hits.standard += 1 }
                if withCautiousList.contains(name) { hits.cautious += 1 }
                if shipped.contains(name) { hits.shipped += 1 }
                lines.append("\(language) name \(name): [\(result.text.contains(name) ? "x" : " ")|\(withList.contains(name) ? "x" : " ")|\(withCautiousList.contains(name) ? "x" : " ")|\(shipped.contains(name) ? "x" : " ")]")
            } else {
                broken.of += 1
                if withList != result.text { broken.standard += 1 }
                if withCautiousList != result.text { broken.cautious += 1 }
                if shipped != appPlain { broken.shipped += 1 }
                lines.append("\(language) control: [\(withList == result.text ? "ok" : "CHANGED")|\(withCautiousList == result.text ? "ok" : "CHANGED")|\(shipped == appPlain ? "ok" : "CHANGED")]")
            }
            lines.append("    said    : \(sentence.text)")
            lines.append("    no list : \(result.text)")
            if withList != result.text { lines.append("    list    : \(withList)") }
            if withCautiousList != result.text, withCautiousList != withList { lines.append("    cautious: \(withCautiousList)") }
            if appPlain != result.text { lines.append("    app     : \(appPlain)") }
            if shipped != appPlain { lines.append("    shipped : \(shipped)") }
        }

        lines.append("")
        lines.append("NAMES written right, of \(hits.of): no list \(hits.plain) · list \(hits.standard) · list without rescue \(hits.cautious) · as shipped \(hits.shipped)")
        lines.append("CONTROLS changed, of \(broken.of): list \(broken.standard) · list without rescue \(broken.cautious) · as shipped \(broken.shipped)")
        lines.append(String(format: "TIME for %.0f s of audio: model %.0f ms · list +%.0f ms · list without rescue +%.0f ms",
                            time.audio, time.plain, time.standard, time.cautious))
        lines.append(String(format: "TIME in the app, %d sentences: %.0f ms without names · %.0f ms with the list (+%.0f ms per sentence)",
                            sentences.count, time.appPlain, time.shipped, (time.shipped - time.appPlain) / Double(sentences.count)))
        return lines.joined(separator: "\n")
    }
}
#endif
