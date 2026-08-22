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
        let (button, target) = makeMacUIActionButton(title: actionTitle, action: action)
        actionTarget = target
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 12
        addArrangedSubview(MacUIStatusRow(content: status, title: name, trailingValue: status.label))
        addArrangedSubview(button)
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
        let (button, target) = makeMacUIActionButton(title: actionTitle, action: action)
        actionTarget = target
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 12
        addArrangedSubview(MacUIStatusRow(content: status, title: name, trailingValue: status.label))
        addArrangedSubview(button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}
