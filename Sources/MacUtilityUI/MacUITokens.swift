import AppKit

public enum MacUITokens {
    public enum Spacing {
        public static let tight: CGFloat = 4
        public static let controlGroup: CGFloat = 8
        public static let row: CGFloat = 12
        public static let section: CGFloat = 16
        public static let major: CGFloat = 24
        public static let window: CGFloat = 32
    }

    public enum Radius {
        public static let compact: CGFloat = 6
        public static let contained: CGFloat = 8
        public static let notice: CGFloat = 10
        public static let floating: CGFloat = 12
    }

    @MainActor
    public enum Typography {
        public static var heading: NSFont { .systemFont(ofSize: 20, weight: .semibold) }
        public static var section: NSFont { .systemFont(ofSize: 13, weight: .semibold) }
        public static var label: NSFont { .systemFont(ofSize: 13) }
        public static var body: NSFont { .preferredFont(forTextStyle: .body) }
        public static var secondary: NSFont { .preferredFont(forTextStyle: .caption1) }
        public static var helper: NSFont { .preferredFont(forTextStyle: .caption1) }
        public static var callout: NSFont { .preferredFont(forTextStyle: .callout) }
        public static var shortcut: NSFont { .monospacedSystemFont(ofSize: 13, weight: .medium) }
    }

    @MainActor
    public enum Colors {
        public static var primaryLabel: NSColor { .labelColor }
        public static var secondaryLabel: NSColor { .secondaryLabelColor }
        public static var tertiaryLabel: NSColor { .tertiaryLabelColor }
        public static var windowBackground: NSColor { .windowBackgroundColor }
        public static var controlBackground: NSColor { .controlBackgroundColor }
        public static var textBackground: NSColor { .textBackgroundColor }
        public static var separator: NSColor { .separatorColor }
        public static var selectedContentBackground: NSColor { .selectedContentBackgroundColor }
        public static var accent: NSColor { .controlAccentColor }
        public static var success: NSColor { .systemGreen }
        public static var warning: NSColor { .systemOrange }
        public static var critical: NSColor { .systemRed }
    }
}

@MainActor
enum MacUIAccessibility {
    static func identifier(prefix: String, label: String) -> String {
        let suffix = label.lowercased().map { character in
            character.isLetter || character.isNumber ? String(character) : "-"
        }.joined()
        let trimmed = suffix.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? prefix : prefix + "." + trimmed
    }

    static func configure(
        _ view: NSView,
        identifier: String,
        label: String,
        role: NSAccessibility.Role = .group
    ) {
        view.setAccessibilityElement(true)
        view.setAccessibilityIdentifier(identifier.isEmpty ? "macui.component" : identifier)
        view.setAccessibilityRole(role)
        view.setAccessibilityLabel(label)
    }
}
