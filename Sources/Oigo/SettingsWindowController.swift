import AppKit
import OigoCore

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let keyCodeField = NSTextField(string: "")
    private let modifiersField = NSTextField(string: "")
    private let localePopup = NSPopUpButton()
    private let modePopup = NSPopUpButton()
    private let retentionPopup = NSPopUpButton()
    private let previewCheckbox = NSButton(checkboxWithTitle: "Show volatile transcript preview", target: nil, action: nil)
    private let keepAudioCheckbox = NSButton(checkboxWithTitle: "Keep successful audio indefinitely", target: nil, action: nil)
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Launch Oigo at login", target: nil, action: nil)
    private let microphoneStatus = NSTextField(labelWithString: "")
    private let accessibilityStatus = NSTextField(labelWithString: "")
    private let storageStatus = NSTextField(labelWithString: "")
    private var retryStorageButton: NSButton?
    private let messageLabel = NSTextField(labelWithString: "")
    private let save: (OigoSettings) -> String?
    private let refreshPermissions: () -> (OigoPermissionState, OigoPermissionState)
    private let openMicrophoneSettings: () -> Void
    private let openAccessibilitySettings: () -> Void
    private let rerunOnboarding: () -> Void
    private let openHistory: () -> Void
    private let openDataFolder: () -> Void
    private let retryStorage: () -> Void
    private let deleteAllHistory: () -> Void

    init(
        settings: OigoSettings,
        supportedLocales: [String],
        microphoneState: OigoPermissionState,
        accessibilityState: OigoPermissionState,
        storageHealth: DurableSessionHealth,
        save: @escaping (OigoSettings) -> String?,
        refreshPermissions: @escaping () -> (OigoPermissionState, OigoPermissionState),
        openMicrophoneSettings: @escaping () -> Void,
        openAccessibilitySettings: @escaping () -> Void,
        rerunOnboarding: @escaping () -> Void,
        openHistory: @escaping () -> Void,
        openDataFolder: @escaping () -> Void,
        retryStorage: @escaping () -> Void,
        deleteAllHistory: @escaping () -> Void
    ) {
        self.save = save
        self.refreshPermissions = refreshPermissions
        self.openMicrophoneSettings = openMicrophoneSettings
        self.openAccessibilitySettings = openAccessibilitySettings
        self.rerunOnboarding = rerunOnboarding
        self.openHistory = openHistory
        self.openDataFolder = openDataFolder
        self.retryStorage = retryStorage
        self.deleteAllHistory = deleteAllHistory

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Oigo Settings"
        window.minSize = NSSize(width: 520, height: 460)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        keyCodeField.stringValue = String(settings.globalShortcut.keyCode)
        modifiersField.stringValue = String(settings.globalShortcut.modifiers)
        localePopup.addItems(withTitles: supportedLocales)
        if let selectedIndex = supportedLocales.firstIndex(where: {
            $0.caseInsensitiveCompare(settings.localeIdentifier) == .orderedSame
        }) {
            localePopup.selectItem(at: selectedIndex)
        } else if !supportedLocales.isEmpty {
            localePopup.selectItem(at: 0)
        }
        modePopup.addItems(withTitles: OigoProcessingMode.allCases.map(\.displayName))
        modePopup.selectItem(withTitle: settings.defaultMode.displayName)
        retentionPopup.addItems(withTitles: OigoAudioRetention.allCases.map(\.displayName))
        retentionPopup.selectItem(withTitle: settings.audioRetention.displayName)
        previewCheckbox.state = settings.showVolatilePreview ? .on : .off
        keepAudioCheckbox.state = settings.keepSuccessfulAudioIndefinitely ? .on : .off
        launchAtLoginCheckbox.state = settings.launchAtLogin ? .on : .off
        updatePermissionLabels(microphone: microphoneState, accessibility: accessibilityState)
        configureWindow()
        setStorageHealth(storageHealth)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowDidBecomeKey(_ notification: Notification) {
        _ = notification
        let states = refreshPermissions()
        updatePermissionLabels(microphone: states.0, accessibility: states.1)
    }

    private func configureWindow() {
        guard let contentView = window?.contentView else {
            return
        }

        let title = NSTextField(labelWithString: "Minimal settings")
        title.font = .boldSystemFont(ofSize: 18)
        let description = NSTextField(
            wrappingLabelWithString: "Changes apply immediately after Save. Oigo only checks permissions when this window becomes active or when you refresh them."
        )
        description.textColor = .secondaryLabelColor

        let shortcutTitle = NSTextField(labelWithString: "Global shortcut")
        let keyCodeLabel = NSTextField(labelWithString: "Key code")
        let modifiersLabel = NSTextField(labelWithString: "Carbon modifiers")
        let shortcutHelp = NSTextField(wrappingLabelWithString: "Option-Space uses key code 49 and modifiers 2304. A conflicting shortcut is rejected and the previous working choice is kept.")
        shortcutHelp.textColor = .secondaryLabelColor
        let modeLabel = NSTextField(labelWithString: "Default mode")
        let localeLabel = NSTextField(labelWithString: "Dictation language")
        let retentionLabel = NSTextField(labelWithString: "Audio retention")

        let refreshButton = NSButton(title: "Refresh permission states", target: self, action: #selector(refreshPermissionStates))
        let microphoneSettingsButton = NSButton(title: "Open Microphone Settings", target: self, action: #selector(openMicrophoneSettingsAction))
        let accessibilitySettingsButton = NSButton(title: "Open Accessibility Settings", target: self, action: #selector(openAccessibilitySettingsAction))
        let retryStorageButton = NSButton(title: "Retry Storage", target: self, action: #selector(retryStorageAction))
        self.retryStorageButton = retryStorageButton
        let rerunButton = NSButton(title: "Re-run onboarding and permission checks", target: self, action: #selector(rerunOnboardingAction))
        let historyButton = NSButton(title: "Open History", target: self, action: #selector(openHistoryAction))
        let dataButton = NSButton(title: "Open Oigo data folder", target: self, action: #selector(openDataFolderAction))
        let deleteButton = NSButton(title: "Delete All History…", target: self, action: #selector(deleteAllHistoryAction))
        deleteButton.hasDestructiveAction = true
        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveSettings))
        saveButton.keyEquivalent = "\r"

        microphoneStatus.font = .systemFont(ofSize: 12)
        accessibilityStatus.font = .systemFont(ofSize: 12)
        storageStatus.font = .systemFont(ofSize: 12)
        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.maximumNumberOfLines = 2

        let shortcutGrid = NSGridView(views: [
            [shortcutTitle, NSGridCell.emptyContentView],
            [keyCodeLabel, keyCodeField],
            [modifiersLabel, modifiersField]
        ])
        shortcutGrid.rowSpacing = 8
        shortcutGrid.columnSpacing = 12
        shortcutGrid.translatesAutoresizingMaskIntoConstraints = false
        keyCodeField.placeholderString = "49"
        modifiersField.placeholderString = "2304"

        let modeRow = row(label: modeLabel, control: modePopup)
        let localeRow = row(label: localeLabel, control: localePopup)
        let retentionRow = row(label: retentionLabel, control: retentionPopup)
        let permissionsTitle = NSTextField(labelWithString: "Permissions")
        permissionsTitle.font = .boldSystemFont(ofSize: 13)
        let permissionStack = NSStackView(views: [microphoneStatus, microphoneSettingsButton, accessibilityStatus, accessibilitySettingsButton, refreshButton])
        permissionStack.orientation = .vertical
        permissionStack.alignment = .leading
        permissionStack.spacing = 6

        let storageStack = NSStackView(views: [storageStatus, retryStorageButton, dataButton])
        storageStack.orientation = .vertical
        storageStack.alignment = .leading
        storageStack.spacing = 6

        let actionStack = NSStackView(views: [rerunButton, historyButton, storageStack, deleteButton])
        actionStack.orientation = .vertical
        actionStack.alignment = .leading
        actionStack.spacing = 8

        let stack = NSStackView(views: [
            title,
            description,
            shortcutGrid,
            shortcutHelp,
            modeRow,
            localeRow,
            retentionRow,
            previewCheckbox,
            keepAudioCheckbox,
            launchAtLoginCheckbox,
            permissionsTitle,
            permissionStack,
            actionStack,
            messageLabel,
            saveButton
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -24),
            description.widthAnchor.constraint(equalTo: stack.widthAnchor),
            shortcutHelp.widthAnchor.constraint(equalTo: stack.widthAnchor),
            modeRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            localeRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            retentionRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            saveButton.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            keyCodeField.widthAnchor.constraint(equalToConstant: 180),
            modifiersField.widthAnchor.constraint(equalTo: keyCodeField.widthAnchor),
            localePopup.widthAnchor.constraint(equalToConstant: 260)
        ])
    }

    private func row(label: NSTextField, control: NSControl) -> NSStackView {
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        label.setContentHuggingPriority(.required, for: .horizontal)
        return row
    }

    private func updatePermissionLabels(
        microphone: OigoPermissionState,
        accessibility: OigoPermissionState
    ) {
        microphoneStatus.stringValue = "Microphone: " + microphone.rawValue.capitalized
        accessibilityStatus.stringValue = "Accessibility: " + accessibility.rawValue.capitalized + " (Copy and History remain available)"
    }

    func setStorageHealth(_ health: DurableSessionHealth) {
        storageStatus.stringValue = health.statusMessage
        let canRetry = !health.isReady
        storageStatus.textColor = canRetry ? .systemOrange : .secondaryLabelColor
        retryStorageButton?.isEnabled = canRetry && health != .checking
    }

    @objc private func refreshPermissionStates() {
        let states = refreshPermissions()
        updatePermissionLabels(microphone: states.0, accessibility: states.1)
        messageLabel.stringValue = "Permission states refreshed."
    }

    @objc private func openMicrophoneSettingsAction() {
        openMicrophoneSettings()
    }

    @objc private func openAccessibilitySettingsAction() {
        openAccessibilitySettings()
    }

    @objc private func rerunOnboardingAction() {
        window?.close()
        rerunOnboarding()
    }

    @objc private func openHistoryAction() {
        window?.close()
        openHistory()
    }

    @objc private func openDataFolderAction() {
        openDataFolder()
    }

    @objc private func retryStorageAction() {
        retryStorage()
    }

    @objc private func deleteAllHistoryAction() {
        let alert = NSAlert()
        alert.messageText = "Delete All History?"
        alert.informativeText = "This removes saved Oigo sessions, recordings, and transcripts. It does not touch future custom dictionary data."
        alert.addButton(withTitle: "Delete All History")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if let window = window {
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else {
                    return
                }
                self?.deleteAllHistory()
            }
        }
    }

    @objc private func saveSettings() {
        guard let keyCode = UInt32(keyCodeField.stringValue),
              let modifiers = UInt32(modifiersField.stringValue),
              let localeIdentifier = localePopup.selectedItem?.title,
              let modeTitle = modePopup.selectedItem?.title,
              let mode = OigoProcessingMode.allCases.first(where: { $0.displayName == modeTitle }),
              let retentionTitle = retentionPopup.selectedItem?.title,
              let retention = OigoAudioRetention.allCases.first(where: { $0.displayName == retentionTitle }) else {
            messageLabel.stringValue = "Enter a valid shortcut and choose a mode and retention duration."
            NSSound.beep()
            return
        }
        let result = save(OigoSettings(
            globalShortcut: ToggleShortcut(keyCode: keyCode, modifiers: modifiers),
            localeIdentifier: localeIdentifier,
            defaultMode: mode,
            showVolatilePreview: previewCheckbox.state == .on,
            audioRetention: retention,
            keepSuccessfulAudioIndefinitely: keepAudioCheckbox.state == .on,
            launchAtLogin: launchAtLoginCheckbox.state == .on
        ))
        if let result {
            messageLabel.stringValue = result
            NSSound.beep()
            return
        }
        window?.close()
    }
}
