import AppKit

@MainActor
public final class MacUIShortcutPresentation: NSStackView {
    public private(set) var glyphs: [String]

    public init(glyphs: [String], accessibilityLabel: String) {
        self.glyphs = glyphs
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 4
        setAccessibilityElement(true)
        setAccessibilityLabel(accessibilityLabel)
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
            label.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            label.alignment = .center
            label.drawsBackground = true
            label.backgroundColor = .controlBackgroundColor
            label.wantsLayer = true
            label.layer?.cornerRadius = 6
            label.setContentHuggingPriority(.required, for: .horizontal)
            addArrangedSubview(label)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}
