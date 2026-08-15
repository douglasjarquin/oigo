import AppKit
import OigoCore

@MainActor
final class SettingsWindowController: NSWindowController {
    private let keyCodeField = NSTextField(string: "")
    private let modifiersField = NSTextField(string: "")
    private let save: (ToggleShortcut) -> Void

    init(shortcut: ToggleShortcut, save: @escaping (ToggleShortcut) -> Void) {
        self.save = save
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Oigo Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        keyCodeField.stringValue = String(shortcut.keyCode)
        modifiersField.stringValue = String(shortcut.modifiers)

        let contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        let keyLabel = NSTextField(labelWithString: "Key code")
        let modifiersLabel = NSTextField(labelWithString: "Carbon modifiers")
        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveShortcut))

        for view in [keyLabel, modifiersLabel, keyCodeField, modifiersField, saveButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        NSLayoutConstraint.activate([
            keyLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            keyLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            keyCodeField.leadingAnchor.constraint(equalTo: keyLabel.trailingAnchor, constant: 12),
            keyCodeField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            keyCodeField.centerYAnchor.constraint(equalTo: keyLabel.centerYAnchor),
            modifiersLabel.leadingAnchor.constraint(equalTo: keyLabel.leadingAnchor),
            modifiersLabel.topAnchor.constraint(equalTo: keyLabel.bottomAnchor, constant: 16),
            modifiersField.leadingAnchor.constraint(equalTo: modifiersLabel.trailingAnchor, constant: 12),
            modifiersField.trailingAnchor.constraint(equalTo: keyCodeField.trailingAnchor),
            modifiersField.centerYAnchor.constraint(equalTo: modifiersLabel.centerYAnchor),
            saveButton.trailingAnchor.constraint(equalTo: keyCodeField.trailingAnchor),
            saveButton.topAnchor.constraint(equalTo: modifiersField.bottomAnchor, constant: 20)
        ])
        window.contentView = contentView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func saveShortcut() {
        guard let keyCode = UInt32(keyCodeField.stringValue),
              let modifiers = UInt32(modifiersField.stringValue) else {
            NSSound.beep()
            return
        }
        save(ToggleShortcut(keyCode: keyCode, modifiers: modifiers))
        window?.close()
    }
}
