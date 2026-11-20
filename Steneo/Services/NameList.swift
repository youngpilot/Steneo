import Foundation

/// The names a person wants written their way: products, companies, people.
///
/// Pure rules only. What does the listening is the speech SDK's vocabulary
/// rescoring; this decides which entries are usable and gives a name its own
/// capitals back when the model heard it right but spelled it "SpielVibe".
enum NameList {
    /// Shorter entries are not names any more, they are syllables: "Sal" would
    /// match half the dictionary. The SDK draws the same line.
    static let minimumLength = 4

    /// The entries worth listening for: trimmed, long enough, and each once
    /// (two spellings that differ only in capitals are one name; the first wins).
    static func usable(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.compactMap { name in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= minimumLength, seen.insert(trimmed.lowercased()).inserted else { return nil }
            return trimmed
        }
    }

    /// Write every listed name the way the list spells it, wherever it stands
    /// as a whole word in other capitals. Changes capitals and nothing else.
    static func respell(_ text: String, names: [String]) -> String {
        var result = text
        for name in usable(names) {
            guard let regex = try? NSRegularExpression(
                pattern: "\\b\(NSRegularExpression.escapedPattern(for: name))\\b", options: .caseInsensitive)
            else { continue }
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result),
                withTemplate: NSRegularExpression.escapedTemplate(for: name))
        }
        return result
    }
}
