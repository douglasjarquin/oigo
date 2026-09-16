import AppKit
import OigoHotKey

@MainActor
final class OigoUtilityWindow: NSWindow {
    var onEscape: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let recorder = firstResponder as? ShortcutRecorderControl,
           recorder.performKeyEquivalent(with: event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        _ = sender
        if let onEscape {
            onEscape()
        } else {
            super.cancelOperation(sender)
        }
    }
}
