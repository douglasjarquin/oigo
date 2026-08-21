import AppKit

@MainActor
public final class MacUIFormRow: NSStackView {
    public init(label: String, control: NSView) {
        let labelView = NSTextField(labelWithString: label)
        labelView.alignment = .right
        labelView.textColor = .labelColor
        labelView.font = .preferredFont(forTextStyle: .body)
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .firstBaseline
        spacing = 12
        labelView.translatesAutoresizingMaskIntoConstraints = false
        labelView.widthAnchor.constraint(equalToConstant: 128).isActive = true
        addArrangedSubview(labelView)
        addArrangedSubview(control)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}

@MainActor
public final class MacUIFieldHelpText: NSTextField {
    public init(_ text: String) {
        super.init(frame: .zero)
        stringValue = text
        font = .preferredFont(forTextStyle: .caption1)
        textColor = .secondaryLabelColor
        isEditable = false
        isSelectable = false
        isBezeled = false
        drawsBackground = false
        lineBreakMode = .byWordWrapping
        maximumNumberOfLines = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}
