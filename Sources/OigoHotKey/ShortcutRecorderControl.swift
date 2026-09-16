import AppKit
import OigoCore

@MainActor
public final class ShortcutRecorderControl: NSControl {
    public private(set) var shortcut: ToggleShortcut
    public private(set) var isRecording = false
    public private(set) var validationError: String?

    public var onCandidateChange: ((ToggleShortcut) -> Void)?
    public var onValidationError: ((String) -> Void)?
    public var onRecordingChange: ((Bool) throws -> Void)?

    private var shortcutBeforeRecording: ToggleShortcut

    public var displayValue: String {
        if isRecording {
            return "Press a shortcut"
        }
        return ShortcutFormatter.displayName(for: shortcut)
    }

    public override var acceptsFirstResponder: Bool {
        isEnabled
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
        guard isEnabled, !isRecording else {
            return
        }
        if let window, window.firstResponder !== self, !window.makeFirstResponder(self) {
            return
        }
        shortcutBeforeRecording = shortcut
        validationError = nil
        do {
            try onRecordingChange?(true)
        } catch {
            reject(String(describing: error))
            return
        }
        isRecording = true
        updatePresentation()
    }

    public func cancelRecording() {
        guard isRecording else {
            return
        }
        shortcut = shortcutBeforeRecording
        validationError = nil
        isRecording = false
        finishRecording()
        updatePresentation()
    }

    public func clearShortcut() {
        cancelRecording()
        shortcutBeforeRecording = .default
        shortcut = .default
        validationError = nil
        isRecording = false
        onCandidateChange?(shortcut)
        sendAction(action, to: target)
        updatePresentation()
    }

    public func restoreCandidate(_ shortcut: ToggleShortcut) {
        cancelRecording()
        shortcutBeforeRecording = shortcut
        self.shortcut = shortcut
        validationError = nil
        isRecording = false
        updatePresentation()
    }

    public override func mouseDown(with event: NSEvent) {
        _ = event
        guard isEnabled else {
            return
        }
        beginRecording()
    }

    public override func accessibilityPerformPress() -> Bool {
        guard isEnabled else {
            return false
        }
        beginRecording()
        return isRecording
    }

    public override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else {
            return false
        }
        cancelRecording()
        return true
    }

    public override func cancelOperation(_ sender: Any?) {
        _ = sender
        cancelRecording()
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        cancelRecording()
        if let window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
            NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window)
        }
        if let newWindow {
            for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowEndedRecording(_:)), name: name, object: newWindow)
            }
        }
        super.viewWillMove(toWindow: newWindow)
    }

    @objc private func windowEndedRecording(_ notification: Notification) {
        cancelRecording()
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return false }
        keyDown(with: event)
        return true
    }

    public override func flagsChanged(with event: NSEvent) {
        guard isRecording, event.keyCode == ToggleShortcut.fnKeyCode else {
            super.flagsChanged(with: event)
            return
        }
        guard event.modifierFlags.contains(.function) else { return }
        let otherModifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        capture(ToggleShortcut(keyCode: ToggleShortcut.fnKeyCode, modifiers: carbonModifiers(for: otherModifiers)))
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
        capture(candidate)
    }

    private func capture(_ candidate: ToggleShortcut) {
        switch OigoShortcutValidator.validate(candidate, occupied: []) {
        case .available:
            shortcut = candidate
            validationError = nil
            isRecording = false
            onCandidateChange?(candidate)
            sendAction(action, to: target)
            finishRecording()
            updatePresentation()
        case .conflict(let message), .invalid(let message):
            reject(message)
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        _ = dirtyRect
        let background: NSColor
        if isRecording {
            background = NSColor.selectedControlColor
        } else if isEnabled {
            background = NSColor.controlBackgroundColor
        } else {
            background = NSColor.controlBackgroundColor.withAlphaComponent(0.55)
        }
        background.setFill()
        bounds.insetBy(dx: 1, dy: 1).fill()

        let borderColor = isEnabled ? NSColor.separatorColor : NSColor.disabledControlTextColor
        borderColor.setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        border.lineWidth = 1
        border.stroke()

        let textColor: NSColor
        if isRecording {
            textColor = NSColor.selectedControlTextColor
        } else if isEnabled {
            textColor = NSColor.labelColor
        } else {
            textColor = NSColor.disabledControlTextColor
        }
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
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Global shortcut")
        updatePresentation()
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
        updatePresentation()
    }

    private func finishRecording() {
        do {
            try onRecordingChange?(false)
        } catch {
            reject(String(describing: error))
        }
    }

    private func updatePresentation() {
        setAccessibilityValue(displayValue)
        needsDisplay = true
    }
}
