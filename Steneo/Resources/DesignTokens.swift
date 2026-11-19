import SwiftUI

enum DesignTokens {
    enum Color {
        static let accent = SwiftUI.Color.accentColor
        static let recording = SwiftUI.Color.red
        static let background = SwiftUI.Color(.windowBackgroundColor)
        /// What the menu's content sits on. The window itself is glass, and text
        /// on glass over a busy desktop was hard to read. One number: 1 is opaque.
        static let backdrop = SwiftUI.Color(.windowBackgroundColor).opacity(0.92)
        /// A card on the backdrop. A tint, not a material: a material lets the
        /// desktop through exactly where the text is.
        static let card = SwiftUI.Color.primary.opacity(0.06)
        static let label = SwiftUI.Color(.labelColor)
        static let labelSecondary = SwiftUI.Color(.secondaryLabelColor)
    }

    enum Font {
        static let body = SwiftUI.Font.system(.body)
        static let caption = SwiftUI.Font.system(.caption)
        static let headline = SwiftUI.Font.system(.headline)
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Radius {
        static let button: CGFloat = 8
    }
}
