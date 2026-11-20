import Foundation

/// Find-and-replace over a transcript.
///
/// Pure and separate from the window on purpose: the rules people actually get
/// bitten by — matching inside longer words, case handling, and a replacement
/// that contains the search term — are invisible in a UI test and obvious in a
/// unit test.
enum TextSearch {

    struct Result: Equatable {
        var text: String
        var replacements: Int
    }

    /// Replaces every occurrence of `find` with `replacement`.
    ///
    /// Scanning left to right and continuing *after* the inserted replacement is
    /// what stops "a" → "aa" from running forever, and what makes replacing a
    /// term with itself-plus-something behave.
    static func replacingAll(
        in text: String,
        find: String,
        with replacement: String,
        caseSensitive: Bool = false,
        wholeWords: Bool = false
    ) -> Result {
        guard !find.isEmpty else { return Result(text: text, replacements: 0) }

        let options: String.CompareOptions = caseSensitive ? [.literal] : [.caseInsensitive]
        var result = ""
        var count = 0
        var index = text.startIndex

        while index < text.endIndex,
              let range = text.range(of: find, options: options, range: index..<text.endIndex) {
            if wholeWords, !isWholeWord(range, in: text) {
                // Not a standalone word — keep the text up to and including this
                // near-miss and carry on past it.
                result += text[index..<range.upperBound]
                index = range.upperBound
                continue
            }
            result += text[index..<range.lowerBound]
            result += replacement
            count += 1
            index = range.upperBound
        }
        result += text[index...]
        return Result(text: result, replacements: count)
    }

    /// How many times `find` occurs, using the same rules as replacing.
    /// A find-and-replace as something worth remembering: both sides trimmed,
    /// and nil when either is empty. An empty replacement would delete a word
    /// from every future transcript, which nobody means by "always".
    static func correction(find: String, replacement: String) -> (from: String, to: String)? {
        let from = find.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !from.isEmpty, !to.isEmpty, from != to else { return nil }
        return (from, to)
    }

    static func count(
        of find: String, in text: String, caseSensitive: Bool = false, wholeWords: Bool = false
    ) -> Int {
        replacingAll(in: text, find: find, with: find, caseSensitive: caseSensitive, wholeWords: wholeWords)
            .replacements
    }

    /// A match is a whole word when neither neighbour is a letter or digit, so
    /// "Steneo" doesn't match inside "Steneos" but does at "(Steneo)".
    private static func isWholeWord(_ range: Range<String.Index>, in text: String) -> Bool {
        let isWordCharacter: (Character) -> Bool = { $0.isLetter || $0.isNumber || $0 == "_" }
        if range.lowerBound > text.startIndex {
            let before = text[text.index(before: range.lowerBound)]
            if isWordCharacter(before) { return false }
        }
        if range.upperBound < text.endIndex {
            let after = text[range.upperBound]
            if isWordCharacter(after) { return false }
        }
        return true
    }
}
