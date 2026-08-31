import AppKit

@MainActor
final class OigoUtilityWindow: NSWindow {
    var onEscape: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        _ = sender
        if let onEscape {
            onEscape()
        } else {
            super.cancelOperation(sender)
        }
    }
}
