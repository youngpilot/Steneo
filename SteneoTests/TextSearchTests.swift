import XCTest
@testable import Steneo

/// Find-and-replace in the transcript window. The rules people actually get bitten
/// by — matching inside longer words, case handling, and a replacement that
/// contains the search term — are invisible in a UI and obvious here.
final class TextSearchTests: XCTestCase {

    // MARK: - Making a replacement permanent

    func testAReplacementCanBecomeACorrection() {
        let pair = TextSearch.correction(find: " antropic ", replacement: "Anthropic")
        XCTAssertEqual(pair?.from, "antropic", "spaces around a word typed into a field are not part of it")
        XCTAssertEqual(pair?.to, "Anthropic")
    }

    /// Capitalisation alone is a correction too: corrections match in any case.
    func testFixingOnlyTheCapitalsCounts() {
        XCTAssertNotNil(TextSearch.correction(find: "steneo", replacement: "Steneo"))
    }

    /// "Always replace with nothing" would delete a word from every transcript.
    func testDeletingIsNeverMadePermanent() {
        XCTAssertNil(TextSearch.correction(find: "um", replacement: ""))
        XCTAssertNil(TextSearch.correction(find: "um", replacement: "   "))
        XCTAssertNil(TextSearch.correction(find: "", replacement: "Anthropic"))
        XCTAssertNil(TextSearch.correction(find: "same", replacement: "same"), "nothing to remember")
    }

    // MARK: - Find and replace

    func testReplacesEveryOccurrence() {
        let r = TextSearch.replacingAll(in: "one two one two one", find: "one", with: "1")
        XCTAssertEqual(r.text, "1 two 1 two 1")
        XCTAssertEqual(r.replacements, 3)
    }

    func testIsCaseInsensitiveByDefault() {
        let r = TextSearch.replacingAll(in: "Steneo steneo STENEO", find: "steneo", with: "X")
        XCTAssertEqual(r.replacements, 3)
        XCTAssertEqual(r.text, "X X X")
    }

    func testCaseSensitiveMatchesOnlyTheExactForm() {
        let r = TextSearch.replacingAll(in: "Steneo steneo", find: "steneo", with: "X", caseSensitive: true)
        XCTAssertEqual(r.replacements, 1)
        XCTAssertEqual(r.text, "Steneo X")
    }

    func testWholeWordsDoesNotMatchInsideALongerWord() {
        let r = TextSearch.replacingAll(in: "Steneo Steneos", find: "Steneo", with: "X", wholeWords: true)
        XCTAssertEqual(r.replacements, 1)
        XCTAssertEqual(r.text, "X Steneos")
    }

    func testWholeWordsStillMatchesNextToPunctuation() {
        let r = TextSearch.replacingAll(in: "(Steneo), Steneo.", find: "Steneo", with: "X", wholeWords: true)
        XCTAssertEqual(r.replacements, 2)
        XCTAssertEqual(r.text, "(X), X.")
    }

    /// The loop trap: replacing a term with something that contains it must
    /// terminate and must not re-process what it just inserted.
    func testReplacementContainingTheSearchTermTerminates() {
        let r = TextSearch.replacingAll(in: "a a", find: "a", with: "aa")
        XCTAssertEqual(r.text, "aa aa")
        XCTAssertEqual(r.replacements, 2)
    }

    func testEmptySearchChangesNothing() {
        let r = TextSearch.replacingAll(in: "unchanged", find: "", with: "X")
        XCTAssertEqual(r.text, "unchanged")
        XCTAssertEqual(r.replacements, 0)
    }

    func testNoMatchLeavesTheTextIdentical() {
        let r = TextSearch.replacingAll(in: "nothing here", find: "absent", with: "X")
        XCTAssertEqual(r.text, "nothing here")
        XCTAssertEqual(r.replacements, 0)
    }

    /// The count shown in the window must be the number the button will replace,
    /// or the button lies about what it is about to do.
    func testCountAgreesWithReplacing() {
        let text = "Bär Bären Bär"
        for whole in [true, false] {
            let counted = TextSearch.count(of: "Bär", in: text, wholeWords: whole)
            let replaced = TextSearch.replacingAll(in: text, find: "Bär", with: "X", wholeWords: whole).replacements
            XCTAssertEqual(counted, replaced, "wholeWords: \(whole)")
        }
    }
}
