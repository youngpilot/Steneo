import AppKit
import SwiftUI

/// A real window for reading and reworking a transcript — the popover is 360 pt
/// wide and made for glancing, not for working through a transcribed interview.
///
/// Same shape as `OnboardingPresenter`: one reused window, built from an
/// `NSHostingController`, so a menubar-only app gains a window without gaining an
/// architecture.
@MainActor
final class TranscriptWindowPresenter: NSObject, NSWindowDelegate {
    static let shared = TranscriptWindowPresenter()
    private var window: NSWindow?

    func show(title: String, text: String) {
        // Reuse the window rather than stacking one per transcript: opening five
        // history entries should not bury the screen in near-identical windows.
        if let window {
            window.contentViewController = NSHostingController(rootView: TranscriptView(title: title, initialText: text))
            window.title = title
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: TranscriptView(title: title, initialText: text))
        let win = NSWindow(contentViewController: hosting)
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.title = title
        win.setContentSize(NSSize(width: 620, height: 520))
        win.minSize = NSSize(width: 420, height: 320)
        win.isReleasedWhenClosed = false
        win.center()
        win.delegate = self
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

private struct TranscriptView: View {
    let title: String
    @State private var text: String
    @State private var find = ""
    @State private var replacement = ""
    @State private var caseSensitive = false
    @State private var wholeWords = false
    @State private var lastResult: String?

    init(title: String, initialText: String) {
        self.title = title
        _text = State(initialValue: initialText)
    }

    private var matches: Int {
        find.isEmpty ? 0 : TextSearch.count(of: find, in: text, caseSensitive: caseSensitive, wholeWords: wholeWords)
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                TextField("Find", text: $find)
                    .textFieldStyle(.roundedBorder)
                TextField("Replace with", text: $replacement)
                    .textFieldStyle(.roundedBorder)
                Toggle("Aa", isOn: $caseSensitive)
                    .toggleStyle(.button)
                    .help("Match case")
                Toggle("Whole words", isOn: $wholeWords)
                    .toggleStyle(.button)
                Button("Replace All") {
                    let result = TextSearch.replacingAll(
                        in: text, find: find, with: replacement,
                        caseSensitive: caseSensitive, wholeWords: wholeWords)
                    text = result.text
                    lastResult = result.replacements == 1 ? "1 replacement" : "\(result.replacements) replacements"
                }
                .disabled(find.isEmpty || matches == 0)
            }

            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 10) {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    lastResult = "Copied"
                }
                Button("Save as…") { save() }
            }
        }
        .padding(14)
        .frame(minWidth: 420, minHeight: 320)
        // "Copied" or "3 replacements" describes the moment it happened. Once the
        // search or the text moves on, the line goes back to counting.
        .onChange(of: find) { lastResult = nil }
        .onChange(of: text) { _, _ in if lastResult == "Copied" || lastResult?.hasPrefix("Saved") == true { lastResult = nil } }
    }

    private var footer: String {
        if let lastResult { return lastResult }
        if !find.isEmpty { return matches == 1 ? "1 match" : "\(matches) matches" }
        let words = text.split { $0.isWhitespace || $0.isNewline }.count
        return "\(words) words · \(text.count) characters"
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(title).txt"
        panel.directoryURL = URL(fileURLWithPath: SettingsStore.shared.exportDirectory)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            lastResult = "Saved to \(url.lastPathComponent)"
        } catch {
            lastResult = "Could not save: \(error.localizedDescription)"
        }
    }
}
