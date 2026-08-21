import AppKit

@MainActor
public final class MacUISectionHeader: NSTextField {
    public init(_ title: String) {
        super.init(frame: .zero)
        stringValue = title
        font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        textColor = .labelColor
        isEditable = false
        isSelectable = false
        isBezeled = false
        drawsBackground = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}

@MainActor
public final class MacUIStatusRow: NSStackView {
    public let content: MacUIStatusContent

    public init(content: MacUIStatusContent, title: String, trailingValue: String? = nil) {
        self.content = content
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 8

        let image = NSImageView()
        image.image = NSImage(
            systemSymbolName: content.iconRole.symbolName,
            accessibilityDescription: content.label
        )
        image.contentTintColor = content.tone.color
        image.setContentHuggingPriority(.required, for: .horizontal)
        addArrangedSubview(image)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .preferredFont(forTextStyle: .body)
        addArrangedSubview(titleLabel)

        if let trailingValue {
            let valueLabel = NSTextField(labelWithString: trailingValue)
            valueLabel.textColor = .secondaryLabelColor
            valueLabel.alignment = .right
            valueLabel.setContentHuggingPriority(.required, for: .horizontal)
            addArrangedSubview(valueLabel)
        }
        setAccessibilityElement(true)
        setAccessibilityLabel("\(title), \(content.label)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}

@MainActor
public final class MacUIStatusBadge: NSStackView {
    public let content: MacUIStatusContent

    public init(content: MacUIStatusContent) {
        self.content = content
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 4

        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: content.iconRole.symbolName,
            accessibilityDescription: content.label
        )
        icon.contentTintColor = content.tone.color
        addArrangedSubview(icon)

        let label = NSTextField(labelWithString: content.label)
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = content.tone.color
        addArrangedSubview(label)
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
        action: (@MainActor () -> Void)? = nil
    ) {
        self.content = content
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        addArrangedSubview(MacUIStatusRow(content: content, title: content.label))
        let bodyLabel = NSTextField(wrappingLabelWithString: body)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.font = .preferredFont(forTextStyle: .callout)
        addArrangedSubview(bodyLabel)

        if let actionTitle, let action {
            let (button, target) = makeMacUIActionButton(title: actionTitle, action: action)
            actionTarget = target
            addArrangedSubview(button)
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}
