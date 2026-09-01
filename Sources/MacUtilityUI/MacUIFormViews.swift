import AppKit

@MainActor
public final class MacUIFormRow: NSStackView {
    public init(label: String, control: NSView, accessibilityIdentifier: String? = nil) {
        let labelView = NSTextField(labelWithString: label)
        labelView.alignment = .right
        labelView.textColor = MacUITokens.Colors.primaryLabel
        labelView.font = MacUITokens.Typography.body
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .firstBaseline
        spacing = MacUITokens.Spacing.row
        labelView.translatesAutoresizingMaskIntoConstraints = false
        labelView.widthAnchor.constraint(equalToConstant: 128).isActive = true
        addArrangedSubview(labelView)
        addArrangedSubview(control)
        MacUIAccessibility.configure(
            self,
            identifier: accessibilityIdentifier ?? MacUIAccessibility.identifier(prefix: "macui.form-row", label: label),
            label: label
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}

@MainActor
public final class MacUIFieldHelpText: NSTextField {
    public init(_ text: String, accessibilityIdentifier: String? = nil) {
        super.init(frame: .zero)
        stringValue = text
        font = MacUITokens.Typography.helper
        textColor = MacUITokens.Colors.secondaryLabel
        isEditable = false
        isSelectable = false
        isBezeled = false
        drawsBackground = false
        lineBreakMode = .byWordWrapping
        maximumNumberOfLines = 0
        MacUIAccessibility.configure(
            self,
            identifier: accessibilityIdentifier ?? MacUIAccessibility.identifier(prefix: "macui.field-help", label: text),
            label: text,
            role: .staticText
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}
