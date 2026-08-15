import AppKit
import OigoCore

@MainActor
final class StatusSurfaceController {
    private let panel: NSPanel
    private let label: NSTextField

    init() {
        label = NSTextField(labelWithString: "Oigo: Idle")
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 48),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = true

        let contentView = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        contentView.layer?.cornerRadius = 10
        contentView.addSubview(label)

        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
        panel.contentView = contentView
        panel.orderOut(nil)
    }

    func show(state: DictationState, anchoredTo button: NSStatusBarButton?) {
        label.stringValue = "Oigo: " + state.rawValue.capitalized
        if let button, let window = button.window {
            let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
            let origin = NSPoint(
                x: buttonFrame.midX - (panel.frame.width / 2),
                y: buttonFrame.minY - panel.frame.height - 8
            )
            panel.setFrameOrigin(origin)
        }
        panel.orderFront(nil)
    }
}
