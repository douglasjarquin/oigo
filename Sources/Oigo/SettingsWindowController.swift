import AppKit
import OigoCore
import OigoTranscription

@MainActor
final class SettingsWindowController: NSWindowController {
    private let keyCodeField = NSTextField(string: "")
    private let modifiersField = NSTextField(string: "")
    private let cleanupModePopup = NSPopUpButton()
    private let save: (ToggleShortcut, TranscriptCleanupMode) -> Void

    init(
        shortcut: ToggleShortcut,
        cleanupMode: TranscriptCleanupMode,
        save: @escaping (ToggleShortcut, TranscriptCleanupMode) -> Void
    ) {
        self.save = save
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 190),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Oigo Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        keyCodeField.stringValue = String(shortcut.keyCode)
        modifiersField.stringValue = String(shortcut.modifiers)
        cleanupModePopup.addItems(withTitles: TranscriptCleanupMode.allCases.map(\.displayName))
        cleanupModePopup.selectItem(withTitle: cleanupMode.displayName)

        let contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        let keyLabel = NSTextField(labelWithString: "Key code")
        let modifiersLabel = NSTextField(labelWithString: "Carbon modifiers")
        let cleanupModeLabel = NSTextField(labelWithString: "Transcript mode")
        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveShortcut))

        for view in [
            keyLabel,
            modifiersLabel,
            cleanupModeLabel,
            keyCodeField,
            modifiersField,
            cleanupModePopup,
            saveButton
        ] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        NSLayoutConstraint.activate([
            keyLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            keyLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            keyCodeField.leadingAnchor.constraint(equalTo: cleanupModeLabel.trailingAnchor, constant: 12),
            keyCodeField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            keyCodeField.centerYAnchor.constraint(equalTo: keyLabel.centerYAnchor),
            modifiersLabel.leadingAnchor.constraint(equalTo: keyLabel.leadingAnchor),
            modifiersLabel.topAnchor.constraint(equalTo: keyLabel.bottomAnchor, constant: 16),
            modifiersField.leadingAnchor.constraint(equalTo: keyCodeField.leadingAnchor),
            modifiersField.trailingAnchor.constraint(equalTo: keyCodeField.trailingAnchor),
            modifiersField.centerYAnchor.constraint(equalTo: modifiersLabel.centerYAnchor),
            cleanupModeLabel.leadingAnchor.constraint(equalTo: keyLabel.leadingAnchor),
            cleanupModeLabel.topAnchor.constraint(equalTo: modifiersLabel.bottomAnchor, constant: 16),
            cleanupModePopup.leadingAnchor.constraint(equalTo: keyCodeField.leadingAnchor),
            cleanupModePopup.trailingAnchor.constraint(equalTo: keyCodeField.trailingAnchor),
            cleanupModePopup.centerYAnchor.constraint(equalTo: cleanupModeLabel.centerYAnchor),
            saveButton.trailingAnchor.constraint(equalTo: keyCodeField.trailingAnchor),
            saveButton.topAnchor.constraint(equalTo: cleanupModePopup.bottomAnchor, constant: 20)
        ])
        window.contentView = contentView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func saveShortcut() {
        guard let keyCode = UInt32(keyCodeField.stringValue),
              let modifiers = UInt32(modifiersField.stringValue),
              let selectedMode = cleanupModePopup.selectedItem?.title,
              let cleanupMode = TranscriptCleanupMode.allCases.first(where: {
                  $0.displayName == selectedMode
              }) else {
            NSSound.beep()
            return
        }
        save(ToggleShortcut(keyCode: keyCode, modifiers: modifiers), cleanupMode)
        window?.close()
    }
}
