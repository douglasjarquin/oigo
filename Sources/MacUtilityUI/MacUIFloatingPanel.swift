import AppKit

@MainActor
public final class MacUIFloatingPanel: NSPanel {
    public override var canBecomeKey: Bool {
        false
    }

    public override var canBecomeMain: Bool {
        false
    }

    public init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    public func terminalize() {
        orderOut(nil)
        contentView = nil
    }

    public func shutdown() {
        terminalize()
    }
}
