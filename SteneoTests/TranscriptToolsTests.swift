import XCTest
@testable import Steneo

/// The two pure pieces behind 1.5.0: find-and-replace in the transcript window,
/// and the naming of exported transcript files. Both fail quietly in a UI — a
/// wrong replacement looks like a typo, a colliding filename looks like nothing
/// at all until yesterday's transcript is gone.
final class TranscriptToolsTests: XCTestCase {

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

    // MARK: - Export naming

    func testOutputFilenameKeepsTheBaseNameAndSwapsTheExtension() {
        XCTAssertEqual(TranscriptExport.outputFilename(forSource: "interview.m4a", format: .txt), "interview.txt")
        XCTAssertEqual(TranscriptExport.outputFilename(forSource: "interview.m4a", format: .md), "interview.md")
    }

    func testOutputFilenameIsNilWhenExportIsOff() {
        XCTAssertNil(TranscriptExport.outputFilename(forSource: "interview.m4a", format: .none))
    }

    /// A source name is data. A slash in it must not steer the write somewhere else.
    func testOutputFilenameStripsPathSeparators() {
        let name = TranscriptExport.outputFilename(forSource: "a/b:c.wav", format: .txt)
        XCTAssertEqual(name, "a-b-c.txt")
        XCTAssertFalse(name!.contains("/"))
    }

    /// ".m4a" is not "no name": macOS reads it as a hidden file NAMED ".m4a" with
    /// no extension, so "m4a.txt" is the honest output. Only a name that really is
    /// empty falls back.
    func testOutputFilenameFallsBackOnlyWhenNothingIsLeft() {
        XCTAssertEqual(TranscriptExport.outputFilename(forSource: ".m4a", format: .txt), "m4a.txt")
        XCTAssertEqual(TranscriptExport.outputFilename(forSource: "...", format: .txt), "Transcript.txt")
        XCTAssertEqual(TranscriptExport.outputFilename(forSource: "", format: .txt), "Transcript.txt")
    }

    /// A hidden source must not produce a hidden transcript — the user would never
    /// see the file they asked for.
    func testOutputFilenameIsNeverHidden() {
        XCTAssertEqual(TranscriptExport.outputFilename(forSource: ".notes.wav", format: .txt), "notes.txt")
    }

    func testMarkdownGetsAHeadingAndPlainTextDoesNot() {
        XCTAssertEqual(TranscriptExport.body(text: "hello", sourceName: "talk", format: .md), "# talk\n\nhello\n")
        XCTAssertEqual(TranscriptExport.body(text: "hello", sourceName: "talk", format: .txt), "hello")
    }

    func testUniqueURLLeavesAFreeNameAlone() {
        let dir = URL(fileURLWithPath: "/tmp")
        let url = TranscriptExport.uniqueURL(in: dir, filename: "talk.txt") { _ in false }
        XCTAssertEqual(url.lastPathComponent, "talk.txt")
    }

    /// Transcribing the same file twice must not overwrite the first result.
    func testUniqueURLStepsAsideForExistingFiles() {
        let dir = URL(fileURLWithPath: "/tmp")
        let taken: Set<String> = ["talk.txt", "talk 2.txt"]
        let url = TranscriptExport.uniqueURL(in: dir, filename: "talk.txt") { taken.contains($0.lastPathComponent) }
        XCTAssertEqual(url.lastPathComponent, "talk 3.txt")
    }
}
