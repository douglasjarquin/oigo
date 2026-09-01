import AppKit

final class QATargetDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
        let identifier = Bundle.main.object(forInfoDictionaryKey: "OigoQATargetFieldIdentifier") as? String ?? ""
        let field = NSTextField(frame: NSRect(x: 24, y: 54, width: 432, height: 28))
        field.identifier = NSUserInterfaceItemIdentifier(identifier)
        field.setAccessibilityIdentifier(identifier)
        field.placeholderString = "Synthetic QA field"

        let label = NSTextField(labelWithString: "Oigo disposable QA target")
        label.frame = NSRect(x: 24, y: 98, width: 432, height: 24)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 150))
        content.addSubview(label)
        content.addSubview(field)

        let window = NSWindow(
            contentRect: content.bounds,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Oigo QA Target"
        window.contentView = content
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(field)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.regular)
let delegate = QATargetDelegate()
application.delegate = delegate
application.run()
