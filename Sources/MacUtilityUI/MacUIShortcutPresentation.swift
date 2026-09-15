import AppKit

@MainActor
public final class MacUIShortcutPresentation: NSStackView {
    public private(set) var glyphs: [String]

    public init(glyphs: [String], accessibilityLabel: String, accessibilityIdentifier: String? = nil) {
        self.glyphs = glyphs
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = MacUITokens.Spacing.tight
        MacUIAccessibility.configure(
            self,
            identifier: accessibilityIdentifier ?? "macui.shortcut",
            label: accessibilityLabel
        )
        rebuildGlyphs()
    }

    public func update(glyphs: [String], accessibilityLabel: String) {
        self.glyphs = glyphs
        setAccessibilityLabel(accessibilityLabel)
        rebuildGlyphs()
    }

    private func rebuildGlyphs() {
        arrangedSubviews.forEach { removeArrangedSubview($0); $0.removeFromSuperview() }
        for glyph in glyphs {
            let label = NSTextField(labelWithString: glyph)
            label.font = MacUITokens.Typography.shortcut
            label.alignment = .center
            label.drawsBackground = true
            label.backgroundColor = MacUITokens.Colors.controlBackground
            label.wantsLayer = true
            label.layer?.cornerRadius = MacUITokens.Radius.compact
            label.setAccessibilityRole(.staticText)
            label.setAccessibilityLabel(glyph)
            label.setContentHuggingPriority(.required, for: .horizontal)
            addArrangedSubview(label)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}
