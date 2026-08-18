import AppKit
import OigoCore

@MainActor
public final class ShortcutRecorderControl: NSControl {
    public private(set) var shortcut: ToggleShortcut
    public private(set) var isRecording = false
    public private(set) var validationError: String?

    public var onCandidateChange: ((ToggleShortcut) -> Void)?
    public var onValidationError: ((String) -> Void)?

    private var shortcutBeforeRecording: ToggleShortcut

    public var displayValue: String {
        if isRecording {
            return "Press a shortcut"
        }
        return ShortcutFormatter.displayName(for: shortcut)
    }

    public override var acceptsFirstResponder: Bool {
        true
    }

    public init(shortcut: ToggleShortcut) {
        self.shortcut = shortcut
        self.shortcutBeforeRecording = shortcut
        super.init(frame: .zero)
        configureAppearance()
    }

    public required init?(coder: NSCoder) {
        self.shortcut = .default
        self.shortcutBeforeRecording = .default
        super.init(coder: coder)
        configureAppearance()
    }

    public func beginRecording() {
        shortcutBeforeRecording = shortcut
        validationError = nil
        isRecording = true
        needsDisplay = true
    }

    public func cancelRecording() {
        guard isRecording else {
            return
        }
        shortcut = shortcutBeforeRecording
        validationError = nil
        isRecording = false
        onCandidateChange?(shortcut)
        needsDisplay = true
    }

    public func restoreCandidate(_ shortcut: ToggleShortcut) {
        shortcutBeforeRecording = shortcut
        self.shortcut = shortcut
        validationError = nil
        isRecording = false
        needsDisplay = true
    }

    public override func mouseDown(with event: NSEvent) {
        _ = event
        if let window, !window.makeFirstResponder(self) {
            return
        }
        beginRecording()
    }

    public override func keyDown(with event: NSEvent) {
        guard isRecording else {
            return
        }

        guard !event.isARepeat else {
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let supportedFlags: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        guard flags.subtracting(supportedFlags).isEmpty else {
            reject("Choose only supported modifiers: Command, Shift, Option, or Control")
            return
        }

        if event.keyCode == 53, flags.isEmpty {
            cancelRecording()
            return
        }

        let modifiers = carbonModifiers(for: flags)
        let candidate = ToggleShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        switch OigoShortcutValidator.validate(candidate, occupied: []) {
        case .available:
            shortcut = candidate
            validationError = nil
            isRecording = false
            onCandidateChange?(candidate)
            needsDisplay = true
        case .conflict(let message), .invalid(let message):
            reject(message)
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        _ = dirtyRect
        let background = isRecording ? NSColor.selectedControlColor : NSColor.controlBackgroundColor
        background.setFill()
        bounds.insetBy(dx: 1, dy: 1).fill()

        NSColor.separatorColor.setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        border.lineWidth = 1
        border.stroke()

        let textColor = isRecording ? NSColor.selectedControlTextColor : NSColor.labelColor
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: textColor
        ]
        let text = NSString(string: displayValue)
        let size = text.size(withAttributes: attributes)
        let origin = NSPoint(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2
        )
        text.draw(at: origin, withAttributes: attributes)
    }

    private func configureAppearance() {
        wantsLayer = true
        toolTip = "Click to record a global shortcut"
    }

    private func carbonModifiers(for flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) {
            modifiers |= ToggleShortcutModifiers.command
        }
        if flags.contains(.control) {
            modifiers |= ToggleShortcutModifiers.control
        }
        if flags.contains(.option) {
            modifiers |= ToggleShortcutModifiers.option
        }
        if flags.contains(.shift) {
            modifiers |= ToggleShortcutModifiers.shift
        }
        return modifiers
    }

    private func reject(_ message: String) {
        validationError = message
        onValidationError?(message)
        needsDisplay = true
    }
}
