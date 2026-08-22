import AppKit

@MainActor
final class Task01SmokeGalleryScenario: GalleryScenario {
    override class var scenarioName: String {
        "smoke"
    }

    override class func makeWindow(configuration: GalleryConfiguration) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Oigo UI Gallery"
        window.isReleasedWhenClosed = false
        window.center()

        let label = NSTextField(labelWithString: "Synthetic smoke scenario")
        label.font = .systemFont(ofSize: 18, weight: .semibold)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityLabel("Synthetic smoke scenario")

        let detail = NSTextField(labelWithString: "No production data or permissions")
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.setAccessibilityLabel("No production data or permissions")

        let stack = NSStackView(views: [label, detail])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let contentView = NSView()
        contentView.addSubview(stack)
        window.contentView = contentView
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
        return window
    }
}
