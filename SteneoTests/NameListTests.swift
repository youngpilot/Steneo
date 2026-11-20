import XCTest
@testable import Steneo

/// The rules around the names list. The listening itself is the speech SDK's
/// and is measured, not unit-tested (`NameMeasurement`).
final class NameListTests: XCTestCase {

    func testANameGetsItsOwnCapitalsBack() {
        XCTAssertEqual(NameList.respell("SpielVibe recommends board games.", names: ["Spielvibe"]),
                       "Spielvibe recommends board games.")
        XCTAssertEqual(NameList.respell("ich nutze steneo jeden tag", names: ["Steneo"]), "ich nutze Steneo jeden tag")
    }

    /// Capitals and nothing else: a longer word that merely contains the name
    /// is a different word.
    func testOnlyWholeWordsAreTouched() {
        XCTAssertEqual(NameList.respell("The airtables are stacked.", names: ["Airtable"]), "The airtables are stacked.")
        XCTAssertEqual(NameList.respell("Stereo is not a name.", names: ["Steneo"]), "Stereo is not a name.",
                       "respelling never turns one word into another")
    }

    func testUmlautsAndSymbolsInANameAreTakenLiterally() {
        XCTAssertEqual(NameList.respell("der mülllotse kommt", names: ["Mülllotse"]), "der Mülllotse kommt")
        XCTAssertEqual(NameList.respell("ask c++ people", names: ["C++ people"]), "ask C++ people")
    }

    func testAnEntryThatIsTooShortIsNotAName() {
        XCTAssertEqual(NameList.usable(["Sal", "  ", "Steneo"]), ["Steneo"])
        XCTAssertEqual(NameList.respell("sal is short", names: ["Sal"]), "sal is short")
    }

    func testTheSameNameTwiceIsOneName() {
        XCTAssertEqual(NameList.usable(["Steneo", " steneo ", "STENEO", "Airtable"]), ["Steneo", "Airtable"],
                       "the first spelling is the one that counts")
    }

    func testAnEmptyListChangesNothing() {
        XCTAssertEqual(NameList.respell("nothing to do", names: []), "nothing to do")
    }
}
