import Foundation

/// Whether transcripts of audio files are written out as files, and in what shape.
/// Off by default: writing files into someone's folder without being asked is
/// worse than making them ask for it once.
enum FileExportFormat: String, Codable, CaseIterable, Identifiable {
    case none
    case txt
    case md

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "Off"
        case .txt: "Text (.txt)"
        case .md: "Markdown (.md)"
        }
    }

    var fileExtension: String? { self == .none ? nil : rawValue }
}

/// Building the output file for a transcribed audio file. Pure on purpose — the
/// naming and collision rules are the parts that go wrong quietly (a slash in a
/// name writing to the wrong place, a second run silently overwriting the first),
/// so they are testable without touching a disk.
enum TranscriptExport {

    /// The output name for a source file: same base name, new extension.
    /// Path separators and colons are stripped — a source name is data, and a
    /// name like "a/b.wav" must not escape the chosen folder.
    static func outputFilename(forSource source: String, format: FileExportFormat) -> String? {
        guard let ext = format.fileExtension else { return nil }
        let base = (source as NSString).deletingPathExtension
        let cleaned = base
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Leading dots are dropped, not kept: for a source called ".m4a" the base
        // name IS ".m4a" (macOS reads the leading dot as "hidden file, no
        // extension"), and the output would be a hidden ".m4a.txt" nobody finds.
        let visible = cleaned.drop(while: { $0 == "." })
        let safe = visible.isEmpty ? "Transcript" : String(visible)
        return "\(safe).\(ext)"
    }

    /// The file's contents. Markdown gets a heading so a folder full of them is
    /// readable at a glance; plain text stays plain.
    static func body(text: String, sourceName: String, format: FileExportFormat) -> String {
        switch format {
        case .none: return text
        case .txt: return text
        case .md: return "# \(sourceName)\n\n\(text)\n"
        }
    }

    /// A URL that doesn't collide with an existing file: "name.txt", then
    /// "name 2.txt", "name 3.txt" … Transcribing the same file twice must not
    /// destroy the first result. `exists` is injected so this is testable.
    static func uniqueURL(
        in directory: URL, filename: String, exists: (URL) -> Bool
    ) -> URL {
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = directory.appendingPathComponent(filename)
        var counter = 2
        while exists(candidate) {
            let next = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = directory.appendingPathComponent(next)
            counter += 1
        }
        return candidate
    }
}
