import Foundation

/// A named preset of the text-output settings, so dictation can adapt to where the
/// text is going: verbatim into an editor, tidied paragraphs into Mail.
///
/// "Standard" is deliberately NOT stored here — it *is* the app's existing Text
/// Output settings (`SettingsStore.cleanupMode` and friends). That keeps the
/// settings screen editing exactly what it always edited, and means there is no
/// migration to get wrong: everyone's current setup simply becomes Standard.
struct OutputProfile: Codable, Hashable, Identifiable {
    var name: String
    var cleanupMode: CleanupMode
    var formatMode: FormatMode
    var insertionMode: InsertionMode
    var prefixText: String = ""
    var suffixText: String = ""

    var id: String { name }

    init(
        name: String, cleanupMode: CleanupMode, formatMode: FormatMode,
        insertionMode: InsertionMode, prefixText: String = "", suffixText: String = ""
    ) {
        self.name = name
        self.cleanupMode = cleanupMode
        self.formatMode = formatMode
        self.insertionMode = insertionMode
        self.prefixText = prefixText
        self.suffixText = suffixText
    }

    /// Decoded field by field instead of using the synthesised initialiser: that
    /// one throws on any key it doesn't find, and a throw here means the whole
    /// profile list falls back to the shipped defaults — the user's edits gone,
    /// silently. Adding a field in a later version must not do that.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        cleanupMode = try c.decodeIfPresent(CleanupMode.self, forKey: .cleanupMode) ?? .off
        formatMode = try c.decodeIfPresent(FormatMode.self, forKey: .formatMode) ?? .none
        insertionMode = try c.decodeIfPresent(InsertionMode.self, forKey: .insertionMode) ?? .auto
        prefixText = try c.decodeIfPresent(String.self, forKey: .prefixText) ?? ""
        suffixText = try c.decodeIfPresent(String.self, forKey: .suffixText) ?? ""
    }

    /// The profile that mirrors the global Text Output settings.
    static let standardName = "Standard"

    /// The profiles shipped alongside Standard. Opinionated on purpose: Code stays
    /// verbatim and pastes atomically (direct typing fights editor autocompletion),
    /// Chat stays short and unstructured, Note and Email get paragraphs.
    static let shippedExtras: [OutputProfile] = [
        OutputProfile(name: "Note", cleanupMode: .rules, formatMode: .paragraphs, insertionMode: .auto),
        OutputProfile(name: "Email", cleanupMode: .ai, formatMode: .paragraphs, insertionMode: .auto),
        OutputProfile(name: "Chat", cleanupMode: .rules, formatMode: .none, insertionMode: .auto),
        OutputProfile(name: "Code", cleanupMode: .off, formatMode: .none, insertionMode: .clipboard),
    ]

    /// Picks the profile for a target app.
    ///
    /// Pure, so the rule itself is unit-testable: no app, an unmapped app, an
    /// explicit mapping to Standard, or a mapping to a profile that no longer
    /// exists all fall back to Standard. Falling back is always safe — Standard is
    /// whatever the user already configured.
    static func resolve(
        bundleID: String?,
        mapping: [String: String],
        profiles: [OutputProfile],
        standard: OutputProfile
    ) -> OutputProfile {
        guard let bundleID,
              let name = mapping[bundleID],
              name != standardName
        else { return standard }
        return profiles.first { $0.name == name } ?? standard
    }
}
