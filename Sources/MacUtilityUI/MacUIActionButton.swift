import AppKit

@MainActor
final class MacUIActionTarget: NSObject {
    private let action: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    @objc func performAction() {
        action()
    }
}

@MainActor
func makeMacUIActionButton(
    title: String,
    action: @escaping @MainActor () -> Void,
    identifier: String? = nil
) -> (NSButton, MacUIActionTarget) {
    let target = MacUIActionTarget(action: action)
    let button = NSButton(title: title, target: target, action: #selector(MacUIActionTarget.performAction))
    button.bezelStyle = .rounded
    MacUIAccessibility.configure(
        button,
        identifier: identifier ?? MacUIAccessibility.identifier(prefix: "macui.action", label: title),
        label: title,
        role: .button
    )
    return (button, target)
}
