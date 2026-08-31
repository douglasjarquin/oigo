import AppKit

@MainActor
public final class MacUIPermissionRow: NSStackView {
    private let actionTarget: MacUIActionTarget

    public init(
        name: String,
        status: MacUIStatusContent,
        actionTitle: String = "Open System Settings",
        action: @escaping @MainActor () -> Void
    ) {
        let (button, target) = makeMacUIActionButton(
            title: actionTitle,
            action: action,
            identifier: MacUIAccessibility.identifier(prefix: "macui.permission-action", label: name)
        )
        actionTarget = target
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = MacUITokens.Spacing.row
        addArrangedSubview(MacUIStatusRow(content: status, title: name, trailingValue: status.label))
        addArrangedSubview(button)
        MacUIAccessibility.configure(self, identifier: MacUIAccessibility.identifier(prefix: "macui.permission-row", label: name), label: name)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}

@MainActor
public final class MacUIStorageHealthRow: NSStackView {
    private let actionTarget: MacUIActionTarget

    public init(
        name: String,
        status: MacUIStatusContent,
        actionTitle: String = "Retry",
        action: @escaping @MainActor () -> Void
    ) {
        let (button, target) = makeMacUIActionButton(
            title: actionTitle,
            action: action,
            identifier: MacUIAccessibility.identifier(prefix: "macui.storage-action", label: name)
        )
        actionTarget = target
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = MacUITokens.Spacing.row
        addArrangedSubview(MacUIStatusRow(content: status, title: name, trailingValue: status.label))
        addArrangedSubview(button)
        MacUIAccessibility.configure(self, identifier: MacUIAccessibility.identifier(prefix: "macui.storage-row", label: name), label: name)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}
