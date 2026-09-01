import AppKit

@MainActor
public final class MacUISectionHeader: NSTextField {
    public init(_ title: String, accessibilityIdentifier: String? = nil) {
        super.init(frame: .zero)
        stringValue = title
        font = MacUITokens.Typography.section
        textColor = MacUITokens.Colors.primaryLabel
        isEditable = false
        isSelectable = false
        isBezeled = false
        drawsBackground = false
        MacUIAccessibility.configure(
            self,
            identifier: accessibilityIdentifier ?? MacUIAccessibility.identifier(prefix: "macui.section", label: title),
            label: title,
            role: .staticText
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}

@MainActor
public final class MacUIStatusRow: NSStackView {
    public let content: MacUIStatusContent

    public init(content: MacUIStatusContent, title: String, trailingValue: String? = nil, accessibilityIdentifier: String? = nil) {
        self.content = content
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = MacUITokens.Spacing.controlGroup

        let image = NSImageView()
        image.image = NSImage(
            systemSymbolName: content.iconRole.symbolName,
            accessibilityDescription: content.label
        )
        image.contentTintColor = content.tone.color
        image.setContentHuggingPriority(.required, for: .horizontal)
        addArrangedSubview(image)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = MacUITokens.Typography.body
        addArrangedSubview(titleLabel)

        if let trailingValue {
            let valueLabel = NSTextField(labelWithString: trailingValue)
            valueLabel.textColor = MacUITokens.Colors.secondaryLabel
            valueLabel.alignment = .right
            valueLabel.setContentHuggingPriority(.required, for: .horizontal)
            addArrangedSubview(valueLabel)
        }
        MacUIAccessibility.configure(
            self,
            identifier: accessibilityIdentifier ?? MacUIAccessibility.identifier(prefix: "macui.status-row", label: title),
            label: "\(title), \(content.label)"
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}

@MainActor
public final class MacUIStatusBadge: NSStackView {
    public let content: MacUIStatusContent

    public init(content: MacUIStatusContent, accessibilityIdentifier: String? = nil) {
        self.content = content
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = MacUITokens.Spacing.tight

        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: content.iconRole.symbolName,
            accessibilityDescription: content.label
        )
        icon.contentTintColor = content.tone.color
        addArrangedSubview(icon)

        let label = NSTextField(labelWithString: content.label)
        label.font = MacUITokens.Typography.secondary
        label.textColor = content.tone.color
        addArrangedSubview(label)
        MacUIAccessibility.configure(
            self,
            identifier: accessibilityIdentifier ?? MacUIAccessibility.identifier(prefix: "macui.status-badge", label: content.label),
            label: content.label
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}

@MainActor
public final class MacUIInlineNotice: NSStackView {
    public let content: MacUIStatusContent
    private var actionTarget: MacUIActionTarget?

    public init(
        content: MacUIStatusContent,
        body: String,
        actionTitle: String? = nil,
        action: (@MainActor () -> Void)? = nil,
        accessibilityIdentifier: String? = nil
    ) {
        self.content = content
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = MacUITokens.Spacing.controlGroup
        edgeInsets = NSEdgeInsets(
            top: MacUITokens.Spacing.row,
            left: MacUITokens.Spacing.row,
            bottom: MacUITokens.Spacing.row,
            right: MacUITokens.Spacing.row
        )
        wantsLayer = true
        layer?.cornerRadius = MacUITokens.Radius.contained
        layer?.backgroundColor = MacUITokens.Colors.controlBackground.cgColor

        addArrangedSubview(MacUIStatusRow(content: content, title: content.label))
        let bodyLabel = NSTextField(wrappingLabelWithString: body)
        bodyLabel.textColor = MacUITokens.Colors.secondaryLabel
        bodyLabel.font = MacUITokens.Typography.callout
        addArrangedSubview(bodyLabel)

        if let actionTitle, let action {
            let (button, target) = makeMacUIActionButton(
                title: actionTitle,
                action: action,
                identifier: MacUIAccessibility.identifier(prefix: "macui.notice-action", label: actionTitle)
            )
            actionTarget = target
            addArrangedSubview(button)
        }
        MacUIAccessibility.configure(
            self,
            identifier: accessibilityIdentifier ?? MacUIAccessibility.identifier(prefix: "macui.notice", label: content.label),
            label: content.label
        )
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = MacUITokens.Colors.controlBackground.cgColor
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.backgroundColor = MacUITokens.Colors.controlBackground.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}
