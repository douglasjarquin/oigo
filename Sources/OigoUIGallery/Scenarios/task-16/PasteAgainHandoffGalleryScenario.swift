import AppKit
import MacUtilityUI

@MainActor
final class PasteAgainHandoffGalleryScenario: GalleryScenario {
    override class var scenarioName: String { "paste-again-handoff" }

    override class func makeWindow(configuration: GalleryConfiguration) -> NSWindow {
        _ = configuration
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Paste Again Handoff - Synthetic Gallery"
        window.isReleasedWhenClosed = false
        window.contentViewController = PasteAgainHandoffGalleryViewController()
        return window
    }
}

@MainActor
private final class PasteAgainHandoffGalleryViewController: NSViewController {
    private let destination = NSTextField(string: "Synthetic destination")
    private let result = NSTextField(labelWithString: "Terminal category: pending")
    private var hud: MacUIFloatingPanel?

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    override func loadView() {
        let title = NSTextField(labelWithString: "Choose a destination")
        title.font = .systemFont(ofSize: 22, weight: .semibold)

        destination.setAccessibilityLabel("Synthetic Paste Again destination")
        destination.identifier = NSUserInterfaceItemIdentifier("task16.synthetic.destination")

        let resolve = NSButton(
            title: "Resolve synthetic handoff",
            target: self,
            action: #selector(resolveHandoff)
        )
        resolve.setAccessibilityLabel("Resolve synthetic Paste Again handoff")

        result.textColor = .secondaryLabelColor
        result.setAccessibilityLabel("Synthetic terminal category")

        let stack = NSStackView(views: [title, destination, resolve, result])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            destination.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        root.setAccessibilityRole(.group)
        root.setAccessibilityLabel("Synthetic Paste Again lifecycle gallery")
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        destination.window?.makeFirstResponder(destination)
        showDestinationHUD()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        hud?.terminalize()
        hud = nil
    }

    @objc private func resolveHandoff() {
        result.stringValue = "Terminal category: paste-attempted"
        hud?.terminalize()
        hud = nil
        destination.window?.makeFirstResponder(destination)
    }

    private func showDestinationHUD() {
        hud?.terminalize()
        let panel = MacUIFloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 64)
        )
        let label = NSTextField(labelWithString: "Choose a destination")
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 64))
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])
        panel.contentView = content
        if let window = view.window {
            panel.setFrameOrigin(NSPoint(x: window.frame.midX - 140, y: window.frame.minY + 28))
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        hud = panel
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}
