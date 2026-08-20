import AppKit
import OigoCore
import OigoHotKey

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let shortcutRecorder: ShortcutRecorderControl
    private let inputPopup = NSPopUpButton()
    private let channelPopup = NSPopUpButton()
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
    private let shortcutStatus = NSTextField(wrappingLabelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")
    private let registrationStatus: () -> GlobalShortcutRegistrationStatus
    private let registrationError: () -> String?
    private let save: (OigoSettings) -> String?
    private let checkSpeechAssets: (String) async -> OigoLocaleAssetStatus
    private let refreshPermissions: () -> (OigoPermissionState, OigoPermissionState)
    private let openMicrophoneSettings: () -> Void
    private let openAccessibilitySettings: () -> Void
    private let rerunOnboarding: () -> Void
    private let openHistory: () -> Void
    private let openDataFolder: () -> Void
    private let retryStorage: () -> Void
    private let deleteAllHistory: () -> Void
    private let isPresented: () -> Bool
    private let onClose: () -> Void
    private var committedShortcut: ToggleShortcut
    private var inputMenuSelections: [OigoInputSelection] = []
    private var selectedInput: OigoInputSelection
    private var selectedInputChannel: Int
    private var inputDevices: [OigoInputDevice]
    private var localeSelection: OigoLocaleSelectionState
    private var localeMenuIdentifiers: [String] = []
    private var isSaving = false
    private var isDismissed = false
    private var saveTask: Task<Void, Never>?
    private let nextDictationNotice = NSTextField(
        wrappingLabelWithString: NextDictationSettingsPolicy.nextDictationCopy
    )

    init(
        settings: OigoSettings,
        inputDevices: [OigoInputDevice],
        supportedLocales: [String],
        microphoneState: OigoPermissionState,
        accessibilityState: OigoPermissionState,
        storageHealth: DurableSessionHealth,
        registrationStatus: @escaping () -> GlobalShortcutRegistrationStatus,
        registrationError: @escaping () -> String?,
        save: @escaping (OigoSettings) -> String?,
        checkSpeechAssets: @escaping (String) async -> OigoLocaleAssetStatus,
        refreshPermissions: @escaping () -> (OigoPermissionState, OigoPermissionState),
        openMicrophoneSettings: @escaping () -> Void,
        openAccessibilitySettings: @escaping () -> Void,
        rerunOnboarding: @escaping () -> Void,
        openHistory: @escaping () -> Void,
        openDataFolder: @escaping () -> Void,
        retryStorage: @escaping () -> Void,
        deleteAllHistory: @escaping () -> Void,
        isPresented: @escaping () -> Bool,
        onClose: @escaping () -> Void
    ) {
        self.registrationStatus = registrationStatus
        self.registrationError = registrationError
        selectedInput = settings.selectedInput
        selectedInputChannel = settings.selectedInputChannel
        self.inputDevices = inputDevices
        self.save = save
        self.checkSpeechAssets = checkSpeechAssets
        self.refreshPermissions = refreshPermissions
        localeSelection = OigoLocaleSelectionState(
            committedIdentifier: settings.localeIdentifier,
            role: .settings
        )
        self.openMicrophoneSettings = openMicrophoneSettings
        self.openAccessibilitySettings = openAccessibilitySettings
        self.rerunOnboarding = rerunOnboarding
        self.openHistory = openHistory
        self.openDataFolder = openDataFolder
        self.retryStorage = retryStorage
        self.deleteAllHistory = deleteAllHistory
        self.isPresented = isPresented
        self.onClose = onClose
        committedShortcut = settings.globalShortcut
        shortcutRecorder = ShortcutRecorderControl(shortcut: settings.globalShortcut)

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
        configureInputMenu(devices: inputDevices, selected: selectedInput)
        configureChannelMenu()
        localePopup.autoenablesItems = false
        localeSelection.loadSupported(supportedLocales)
        syncLocalePopup()
        localePopup.target = self
        localePopup.action = #selector(localeSelectionChanged)
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
        updateShortcutStatus()
    }

    func windowWillClose(_ notification: Notification) {
        _ = notification
        saveTask?.cancel()
        saveTask = nil
        isSaving = false
        isDismissed = true
        localeSelection.abandonUncommitted()
        shortcutRecorder.cancelRecording()
        shortcutRecorder.restoreCandidate(committedShortcut)
        onClose()
    }

    func updateInputDevices(_ devices: [OigoInputDevice]) {
        selectedInput = selectedInputFromMenu()
        selectedInputChannel = selectedChannelFromMenu()
        inputDevices = devices
        configureInputMenu(devices: devices, selected: selectedInput)
        configureChannelMenu()
    }

    private func configureWindow() {
        guard let contentView = window?.contentView else {
            return
        }
        shortcutRecorder.onValidationError = { [weak self] message in
            self?.messageLabel.stringValue = message
        }

        let title = NSTextField(labelWithString: "Minimal settings")
        title.font = .boldSystemFont(ofSize: 18)
        let description = NSTextField(
            wrappingLabelWithString: "Changes apply immediately after Save. Oigo only checks permissions when this window becomes active or when you refresh them."
        )
        description.textColor = .secondaryLabelColor
        nextDictationNotice.textColor = .secondaryLabelColor
        nextDictationNotice.isHidden = true

        let shortcutTitle = NSTextField(labelWithString: "Global shortcut")
        let shortcutHelp = NSTextField(
            wrappingLabelWithString: "Click the recorder and press a shortcut. The default is \(ToggleShortcut.default.displayName). Validation never displaces the current working registration."
        )
        shortcutHelp.textColor = .secondaryLabelColor
        let modeLabel = NSTextField(labelWithString: "Default mode")
        let localeLabel = NSTextField(labelWithString: "Dictation language")
        let retentionLabel = NSTextField(labelWithString: "Audio retention")
        let inputLabel = NSTextField(labelWithString: "Microphone input")
        let channelLabel = NSTextField(labelWithString: "Input channel")

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

        let shortcutRow = NSStackView(views: [shortcutTitle, shortcutRecorder])
        shortcutRow.orientation = .horizontal
        shortcutRow.alignment = .centerY
        shortcutRow.spacing = 12
        shortcutRow.translatesAutoresizingMaskIntoConstraints = false
        shortcutRecorder.widthAnchor.constraint(equalToConstant: 280).isActive = true

        let modeRow = row(label: modeLabel, control: modePopup)
        let localeRow = row(label: localeLabel, control: localePopup)
        let retentionRow = row(label: retentionLabel, control: retentionPopup)
        let inputRow = row(label: inputLabel, control: inputPopup)
        let channelRow = row(label: channelLabel, control: channelPopup)
        inputPopup.target = self
        inputPopup.action = #selector(inputSelectionChanged)
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
            nextDictationNotice,
            shortcutRow,
            shortcutHelp,
            shortcutStatus,
            inputRow,
            channelRow,
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
            nextDictationNotice.widthAnchor.constraint(equalTo: stack.widthAnchor),
            shortcutHelp.widthAnchor.constraint(equalTo: stack.widthAnchor),
            modeRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            localeRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            retentionRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            inputRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            channelRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            saveButton.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            localePopup.widthAnchor.constraint(equalToConstant: 260),
            inputPopup.widthAnchor.constraint(equalTo: localePopup.widthAnchor),
            channelPopup.widthAnchor.constraint(equalTo: localePopup.widthAnchor)
        ])
        updateShortcutStatus()
    }

    private func configureInputMenu(
        devices: [OigoInputDevice],
        selected: OigoInputSelection
    ) {
        let items = OigoInputMenu.items(devices: devices, selected: selected)
        inputMenuSelections = items.map(\.selection)
        inputPopup.removeAllItems()
        inputPopup.addItems(withTitles: items.map(\.title))
        if let selectedIndex = items.firstIndex(where: { $0.selection == selected }) {
            inputPopup.selectItem(at: selectedIndex)
        }
    }

    private func configureChannelMenu() {
        let channelCount = OigoInputChannelPolicy.channelCount(
            for: selectedInput,
            devices: inputDevices
        )
        if !OigoInputChannelPolicy.isValid(selectedInputChannel, channelCount: channelCount) {
            selectedInputChannel = OigoInputChannelPolicy.defaultIndex
        }
        channelPopup.removeAllItems()
        channelPopup.addItems(
            withTitles: (0..<channelCount).map(OigoInputChannelPolicy.displayTitle(for:))
        )
        if selectedInputChannel < channelCount {
            channelPopup.selectItem(at: selectedInputChannel)
        }
    }

    private func selectedInputFromMenu() -> OigoInputSelection {
        let index = inputPopup.indexOfSelectedItem
        guard inputMenuSelections.indices.contains(index) else {
            return .systemDefault
        }
        return inputMenuSelections[index]
    }

    private func selectedChannelFromMenu() -> Int {
        max(OigoInputChannelPolicy.defaultIndex, channelPopup.indexOfSelectedItem)
    }

    @objc private func inputSelectionChanged() {
        selectedInput = selectedInputFromMenu()
        selectedInputChannel = selectedChannelFromMenu()
        configureChannelMenu()
    }

    private func syncLocalePopup() {
        let items = localeSelection.menuItems
        localeMenuIdentifiers = items.map(\.identifier)
        localePopup.removeAllItems()
        localePopup.addItems(withTitles: items.map(\.title))
        for (index, item) in items.enumerated() {
            localePopup.item(at: index)?.isEnabled = !item.isUnavailable
        }
        if let selected = localeSelection.selectedIdentifier,
           let index = items.firstIndex(where: { $0.identifier == selected }) {
            localePopup.selectItem(at: index)
        }
    }

    @objc private func localeSelectionChanged() {
        guard let identifier = selectedLocaleFromMenu() else {
            return
        }
        localeSelection.select(identifier)
        messageLabel.stringValue = localeSelection.statusMessage
    }

    private func selectedLocaleFromMenu() -> String? {
        let index = localePopup.indexOfSelectedItem
        guard localeMenuIdentifiers.indices.contains(index) else {
            return nil
        }
        return localeMenuIdentifiers[index]
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

    func setAppliesToNextDictation(_ applies: Bool) {
        nextDictationNotice.isHidden = !applies
    }

    func setStorageHealth(_ health: DurableSessionHealth) {
        storageStatus.stringValue = health.statusMessage
        let canRetry = !health.isReady
        storageStatus.textColor = canRetry ? .systemOrange : .secondaryLabelColor
        retryStorageButton?.isEnabled = canRetry && health != .checking
    }

    private func updateShortcutStatus() {
        switch registrationStatus() {
        case .active(let shortcut, _):
            let suffix = registrationError().map { ". Last error: " + $0 } ?? ""
            shortcutStatus.stringValue = "Registration active: " + shortcut.displayName + suffix
        case .inactive(let message):
            shortcutStatus.stringValue = "Registration inactive: " + (registrationError() ?? message)
        }
    }

    @objc private func refreshPermissionStates() {
        let states = refreshPermissions()
        updatePermissionLabels(microphone: states.0, accessibility: states.1)
        updateShortcutStatus()
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
        guard !isSaving else {
            return
        }
        guard let modeTitle = modePopup.selectedItem?.title,
              let mode = OigoProcessingMode.allCases.first(where: { $0.displayName == modeTitle }),
              let retentionTitle = retentionPopup.selectedItem?.title,
              let retention = OigoAudioRetention.allCases.first(where: { $0.displayName == retentionTitle }) else {
            messageLabel.stringValue = "Enter a valid shortcut and choose a mode and retention duration."
            NSSound.beep()
            return
        }
        let candidate = shortcutRecorder.shortcut
        let draft = OigoSettings(
            globalShortcut: candidate,
            localeIdentifier: localeSelection.committedIdentifier,
            defaultMode: mode,
            showVolatilePreview: previewCheckbox.state == .on,
            audioRetention: retention,
            keepSuccessfulAudioIndefinitely: keepAudioCheckbox.state == .on,
            launchAtLogin: launchAtLoginCheckbox.state == .on,
            selectedInput: selectedInputFromMenu(),
            selectedInputChannel: selectedChannelFromMenu()
        )
        guard localeSelection.requiresVerificationToCommit else {
            _ = finishSave(draft, languageUnappliedMessage: nil)
            return
        }
        guard let request = localeSelection.beginAssetRequest(status: .installing) else {
            messageLabel.stringValue = localeSelection.statusMessage
            NSSound.beep()
            return
        }
        isSaving = true
        messageLabel.stringValue = localeSelection.statusMessage
        let inspectAssets = checkSpeechAssets
        saveTask = Task { @MainActor [weak self] in
            let status = await inspectAssets(request.localeIdentifier)
            guard let self else { return }
            defer { self.saveTask = nil }
            guard !Task.isCancelled, !isDismissed, isPresented() else {
                return
            }
            let applied = localeSelection.applyAssetResult(
                localeIdentifier: request.localeIdentifier,
                generation: request.generation,
                status: status
            )
            isSaving = false
            if applied,
               localeSelection.canConfirm,
               let locale = localeSelection.selectedIdentifier {
                let saved = finishSave(
                    draft.with(localeIdentifier: locale),
                    languageUnappliedMessage: nil
                )
                if saved {
                    _ = localeSelection.confirm()
                }
                return
            }
            let reason = applied
                ? localeSelection.statusMessage
                : "the selected language is no longer current"
            if applied {
                localeSelection.abandonUncommitted()
                syncLocalePopup()
            }
            _ = finishSave(
                draft,
                languageUnappliedMessage: "Settings saved. Dictation language was not changed: " + reason
            )
        }
    }

    @discardableResult
    private func finishSave(_ settings: OigoSettings, languageUnappliedMessage: String?) -> Bool {
        guard !isDismissed, isPresented() else {
            return false
        }
        let result = save(settings)
        if let result {
            messageLabel.stringValue = result
            updateShortcutStatus()
            NSSound.beep()
            return false
        }
        committedShortcut = settings.globalShortcut
        if let languageUnappliedMessage {
            messageLabel.stringValue = languageUnappliedMessage
            NSSound.beep()
            return true
        }
        window?.close()
        return true
    }
}
