import AppKit

@MainActor
public enum MacUIDestructiveConfirmation {
    public static func makeAlert(
        title: String,
        message: String,
        confirmTitle: String,
        cancelTitle: String = "Cancel"
    ) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = message
        let confirmButton = alert.addButton(withTitle: confirmTitle)
        confirmButton.hasDestructiveAction = true
        confirmButton.setAccessibilityIdentifier("macui.destructive-confirm")
        confirmButton.setAccessibilityLabel(confirmTitle)
        let cancelButton = alert.addButton(withTitle: cancelTitle)
        cancelButton.setAccessibilityIdentifier("macui.destructive-cancel")
        cancelButton.setAccessibilityLabel(cancelTitle)
        return alert
    }

    public static func beginSheet(
        for window: NSWindow,
        title: String,
        message: String,
        confirmTitle: String,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        let alert = makeAlert(title: title, message: message, confirmTitle: confirmTitle)
        alert.beginSheetModal(for: window) { response in
            completion(response == .alertFirstButtonReturn)
        }
    }
}
