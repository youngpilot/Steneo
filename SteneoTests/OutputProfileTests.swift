import XCTest
@testable import Steneo

/// The per-app profile rule. Every fallback here matters: resolving to the wrong
/// profile silently changes what gets typed (verbatim code turned into bullets,
/// a signature appended to a chat message), so the safe direction is always back
/// to Standard — which is whatever the user already configured.
final class OutputProfileTests: XCTestCase {

    private let standard = OutputProfile(
        name: OutputProfile.standardName,
        cleanupMode: .off, formatMode: .none, insertionMode: .auto)

    private let extras = OutputProfile.shippedExtras

    private func resolve(_ bundleID: String?, _ mapping: [String: String]) -> OutputProfile {
        OutputProfile.resolve(bundleID: bundleID, mapping: mapping, profiles: extras, standard: standard)
    }

    // MARK: - Resolution

    func testMappedAppGetsItsProfile() {
        let p = resolve("com.apple.mail", ["com.apple.mail": "Email"])
        XCTAssertEqual(p.name, "Email")
        XCTAssertEqual(p.formatMode, .paragraphs)
    }

    func testUnmappedAppFallsBackToStandard() {
        XCTAssertEqual(resolve("com.apple.Safari", ["com.apple.mail": "Email"]).name, OutputProfile.standardName)
    }

    func testNoAppFallsBackToStandard() {
        XCTAssertEqual(resolve(nil, ["com.apple.mail": "Email"]).name, OutputProfile.standardName)
    }

    func testExplicitStandardMappingResolvesToStandard() {
        XCTAssertEqual(resolve("com.apple.mail", ["com.apple.mail": "Standard"]).name, OutputProfile.standardName)
    }

    func testMappingToAMissingProfileFallsBackInsteadOfCrashing() {
        // A profile that no longer exists (renamed, or settings carried over from
        // a build that shipped different profiles).
        XCTAssertEqual(resolve("com.apple.mail", ["com.apple.mail": "Ghost"]).name, OutputProfile.standardName)
    }

    func testStandardCarriesTheUsersOwnSettings() {
        let mine = OutputProfile(
            name: OutputProfile.standardName, cleanupMode: .rules, formatMode: .bullets,
            insertionMode: .direct, prefixText: "→ ", suffixText: " ✓")
        let p = OutputProfile.resolve(bundleID: "com.unknown.app", mapping: [:], profiles: extras, standard: mine)
        XCTAssertEqual(p.cleanupMode, .rules)
        XCTAssertEqual(p.formatMode, .bullets)
        XCTAssertEqual(p.insertionMode, .direct)
        XCTAssertEqual(p.prefixText, "→ ")
        XCTAssertEqual(p.suffixText, " ✓")
    }

    // MARK: - The shipped profiles

    func testCodeProfileStaysVerbatim() {
        let code = extras.first { $0.name == "Code" }
        XCTAssertEqual(code?.cleanupMode, .off, "code must never be reworded")
        // Spelled out: on an Optional, a bare `.none` means nil, not FormatMode.none.
        XCTAssertEqual(code?.formatMode, FormatMode.none)
        XCTAssertEqual(code?.insertionMode, .clipboard, "direct typing fights editor autocompletion")
    }

    func testShippedProfileNamesAreUniqueAndNotStandard() {
        let names = extras.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "names are the identity — duplicates would shadow each other")
        XCTAssertFalse(names.contains(OutputProfile.standardName))
    }

    // MARK: - Persistence

    func testProfileSurvivesAJSONRoundTrip() throws {
        let original = OutputProfile(
            name: "Email", cleanupMode: .ai, formatMode: .paragraphs,
            insertionMode: .clipboard, prefixText: "Hi,\n", suffixText: "\nBest")
        let data = try JSONEncoder().encode([original])
        let decoded = try JSONDecoder().decode([OutputProfile].self, from: data)
        XCTAssertEqual(decoded, [original])
    }

    func testDecodingSurvivesAProfileWithoutPrefixOrSuffix() throws {
        // Written by a build before prefix/suffix existed in the profile.
        let json = #"[{"name":"Chat","cleanupMode":"rules","formatMode":"none","insertionMode":"auto"}]"#
        let decoded = try JSONDecoder().decode([OutputProfile].self, from: Data(json.utf8))
        XCTAssertEqual(decoded.first?.name, "Chat")
        XCTAssertEqual(decoded.first?.prefixText, "")
        XCTAssertEqual(decoded.first?.suffixText, "")
    }
}
