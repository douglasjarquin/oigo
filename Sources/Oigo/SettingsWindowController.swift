import AppKit
import UniformTypeIdentifiers
import OigoCore
import OigoHotKey
import MacUtilityUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private static let selectedPaneKey = "oigo.settings.selected-pane"
    private static let shellWidth: CGFloat = 720
    private static let paneHorizontalPadding: CGFloat = 40
    private static let paneTopPadding: CGFloat = 22
    private static let paneBottomPadding: CGFloat = 28
    private static let paneTransitionDuration: TimeInterval = 0.12

    private static func iconName(for pane: OigoSettingsPane) -> String {
        switch pane {
        case .general:
            "gearshape"
        case .dictation:
            "waveform"
        case .dictionary:
            "text.book.closed"
        case .dataPrivacy:
            "lock.shield"
        }
    }
    private let paneContainer = NSView()
    private var paneViews: [OigoSettingsPane: NSView] = [:]
    private var selectedPane: OigoSettingsPane
    var committedSettings: OigoSettings
    private let shortcutRecorder: ShortcutRecorderControl
    private let loadSupportedLocales: () async -> [String]
    private let inputPopup = NSPopUpButton()
    private let channelPopup = NSPopUpButton()
    private let localePopup = NSPopUpButton()
    private let modePopup = NSPopUpButton()
    private let retentionPopup = NSPopUpButton()
    private let previewCheckbox = NSButton(checkboxWithTitle: "Show volatile transcript preview", target: nil, action: nil)
    private let keepAudioCheckbox = NSButton(checkboxWithTitle: "Keep successful audio indefinitely", target: nil, action: nil)
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Launch Oigo at login", target: nil, action: nil)
    private let launchAtLoginStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let openLoginItemsButton = NSButton(title: "Open Login Items", target: nil, action: nil)
    private let microphoneStatus = NSTextField(labelWithString: "")
    private let accessibilityStatus = NSTextField(labelWithString: "")
    private let storageStatus = NSTextField(labelWithString: "")
    private var retryStorageButton: NSButton?
    private let shortcutStatus = NSTextField(wrappingLabelWithString: "")
    private let shortcutHelp = NSTextField(wrappingLabelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    let dictationMessage = NSTextField(wrappingLabelWithString: "")
    private let registrationStatus: () -> GlobalShortcutRegistrationStatus
    private let registrationError: () -> String?
    private let validateShortcut: (ToggleShortcut) -> OigoShortcutValidation
    private let saveShortcut: (ToggleShortcut) -> OigoShortcutValidation
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
    private let exportDiagnostics: () throws -> Data
    private let saveDictionary: (DictionaryDocument) -> String?
    private let previewDictionary: (String) -> String
    private let addStarterTerms: () -> (DictionaryDocument, String?)
    var dictionaryEntries: [DictionaryEntry]
    private var committedDictionaryEntries: [DictionaryEntry]
    private let dictionaryTable = NSTableView()
    private let dictionarySearch = NSSearchField()
    private let canonicalField = NSTextField()
    private let dictionaryLocale = NSPopUpButton()
    private let dictionaryEnabled = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    private let aliasStack = NSStackView()
    private let addAliasButton = NSButton(title: "+ Add Alias", target: nil, action: nil)
    private let removeTermButton = NSButton(title: "−", target: nil, action: nil)
    private var editingDictionaryEntry: DictionaryEntry?
    private var visibleDictionaryEntries: [DictionaryEntry] = []
    private var refreshingDictionary = false
    private let dictionaryMessage = NSTextField(wrappingLabelWithString: "")
    private let sampleField = NSTextField()
    private let previewLabel = NSTextField(wrappingLabelWithString: "")
    private let launchAtLoginStatusProvider: () -> OigoLaunchAtLoginStatus
    private let openLoginItemsSettings: () -> Void
    private let isPresented: () -> Bool
    private let onClose: () -> Void
    private var committedShortcut: ToggleShortcut
    private var committedShortcutCopy: OigoShortcutCopy {
        committedShortcut.copy
    }
    private var inputMenuSelections: [OigoInputSelection] = []
    private var selectedInput: OigoInputSelection
    private var selectedInputChannel: Int
    private var inputDevices: [OigoInputDevice]
    var localeSelection: OigoLocaleSelectionState
    private var localeMenuIdentifiers: [String] = []
    var isCheckingLocale = false
    private var isDismissed = false
    private var saveTask: Task<Void, Never>?
    private var localeLoadTask: Task<Void, Never>?
    private var hasLoadedSupportedLocales = false
    private let nextDictationNotice = NSTextField(
        wrappingLabelWithString: NextDictationSettingsPolicy.nextDictationCopy
    )
    private var lastRequestedLaunchAtLogin: Bool
    private var currentLaunchAtLoginStatus: OigoLaunchAtLoginStatus

    init(
        settings: OigoSettings,
        inputDevices: [OigoInputDevice],
        supportedLocales: [String],
        loadSupportedLocales: @escaping () async -> [String],
        microphoneState: OigoPermissionState,
        accessibilityState: OigoPermissionState,
        storageHealth: DurableSessionHealth,
        launchAtLoginStatus: OigoLaunchAtLoginStatus,
        launchAtLoginStatusProvider: @escaping () -> OigoLaunchAtLoginStatus,
        openLoginItemsSettings: @escaping () -> Void,
        registrationStatus: @escaping () -> GlobalShortcutRegistrationStatus,
        registrationError: @escaping () -> String?,
        setShortcutRecording: @escaping (Bool) throws -> Void = { _ in },
        validateShortcut: @escaping (ToggleShortcut) -> OigoShortcutValidation,
        saveShortcut: @escaping (ToggleShortcut) -> OigoShortcutValidation,
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
        exportDiagnostics: @escaping () throws -> Data,
        dictionaryDocument: DictionaryDocument,
        saveDictionary: @escaping (DictionaryDocument) -> String?,
        previewDictionary: @escaping (String) -> String,
        addStarterTerms: @escaping () -> (DictionaryDocument, String?),
        isPresented: @escaping () -> Bool,
        onClose: @escaping () -> Void
    ) {
        self.registrationStatus = registrationStatus
        self.registrationError = registrationError
        self.validateShortcut = validateShortcut
        self.saveShortcut = saveShortcut
        committedSettings = settings
        self.loadSupportedLocales = loadSupportedLocales
        selectedPane = OigoSettingsPane(
            rawValue: UserDefaults.standard.string(forKey: Self.selectedPaneKey) ?? ""
        ) ?? .general
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
        self.exportDiagnostics = exportDiagnostics
        self.saveDictionary = saveDictionary
        self.previewDictionary = previewDictionary
        self.addStarterTerms = addStarterTerms
        dictionaryEntries = dictionaryDocument.entries
        committedDictionaryEntries = dictionaryDocument.entries
        self.launchAtLoginStatusProvider = launchAtLoginStatusProvider
        self.openLoginItemsSettings = openLoginItemsSettings
        self.isPresented = isPresented
        self.onClose = onClose
        lastRequestedLaunchAtLogin = settings.launchAtLogin
        currentLaunchAtLoginStatus = launchAtLoginStatus
        committedShortcut = settings.globalShortcut
        shortcutRecorder = ShortcutRecorderControl(shortcut: settings.globalShortcut)
        shortcutRecorder.isEnabled = true
        shortcutRecorder.toolTip = settings.globalShortcut.copy.settingsHint
        shortcutRecorder.setAccessibilityLabel("Dictation shortcut")
        shortcutRecorder.identifier = NSUserInterfaceItemIdentifier("oigo.settings.shortcut-recorder")
        shortcutRecorder.setAccessibilityIdentifier("oigo.settings.shortcut-recorder")
        shortcutHelp.setAccessibilityIdentifier("oigo.settings.shortcut-help")
        shortcutStatus.setAccessibilityIdentifier("oigo.settings.shortcut-status")

        let window = OigoUtilityWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.shellWidth, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Oigo Settings"
        window.minSize = NSSize(width: Self.shellWidth, height: 520)
        window.identifier = NSUserInterfaceItemIdentifier("com.oigo.settings.window")
        window.setFrameAutosaveName("Oigo.SettingsWindow")
        window.isRestorable = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        shortcutRecorder.onRecordingChange = { [weak self] recording in
            defer {
                if !recording { self?.updateShortcutStatus() }
            }
            try setShortcutRecording(recording)
        }
        window.delegate = self
        window.onEscape = { [weak self] in
            guard let self else { return }
            var available: Set<OigoEscapeAction> = [.closeUtilityWindow]
            if shortcutRecorder.isRecording { available.insert(.cancelEditor) }
            if isCheckingLocale { available.insert(.cancelBoundedHandoff) }
            switch OigoUIIntegrationPolicy.resolveEscapeAction(from: available) {
            case .cancelEditor:
                shortcutRecorder.cancelRecording()
            case .cancelBoundedHandoff:
                cancelLocaleWork()
            default:
                self.window?.performClose(nil)
            }
        }
        configureToolbar()
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
        modePopup.target = self
        modePopup.action = #selector(commitChangedSettings)
        retentionPopup.target = self
        retentionPopup.action = #selector(commitChangedSettings)
        previewCheckbox.target = self
        previewCheckbox.action = #selector(commitChangedSettings)
        keepAudioCheckbox.target = self
        keepAudioCheckbox.action = #selector(commitChangedSettings)
        launchAtLoginCheckbox.target = self
        launchAtLoginCheckbox.action = #selector(commitChangedSettings)
        shortcutRecorder.onCandidateChange = { [weak self] candidate in
            self?.commitShortcut(candidate)
        }
        updatePermissionLabels(microphone: microphoneState, accessibility: accessibilityState)
        configureWindow()
        setStorageHealth(storageHealth)
        setLaunchAtLoginStatus(launchAtLoginStatus)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureToolbar() {
        let toolbar = NSToolbar(identifier: "oigo.settings.toolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsDisplayModeCustomization = false
        toolbar.centeredItemIdentifiers = Set(toolbarAllowedItemIdentifiers(toolbar))
        toolbar.selectedItemIdentifier = NSToolbarItem.Identifier(selectedPane.rawValue)
        window?.toolbar = toolbar
        window?.toolbarStyle = .preference
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        _ = toolbar
        return OigoSettingsPane.allCases.map { NSToolbarItem.Identifier($0.rawValue) }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        _ = toolbar
        _ = flag
        guard let pane = OigoSettingsPane(rawValue: itemIdentifier.rawValue) else {
            return nil
        }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = pane.title
        item.paletteLabel = pane.title
        item.toolTip = pane.title + " settings"
        item.image = NSImage(
            systemSymbolName: Self.iconName(for: pane),
            accessibilityDescription: pane.title
        )
        item.target = self
        item.action = #selector(selectToolbarPane(_:))
        return item
    }

    @objc private func selectToolbarPane(_ sender: NSToolbarItem) {
        guard let pane = OigoSettingsPane(rawValue: sender.itemIdentifier.rawValue) else {
            return
        }
        selectPane(pane)
    }

    private func selectPane(_ pane: OigoSettingsPane, loadLocales: Bool = true) {
        let previousPane = selectedPane
        if pane != .dictation {
            cancelLocaleWork()
        }
        selectedPane = pane
        UserDefaults.standard.set(pane.rawValue, forKey: Self.selectedPaneKey)
        let incomingView = paneViews[pane]
        let outgoingView = paneViews[previousPane]
        if let window {
            let contentHeight: CGFloat = 400 + 24 + MacUITokens.Spacing.section + Self.paneTopPadding + Self.paneBottomPadding
            let dictionaryMinimum = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: Self.shellWidth, height: contentHeight)).height
            window.minSize.height = pane == .dictionary ? max(520, dictionaryMinimum) : 520
            if pane == .dictionary, window.frame.height < window.minSize.height {
                var frame = window.frame
                frame.origin.y -= window.minSize.height - frame.height
                frame.size.height = window.minSize.height
                window.setFrame(frame, display: false)
            }
        }
        if previousPane != pane, window?.isVisible == true, let incomingView {
            outgoingView?.isHidden = true
            incomingView.isHidden = false
            incomingView.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.paneTransitionDuration
                incomingView.animator().alphaValue = 1
            }
        } else {
            for (candidate, view) in paneViews {
                view.isHidden = candidate != pane
                view.alphaValue = 1
            }
        }
        window?.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(pane.rawValue)
        window?.makeFirstResponder(incomingView)
        if loadLocales, pane == .dictation {
            loadSupportedLocalesIfNeeded()
        }
    }

    private func loadSupportedLocalesIfNeeded() {
        guard !hasLoadedSupportedLocales, localeLoadTask == nil else {
            return
        }
        let loadLocales = loadSupportedLocales
        localeLoadTask = Task { @MainActor [weak self] in
            let locales = await loadLocales()
            guard let self, !Task.isCancelled, !isDismissed, selectedPane == .dictation else {
                return
            }
            localeSelection.loadSupported(locales)
            syncLocalePopup()
            hasLoadedSupportedLocales = true
            localeLoadTask = nil
        }
    }

    private func cancelLocaleWork() {
        localeLoadTask?.cancel()
        localeLoadTask = nil
        hasLoadedSupportedLocales = false
        saveTask?.cancel()
        saveTask = nil
        isCheckingLocale = false
        localeSelection.abandonUncommitted()
        syncLocalePopup()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        _ = notification
        let states = refreshPermissions()
        updatePermissionLabels(microphone: states.0, accessibility: states.1)
        updateShortcutStatus()
        setLaunchAtLoginStatus(launchAtLoginStatusProvider())
    }

    func showAndFocus() {
        let wasVisible = window?.isVisible == true
        showWindow(nil)
        if !wasVisible, window?.frame.origin == .zero {
            window?.center()
        }
        clampWindowToVisibleFrame()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowDidMove(_ notification: Notification) {
        _ = notification
        clampWindowToVisibleFrame()
    }

    func windowDidResize(_ notification: Notification) {
        _ = notification
        clampWindowToVisibleFrame()
    }

    func windowWillClose(_ notification: Notification) {
        _ = notification
        saveTask?.cancel()
        saveTask = nil
        isCheckingLocale = false
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

    private func clampWindowToVisibleFrame() {
        guard let window else {
            return
        }
        let screen = window.screen ?? NSScreen.screens.first(where: { $0.visibleFrame.intersects(window.frame) }) ?? NSScreen.main
        guard let screen else {
            return
        }
        let visible = screen.visibleFrame
        var frame = window.frame
        frame.size.width = min(max(frame.width, window.minSize.width), visible.width)
        frame.size.height = min(max(frame.height, window.minSize.height), visible.height)
        frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        guard frame != window.frame else {
            return
        }
        window.setFrame(frame, display: false)
    }

    private func configureWindow() {
        guard let contentView = window?.contentView else {
            return
        }
        shortcutRecorder.onValidationError = { [weak self] message in
            guard let self else { return }
            messageLabel.stringValue = committedShortcutCopy.preservedMessage(message)
        }

        func heading(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = MacUITokens.Typography.heading
            return label
        }

        let dictationTitle = heading("Dictation")
        let dictionaryPaneTitle = heading("Dictionary")
        let privacyPaneTitle = heading("Data & Privacy")
        identify(dictationTitle, as: "section-dictation")
        identify(dictionaryPaneTitle, as: "section-dictionary")
        identify(privacyPaneTitle, as: "section-data-privacy")
        nextDictationNotice.textColor = MacUITokens.Colors.secondaryLabel
        nextDictationNotice.isHidden = true

        let shortcutTitle = NSTextField(labelWithString: "Dictation shortcut:")
        shortcutHelp.stringValue = committedShortcutCopy.settingsHint
        shortcutHelp.textColor = MacUITokens.Colors.secondaryLabel
        shortcutHelp.font = MacUITokens.Typography.secondary
        shortcutStatus.font = MacUITokens.Typography.secondary
        shortcutStatus.textColor = MacUITokens.Colors.secondaryLabel
        identify(shortcutHelp, as: "shortcut-help")
        identify(shortcutStatus, as: "shortcut-status")
        identify(messageLabel, as: "save-message")
        identify(dictationMessage, as: "dictation-message")
        let modeLabel = NSTextField(labelWithString: "Processing mode:")
        let localeLabel = NSTextField(labelWithString: "Language:")
        let retentionLabel = NSTextField(labelWithString: "Audio retention:")
        let inputLabel = NSTextField(labelWithString: "Microphone:")
        let channelLabel = NSTextField(labelWithString: "Channel:")

        let refreshButton = NSButton(title: "Refresh permission states", target: self, action: #selector(refreshPermissionStates))
        let microphoneSettingsButton = NSButton(title: "Open Microphone Settings", target: self, action: #selector(openMicrophoneSettingsAction))
        let accessibilitySettingsButton = NSButton(title: "Open Accessibility Settings", target: self, action: #selector(openAccessibilitySettingsAction))
        let retryStorageButton = NSButton(title: "Retry Storage", target: self, action: #selector(retryStorageAction))
        self.retryStorageButton = retryStorageButton
        let rerunButton = NSButton(title: "Run Setup Assistant Again…", target: self, action: #selector(rerunOnboardingAction))
        let historyButton = NSButton(title: "Open History", target: self, action: #selector(openHistoryAction))
        let dataButton = NSButton(title: "Open Oigo data folder", target: self, action: #selector(openDataFolderAction))
        let deleteButton = NSButton(title: "Delete All History…", target: self, action: #selector(deleteAllHistoryAction))
        deleteButton.hasDestructiveAction = true
        let exportButton = NSButton(title: "Export Diagnostics…", target: self, action: #selector(exportDiagnosticsAction))
        identify(shortcutRecorder, as: "shortcut-recorder")
        launchAtLoginCheckbox.title = "Open Oigo automatically"
        previewCheckbox.title = "Show live transcript preview"
        identify(launchAtLoginCheckbox, as: "launch-at-login")
        identify(openLoginItemsButton, as: "open-login-items")
        identify(previewCheckbox, as: "volatile-preview")
        identify(modePopup, as: "default-mode")
        identify(inputPopup, as: "microphone-input")
        identify(channelPopup, as: "input-channel")
        identify(localePopup, as: "dictation-language")
        identify(retentionPopup, as: "audio-retention")
        identify(keepAudioCheckbox, as: "keep-audio")
        identify(refreshButton, as: "refresh-permissions")
        identify(microphoneSettingsButton, as: "open-microphone-settings")
        identify(accessibilitySettingsButton, as: "open-accessibility-settings")
        identify(retryStorageButton, as: "retry-storage")
        identify(rerunButton, as: "rerun-onboarding")
        identify(historyButton, as: "open-history")
        identify(dataButton, as: "open-data-folder")
        identify(deleteButton, as: "delete-all-history")
        identify(exportButton, as: "export-diagnostics")
        let helpTitle = NSTextField(labelWithString: "About")
        helpTitle.font = MacUITokens.Typography.section
        let helpBody = NSTextField(
            wrappingLabelWithString: "Oigo is a menu-bar dictation app for macOS 26 or later on Apple silicon. Microphone access is required. Accessibility enables Fn and automatic paste; modified shortcuts and copy-only work without it. Instant inserts the recognized transcript; Clean optionally rewrites it on this Mac. Recordings, transcripts, and the custom dictionary live in Application Support/Oigo. The README and privacy statement ship with the download."
        )
        helpBody.textColor = MacUITokens.Colors.secondaryLabel
        microphoneStatus.font = MacUITokens.Typography.secondary
        accessibilityStatus.font = MacUITokens.Typography.secondary
        storageStatus.font = MacUITokens.Typography.secondary
        launchAtLoginStatusLabel.font = MacUITokens.Typography.secondary
        launchAtLoginStatusLabel.textColor = MacUITokens.Colors.secondaryLabel
        launchAtLoginStatusLabel.maximumNumberOfLines = 3
        openLoginItemsButton.target = self
        openLoginItemsButton.action = #selector(openLoginItemsSettingsAction)
        openLoginItemsButton.bezelStyle = .rounded
        messageLabel.font = MacUITokens.Typography.secondary
        messageLabel.textColor = MacUITokens.Colors.secondaryLabel
        messageLabel.maximumNumberOfLines = 4
        dictationMessage.font = MacUITokens.Typography.secondary
        dictationMessage.textColor = MacUITokens.Colors.warning
        dictationMessage.maximumNumberOfLines = 3

        func generalControlGroup(_ views: [NSView]) -> NSStackView {
            let group = NSStackView(views: views)
            group.orientation = .vertical
            group.alignment = .leading
            group.spacing = 4
            return group
        }
        let shortcutGroup = generalControlGroup([shortcutRecorder, shortcutHelp, shortcutStatus])
        let shortcutRow = NSStackView(views: [shortcutTitle, shortcutGroup])
        shortcutRow.orientation = .horizontal
        shortcutRow.alignment = .top
        shortcutRow.spacing = 10
        shortcutTitle.alignment = .right
        shortcutTitle.widthAnchor.constraint(equalToConstant: 180).isActive = true
        shortcutRow.translatesAutoresizingMaskIntoConstraints = false
        shortcutRecorder.widthAnchor.constraint(equalToConstant: 160).isActive = true
        shortcutRecorder.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let modeRow = row(label: modeLabel, control: modePopup)
        let localeRow = row(label: localeLabel, control: localePopup)
        let retentionRow = row(label: retentionLabel, control: retentionPopup)
        let inputRow = row(label: inputLabel, control: inputPopup)
        let channelRow = row(label: channelLabel, control: channelPopup)
        inputPopup.target = self
        inputPopup.action = #selector(inputSelectionChanged)
        let dictionaryHelp = NSTextField(
            wrappingLabelWithString: "Canonical spellings are supplied to Speech and used for deterministic normalization. Editing the dictionary never rewrites historical transcripts."
        )
        dictionaryHelp.textColor = MacUITokens.Colors.secondaryLabel
        identify(dictionaryHelp, as: "dictionary-helper")
        let dictionarySplit = makeDictionarySplit(helper: dictionaryHelp)
        dictionaryMessage.textColor = MacUITokens.Colors.warning
        dictionaryMessage.maximumNumberOfLines = 3
        identify(dictionaryMessage, as: "dictionary-status")

        let permissionsTitle = NSTextField(labelWithString: "Permissions")
        permissionsTitle.font = MacUITokens.Typography.section
        identify(permissionsTitle, as: "section-permissions")
        let permissionStack = NSStackView(views: [microphoneStatus, microphoneSettingsButton, accessibilityStatus, accessibilitySettingsButton, refreshButton])
        permissionStack.orientation = .vertical
        permissionStack.alignment = .leading
        permissionStack.spacing = 6

        let storageStack = NSStackView(views: [storageStatus, retryStorageButton, dataButton])
        storageStack.orientation = .vertical
        storageStack.alignment = .leading
        storageStack.spacing = 6

        let privacyActionStack = NSStackView(views: [historyButton, storageStack, deleteButton, exportButton])
        privacyActionStack.orientation = .vertical
        privacyActionStack.alignment = .leading
        privacyActionStack.spacing = 8

        func generalRow(_ title: String, _ controls: [NSView]) -> NSStackView {
            let label = NSTextField(labelWithString: title)
            label.alignment = .right
            label.widthAnchor.constraint(equalToConstant: 180).isActive = true
            let group = generalControlGroup(controls)
            let row = NSStackView(views: [label, group])
            row.alignment = .top
            row.spacing = 10
            return row
        }
        let launchRow = generalRow("Launch at login:", [launchAtLoginCheckbox, launchAtLoginStatusLabel, openLoginItemsButton])
        let previewHelp = NSTextField(wrappingLabelWithString: "One line of in-progress text beneath the timer. Never stored.")
        previewHelp.font = MacUITokens.Typography.secondary
        previewHelp.textColor = .secondaryLabelColor
        identify(previewHelp, as: "volatile-preview-help")
        let previewRow = generalRow("Recording HUD:", [previewCheckbox, previewHelp])
        let setupSeparator = NSBox()
        setupSeparator.boxType = .separator
        let setupRow = generalRow("Setup:", [rerunButton])

        let generalStack = NSStackView(views: [
            shortcutRow,
            launchRow,
            previewRow,
            setupSeparator,
            setupRow,
            messageLabel
        ])
        let dictationStack = NSStackView(views: [
            dictationTitle,
            nextDictationNotice,
            modeRow,
            inputRow,
            channelRow,
            localeRow,
            retentionRow,
            keepAudioCheckbox,
            dictationMessage
        ])
        let dictionaryStack = NSStackView(views: [
            dictionaryPaneTitle,
            dictionarySplit
        ])
        let privacyStack = NSStackView(views: [
            privacyPaneTitle,
            permissionsTitle,
            permissionStack,
            privacyActionStack,
            helpTitle,
            helpBody
        ])
        let paneStacks: [(OigoSettingsPane, NSStackView)] = [
            (.general, generalStack),
            (.dictation, dictationStack),
            (.dictionary, dictionaryStack),
            (.dataPrivacy, privacyStack)
        ]
        paneContainer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(paneContainer)
        NSLayoutConstraint.activate([
            paneContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Self.paneHorizontalPadding),
            paneContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Self.paneHorizontalPadding),
            paneContainer.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Self.paneTopPadding),
            paneContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Self.paneBottomPadding)
        ])
        paneContainer.identifier = NSUserInterfaceItemIdentifier("oigo.settings.content")
        paneContainer.setAccessibilityIdentifier("oigo.settings.content")
        paneContainer.setAccessibilityElement(true)
        paneContainer.setAccessibilityRole(.group)
        paneContainer.setAccessibilityLabel("Settings content")
        paneViews = Dictionary(uniqueKeysWithValues: paneStacks.map { ($0.0, $0.1) })
        for (pane, stack) in paneStacks {
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = MacUITokens.Spacing.section
            stack.identifier = NSUserInterfaceItemIdentifier("oigo.settings.pane." + pane.rawValue)
            stack.setAccessibilityIdentifier("oigo.settings.pane." + pane.rawValue)
            stack.setAccessibilityElement(true)
            stack.setAccessibilityRole(.group)
            stack.setAccessibilityLabel(pane.title)
            stack.translatesAutoresizingMaskIntoConstraints = false
            paneContainer.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: paneContainer.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: paneContainer.trailingAnchor),
                stack.topAnchor.constraint(equalTo: paneContainer.topAnchor),
                stack.bottomAnchor.constraint(lessThanOrEqualTo: paneContainer.bottomAnchor)
            ])
        }
        NSLayoutConstraint.activate([
            dictationTitle.widthAnchor.constraint(equalTo: paneContainer.widthAnchor),
            dictionaryPaneTitle.widthAnchor.constraint(equalTo: paneContainer.widthAnchor),
            shortcutRow.widthAnchor.constraint(equalTo: paneContainer.widthAnchor),
            shortcutHelp.widthAnchor.constraint(equalTo: paneContainer.widthAnchor, constant: -190),
            shortcutStatus.widthAnchor.constraint(equalTo: shortcutHelp.widthAnchor),
            launchRow.widthAnchor.constraint(equalTo: paneContainer.widthAnchor),
            previewRow.widthAnchor.constraint(equalTo: paneContainer.widthAnchor),
            previewHelp.widthAnchor.constraint(equalTo: shortcutHelp.widthAnchor),
            setupSeparator.widthAnchor.constraint(equalTo: paneContainer.widthAnchor),
            setupRow.widthAnchor.constraint(equalTo: paneContainer.widthAnchor),
            messageLabel.widthAnchor.constraint(equalTo: paneContainer.widthAnchor),
            dictationMessage.widthAnchor.constraint(equalTo: paneContainer.widthAnchor),
            nextDictationNotice.widthAnchor.constraint(equalTo: paneContainer.widthAnchor),
            modeRow.widthAnchor.constraint(equalTo: paneContainer.widthAnchor),
            localeRow.widthAnchor.constraint(equalTo: paneContainer.widthAnchor),
            retentionRow.widthAnchor.constraint(equalTo: paneContainer.widthAnchor),
            inputRow.widthAnchor.constraint(equalTo: paneContainer.widthAnchor),
            channelRow.widthAnchor.constraint(equalTo: paneContainer.widthAnchor),
            dictionarySplit.widthAnchor.constraint(equalTo: paneContainer.widthAnchor),
            helpBody.widthAnchor.constraint(equalTo: paneContainer.widthAnchor),
            localePopup.widthAnchor.constraint(equalToConstant: 260),
            inputPopup.widthAnchor.constraint(equalTo: localePopup.widthAnchor),
            channelPopup.widthAnchor.constraint(equalTo: localePopup.widthAnchor)
        ])
        selectPane(selectedPane, loadLocales: false)
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
        commitChangedSettings()
    }

    func syncLocalePopup() {
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
        dictationMessage.stringValue = localeSelection.statusMessage
        commitChangedSettings()
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
        row.spacing = MacUITokens.Spacing.controlGroup
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 180).isActive = true
        label.setContentHuggingPriority(.required, for: .horizontal)
        return row
    }

    private func identify(_ control: NSControl, as name: String) {
        let identifier = "oigo.settings." + name
        control.identifier = NSUserInterfaceItemIdentifier(identifier)
        control.setAccessibilityIdentifier(identifier)
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

    func setLaunchAtLoginStatus(_ status: OigoLaunchAtLoginStatus) {
        currentLaunchAtLoginStatus = status
        let presentation = OigoLaunchAtLoginPresentation(status: status)
        launchAtLoginCheckbox.state = presentation.checkboxOn ? .on : .off
        launchAtLoginCheckbox.isEnabled = presentation.allowsCheckboxMutation
        launchAtLoginStatusLabel.stringValue = presentation.detail
        openLoginItemsButton.isHidden = !presentation.showsOpenLoginItems
        if !presentation.allowsCheckboxMutation {
            launchAtLoginStatusLabel.textColor = MacUITokens.Colors.warning
        } else {
            launchAtLoginStatusLabel.textColor = MacUITokens.Colors.secondaryLabel
        }
    }

    private func updateShortcutStatus() {
        shortcutHelp.stringValue = committedShortcutCopy.settingsHint
        shortcutRecorder.toolTip = committedShortcutCopy.settingsHint
        switch registrationStatus() {
        case .active:
            let suffix = registrationError().map { ". Last error: " + $0 } ?? ""
            shortcutStatus.stringValue = committedShortcutCopy.activeStatus + suffix
        case .inactive(let message):
            shortcutStatus.stringValue = committedShortcutCopy.unavailableMessage(
                registrationError() ?? message
            )
        }
    }

    @objc private func refreshPermissionStates() {
        let states = refreshPermissions()
        updatePermissionLabels(microphone: states.0, accessibility: states.1)
        updateShortcutStatus()
        setLaunchAtLoginStatus(launchAtLoginStatusProvider())
        messageLabel.stringValue = "Permission states refreshed."
    }

    @objc private func openLoginItemsSettingsAction() {
        openLoginItemsSettings()
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

    @objc private func exportDiagnosticsAction() {
        guard let window else {
            return
        }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "oigo-diagnostics.json"
        panel.allowedContentTypes = [.json]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else {
                return
            }
            do {
                let data = try self.exportDiagnostics()
                try data.write(to: url, options: .atomic)
                self.messageLabel.stringValue = "Diagnostics exported."
            } catch {
                self.messageLabel.stringValue = "Diagnostics export failed."
            }
        }
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

    @objc private func commitChangedSettings() {
        guard let modeTitle = modePopup.selectedItem?.title,
              let mode = OigoProcessingMode.allCases.first(where: { $0.displayName == modeTitle }),
              let retentionTitle = retentionPopup.selectedItem?.title,
              let retention = OigoAudioRetention.allCases.first(where: { $0.displayName == retentionTitle }) else {
            messageLabel.stringValue = "Enter a valid shortcut and choose a mode and retention duration."
            NSSound.beep()
            return
        }
        let draft = OigoSettings(
            globalShortcut: committedShortcut,
            localeIdentifier: localeSelection.committedIdentifier,
            defaultMode: mode,
            showVolatilePreview: previewCheckbox.state == .on,
            audioRetention: retention,
            keepSuccessfulAudioIndefinitely: keepAudioCheckbox.state == .on,
            launchAtLogin: OigoLaunchAtLoginReconciliation.persistableIntent(
                checkboxOn: launchAtLoginCheckbox.state == .on,
                allowsCheckboxMutation: OigoLaunchAtLoginPresentation(
                    status: currentLaunchAtLoginStatus
                ).allowsCheckboxMutation,
                previousIntent: lastRequestedLaunchAtLogin,
                status: currentLaunchAtLoginStatus
            ),
            selectedInput: selectedInputFromMenu(),
            selectedInputChannel: selectedChannelFromMenu()
        )
        guard localeSelection.requiresVerificationToCommit else {
            _ = finishSave(draft, languageUnappliedMessage: nil)
            return
        }
        if isCheckingLocale {
            _ = finishSave(
                draft.with(localeIdentifier: localeSelection.committedIdentifier),
                languageUnappliedMessage: nil
            )
            return
        }
        guard let request = localeSelection.beginAssetRequest(status: .installing) else {
            dictationMessage.stringValue = localeSelection.statusMessage
            NSSound.beep()
            return
        }
        isCheckingLocale = true
        dictationMessage.stringValue = localeSelection.statusMessage
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
            isCheckingLocale = false
            if applied,
               localeSelection.canConfirm,
               let locale = localeSelection.selectedIdentifier {
                let saved = finishSave(
                    committedSettings.with(localeIdentifier: locale),
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
                committedSettings,
                languageUnappliedMessage: "Settings saved. Dictation language was not changed: " + reason
            )
        }
    }

    private func commitShortcut(_ candidate: ToggleShortcut) {
        guard !isDismissed, isPresented() else {
            shortcutRecorder.restoreCandidate(committedShortcut)
            return
        }
        let validation = validateShortcut(candidate)
        guard validation.isAvailable else {
            restoreShortcutAfterFailure(validation)
            return
        }
        let result = saveShortcut(candidate)
        guard result.isAvailable else {
            restoreShortcutAfterFailure(result)
            return
        }
        committedShortcut = candidate
        committedSettings = committedSettings.with(globalShortcut: candidate)
        shortcutRecorder.restoreCandidate(candidate)
        messageLabel.stringValue = "Saved."
        updateShortcutStatus()
    }

    private func restoreShortcutAfterFailure(_ validation: OigoShortcutValidation) {
        shortcutRecorder.restoreCandidate(committedShortcut)
        let reason = switch validation {
        case .available: "Shortcut could not be saved"
        case .conflict(let reason), .invalid(let reason): reason
        }
        messageLabel.stringValue = committedShortcutCopy.preservedMessage(reason)
        updateShortcutStatus()
        NSSound.beep()
    }

    @discardableResult
    func finishSave(_ settings: OigoSettings, languageUnappliedMessage: String?) -> Bool {
        guard !isDismissed, isPresented() else {
            return false
        }
        let result = save(settings)
        if let result {
            messageLabel.stringValue = result
            restoreCommittedControls()
            updateShortcutStatus()
            setLaunchAtLoginStatus(launchAtLoginStatusProvider())
            NSSound.beep()
            return false
        }
        committedSettings = settings
        lastRequestedLaunchAtLogin = settings.launchAtLogin
        updateShortcutStatus()
        if let languageUnappliedMessage {
            dictationMessage.stringValue = languageUnappliedMessage
            NSSound.beep()
            return true
        }
        messageLabel.stringValue = "Saved."
        return true
    }

    private func restoreCommittedControls() {
        modePopup.selectItem(withTitle: committedSettings.defaultMode.displayName)
        retentionPopup.selectItem(withTitle: committedSettings.audioRetention.displayName)
        previewCheckbox.state = committedSettings.showVolatilePreview ? .on : .off
        keepAudioCheckbox.state = committedSettings.keepSuccessfulAudioIndefinitely ? .on : .off
        selectedInput = committedSettings.selectedInput
        selectedInputChannel = committedSettings.selectedInputChannel
        configureInputMenu(devices: inputDevices, selected: selectedInput)
        configureChannelMenu()
        localeSelection.abandonUncommitted()
        syncLocalePopup()
        shortcutRecorder.restoreCandidate(committedShortcut)
    }

    private func makeDictionarySplit(helper: NSTextField) -> NSView {
        configureDictionaryTable()
        let split = NSView()
        split.identifier = NSUserInterfaceItemIdentifier("oigo.settings.dictionary-split")
        split.setAccessibilityIdentifier("oigo.settings.dictionary-split")
        split.wantsLayer = true
        split.layer?.cornerRadius = 8
        split.layer?.masksToBounds = true
        let sidebar = NSBox()
        sidebar.boxType = .custom
        sidebar.borderWidth = 0
        sidebar.fillColor = .controlBackgroundColor
        sidebar.contentViewMargins = .zero
        dictionarySearch.placeholderString = "Search"
        dictionarySearch.delegate = self
        identify(dictionarySearch, as: "dictionary-search")
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = dictionaryTable
        let add = NSButton(title: "+", target: self, action: #selector(addDictionaryEntry))
        identify(add, as: "dictionary-add")
        add.setAccessibilityLabel("Add dictionary term")
        removeTermButton.target = self
        removeTermButton.action = #selector(deleteDictionaryEntry)
        identify(removeTermButton, as: "dictionary-delete")
        removeTermButton.setAccessibilityLabel("Remove dictionary term")
        let starter = NSButton(title: "Starter terms", target: self, action: #selector(addStarterTermsAction))
        starter.controlSize = .small
        identify(starter, as: "dictionary-starter-terms")
        starter.setAccessibilityLabel("Add starter terms")
        let buttons = NSStackView(views: [add, removeTermButton, starter])
        buttons.spacing = 2
        let divider = NSBox()
        divider.boxType = .separator
        let editor = DictionaryEditorStack()
        editor.orientation = .vertical
        editor.alignment = .leading
        editor.spacing = 12
        editor.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        let editorScroll = NSScrollView()
        editorScroll.hasVerticalScroller = true
        editorScroll.autohidesScrollers = true
        editorScroll.drawsBackground = true
        editorScroll.backgroundColor = .textBackgroundColor
        editorScroll.documentView = editor
        canonicalField.placeholderString = "Canonical spelling"
        canonicalField.delegate = self
        identify(canonicalField, as: "dictionary-canonical")
        canonicalField.setAccessibilityLabel("Canonical spelling")
        dictionaryLocale.addItem(withTitle: "All languages")
        dictionaryLocale.lastItem?.representedObject = ""
        dictionaryLocale.target = self
        dictionaryLocale.action = #selector(dictionaryOptionsChanged)
        identify(dictionaryLocale, as: "dictionary-locale")
        dictionaryLocale.setAccessibilityLabel("Dictionary language")
        dictionaryEnabled.target = self
        dictionaryEnabled.action = #selector(dictionaryOptionsChanged)
        identify(dictionaryEnabled, as: "dictionary-toggle")
        let options = NSStackView(views: [dictionaryLocale, dictionaryEnabled])
        options.spacing = 8
        dictionaryLocale.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        aliasStack.orientation = .vertical
        aliasStack.alignment = .leading
        aliasStack.spacing = 4
        addAliasButton.target = self
        addAliasButton.action = #selector(addDictionaryAlias)
        addAliasButton.controlSize = .small
        identify(addAliasButton, as: "dictionary-add-alias")
        let aliases = NSStackView(views: [aliasStack, addAliasButton])
        aliases.orientation = .vertical
        aliases.alignment = .leading
        aliases.spacing = 4
        sampleField.placeholderString = "Type a sentence with an alias"
        sampleField.delegate = self
        identify(sampleField, as: "dictionary-preview")
        sampleField.setAccessibilityLabel("Test dictionary normalization")
        identify(previewLabel, as: "dictionary-result")
        previewLabel.maximumNumberOfLines = 3
        previewLabel.textColor = .secondaryLabelColor
        let test = NSStackView(views: [sampleField, previewLabel])
        test.orientation = .vertical
        test.alignment = .leading
        test.spacing = 5
        let separator = NSBox()
        separator.boxType = .separator
        let rows = [
            dictionaryFormRow("Canonical:", canonicalField),
            dictionaryFormRow("Locale:", options),
            dictionaryFormRow("Aliases:", aliases),
            separator,
            dictionaryFormRow("Test:", test),
            helper,
            dictionaryMessage
        ]
        for row in rows {
            editor.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: editor.widthAnchor, constant: -40).isActive = true
        }
        for view in [sidebar, divider, editorScroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            split.addSubview(view)
        }
        for view in [dictionarySearch, scroll, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            sidebar.addSubview(view)
        }
        editor.translatesAutoresizingMaskIntoConstraints = false
        split.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            split.heightAnchor.constraint(equalToConstant: 400),
            sidebar.leadingAnchor.constraint(equalTo: split.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: split.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: split.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 200),
            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.topAnchor.constraint(equalTo: split.topAnchor),
            divider.bottomAnchor.constraint(equalTo: split.bottomAnchor),
            editorScroll.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            editorScroll.trailingAnchor.constraint(equalTo: split.trailingAnchor),
            editorScroll.topAnchor.constraint(equalTo: split.topAnchor),
            editorScroll.bottomAnchor.constraint(equalTo: split.bottomAnchor),
            editor.widthAnchor.constraint(equalTo: editorScroll.contentView.widthAnchor),
            editor.leadingAnchor.constraint(equalTo: editorScroll.contentView.leadingAnchor),
            editor.topAnchor.constraint(equalTo: editorScroll.contentView.topAnchor),
            dictionarySearch.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 10),
            dictionarySearch.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
            dictionarySearch.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: dictionarySearch.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -6),
            buttons.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 8),
            buttons.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -6),
            aliasStack.widthAnchor.constraint(equalTo: aliases.widthAnchor),
            sampleField.widthAnchor.constraint(equalTo: test.widthAnchor),
            previewLabel.widthAnchor.constraint(equalTo: test.widthAnchor)
        ])
        reloadDictionarySelection()
        refreshDictionaryEditor()
        return split
    }

    private func dictionaryFormRow(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 70).isActive = true
        let row = NSStackView(views: [label, control])
        row.alignment = .top
        row.spacing = 10
        control.widthAnchor.constraint(equalTo: row.widthAnchor, constant: -80).isActive = true
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    private func reloadDictionarySelection() {
        refreshingDictionary = true
        defer { refreshingDictionary = false }
        let query = dictionarySearch.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        visibleDictionaryEntries = dictionaryEntries.filter {
            query.isEmpty || ([$0.canonical] + $0.aliases).contains { $0.localizedCaseInsensitiveContains(query) }
        }
        if let draft = editingDictionaryEntry,
           !dictionaryEntries.contains(where: { $0.id == draft.id }) {
            visibleDictionaryEntries.append(draft)
        }
        dictionaryTable.reloadData()
        if let selected = visibleDictionaryEntries.firstIndex(where: { $0.id == editingDictionaryEntry?.id }) {
            dictionaryTable.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
        } else {
            dictionaryTable.deselectAll(nil)
            editingDictionaryEntry = nil
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !refreshingDictionary else { return }
        let row = dictionaryTable.selectedRow
        editingDictionaryEntry = visibleDictionaryEntries.indices.contains(row) ? visibleDictionaryEntries[row] : nil
        dictionaryMessage.stringValue = ""
        refreshDictionaryEditor()
    }

    private func refreshDictionaryEditor() {
        let entry = editingDictionaryEntry
        canonicalField.stringValue = entry?.canonical ?? ""
        dictionaryEnabled.state = entry?.isEnabled == true ? .on : .off
        let locales = Set(localeMenuIdentifiers + [committedSettings.localeIdentifier] + dictionaryEntries.compactMap(\.localeIdentifier))
        dictionaryLocale.removeAllItems()
        dictionaryLocale.addItem(withTitle: "All languages")
        dictionaryLocale.lastItem?.representedObject = ""
        for locale in locales.sorted() {
            dictionaryLocale.addItem(withTitle: Locale.current.localizedString(forIdentifier: locale) ?? locale)
            dictionaryLocale.lastItem?.representedObject = locale
        }
        dictionaryLocale.selectItem(at: dictionaryLocale.itemArray.firstIndex {
            ($0.representedObject as? String) == (entry?.localeIdentifier ?? "")
        } ?? 0)
        for control: NSControl in [canonicalField, dictionaryLocale, dictionaryEnabled, addAliasButton, removeTermButton, sampleField] {
            control.isEnabled = entry != nil
        }
        let aliases = entry?.aliases ?? []
        if aliasStack.arrangedSubviews.count == aliases.count {
            for (index, row) in aliasStack.arrangedSubviews.enumerated() {
                if let row = row as? NSStackView, let field = row.arrangedSubviews.first as? NSTextField {
                    field.stringValue = aliases[index]
                }
            }
            previewSampleChanged()
            return
        }
        for view in aliasStack.arrangedSubviews {
            aliasStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, alias) in aliases.enumerated() {
            let field = NSTextField(string: alias)
            field.placeholderString = "Alias"
            field.tag = index
            field.delegate = self
            identify(field, as: "dictionary-alias-\(index)")
            field.setAccessibilityLabel("Alias \(index + 1)")
            let remove = NSButton(title: "−", target: self, action: #selector(removeDictionaryAlias(_:)))
            remove.tag = index
            remove.controlSize = .small
            identify(remove, as: "dictionary-remove-alias-\(index)")
            remove.setAccessibilityLabel("Remove alias \(index + 1)")
            let row = NSStackView(views: [field, remove])
            row.spacing = 8
            aliasStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: aliasStack.widthAnchor).isActive = true
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        previewSampleChanged()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === sampleField {
            previewSampleChanged()
        } else if field === dictionarySearch {
            reloadDictionarySelection()
            refreshDictionaryEditor()
        } else if field === canonicalField {
            editingDictionaryEntry?.canonical = field.stringValue
        } else if editingDictionaryEntry?.aliases.indices.contains(field.tag) == true {
            editingDictionaryEntry?.aliases[field.tag] = field.stringValue
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              field !== sampleField, field !== dictionarySearch else { return }
        controlTextDidChange(notification)
        commitDictionaryEditor()
    }

    @objc private func dictionaryOptionsChanged() {
        editingDictionaryEntry?.isEnabled = dictionaryEnabled.state == .on
        let locale = dictionaryLocale.selectedItem?.representedObject as? String ?? ""
        editingDictionaryEntry?.localeIdentifier = locale.isEmpty ? nil : locale
        commitDictionaryEditor()
    }

    @objc private func addDictionaryAlias() {
        guard editingDictionaryEntry != nil else { return }
        editingDictionaryEntry?.aliases.append("")
        dictionaryMessage.stringValue = "Enter an alias to save."
        refreshDictionaryEditor()
        if let row = aliasStack.arrangedSubviews.last as? NSStackView,
           let field = row.arrangedSubviews.first as? NSTextField {
            window?.makeFirstResponder(field)
        }
    }

    @objc private func removeDictionaryAlias(_ sender: NSButton) {
        guard editingDictionaryEntry?.aliases.indices.contains(sender.tag) == true else { return }
        editingDictionaryEntry?.aliases.remove(at: sender.tag)
        commitDictionaryEditor()
        refreshDictionaryEditor()
    }

    private func commitDictionaryEditor() {
        guard var entry = editingDictionaryEntry else { return }
        entry.canonical = entry.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        entry.aliases = entry.aliases.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var candidate = dictionaryEntries
        if let index = candidate.firstIndex(where: { $0.id == entry.id }) {
            candidate[index] = entry
        } else {
            candidate.append(entry)
        }
        do {
            try DictionaryCompiler.validate(candidate)
        } catch {
            dictionaryMessage.stringValue = String(describing: error)
            return
        }
        guard candidate != committedDictionaryEntries else { return }
        if persistDictionaryEntries(candidate) {
            editingDictionaryEntry = entry
            dictionarySearch.stringValue = ""
        } else if let committed = committedDictionaryEntries.first(where: { $0.id == entry.id }) {
            editingDictionaryEntry = committed
        }
        reloadDictionarySelection()
        refreshDictionaryEditor()
    }

    private func configureDictionaryTable() {
        dictionaryTable.identifier = NSUserInterfaceItemIdentifier("oigo.settings.dictionary-table")
        dictionaryTable.setAccessibilityIdentifier("oigo.settings.dictionary-table")
        dictionaryTable.setAccessibilityElement(true)
        dictionaryTable.setAccessibilityRole(.table)
        dictionaryTable.setAccessibilityLabel("Custom dictionary entries")
        dictionaryTable.addTableColumn(column(identifier: "canonical", title: "Terms", width: 180))
        dictionaryTable.headerView = nil
        dictionaryTable.delegate = self
        dictionaryTable.dataSource = self
        dictionaryTable.style = .sourceList
        dictionaryTable.rowHeight = 28
        dictionaryTable.allowsEmptySelection = true
    }

    private func column(identifier: String, title: String, width: CGFloat) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = title
        column.width = width
        return column
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        visibleDictionaryEntries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard visibleDictionaryEntries.indices.contains(row) else {
            return nil
        }
        let entry = visibleDictionaryEntries[row]
        let text = (entry.canonical.isEmpty ? "New term" : entry.canonical) + (entry.isEnabled ? "" : "  off")
        let view = NSTableCellView()
        let field = NSTextField(labelWithString: text)
        field.lineBreakMode = .byTruncatingTail
        view.textField = field
        field.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        return view
    }

    @objc private func addDictionaryEntry() {
        dictionarySearch.stringValue = ""
        editingDictionaryEntry = DictionaryEntry(canonical: "", aliases: [])
        dictionaryMessage.stringValue = "Enter a canonical spelling to save a new term."
        reloadDictionarySelection()
        refreshDictionaryEditor()
        window?.makeFirstResponder(canonicalField)
    }

    @objc private func deleteDictionaryEntry() {
        guard let entry = editingDictionaryEntry else { return }
        let row = dictionaryTable.selectedRow
        if dictionaryEntries.contains(where: { $0.id == entry.id }) {
            guard persistDictionaryEntries(dictionaryEntries.filter { $0.id != entry.id }) else { return }
        }
        editingDictionaryEntry = nil
        reloadDictionarySelection()
        if !visibleDictionaryEntries.isEmpty {
            dictionaryTable.selectRowIndexes(IndexSet(integer: min(max(row, 0), visibleDictionaryEntries.count - 1)), byExtendingSelection: false)
        }
        refreshDictionaryEditor()
        previewSampleChanged()
    }

    @objc private func addStarterTermsAction() {
        let (document, error) = addStarterTerms()
        if let error {
            dictionaryMessage.stringValue = error
            return
        }
        dictionaryEntries = document.entries
        committedDictionaryEntries = document.entries
        reloadDictionarySelection()
        refreshDictionaryEditor()
        dictionaryMessage.stringValue = ""
        previewSampleChanged()
    }

    @objc private func previewSampleChanged() {
        previewLabel.stringValue = "Result: " + previewDictionary(sampleField.stringValue)
    }

    func setDictionaryStatus(_ message: String?) {
        dictionaryMessage.stringValue = message ?? ""
    }

    private func persistDictionaryEntries(_ entries: [DictionaryEntry]) -> Bool {
        do {
            try DictionaryCompiler.validate(entries)
        } catch {
            dictionaryMessage.stringValue = String(describing: error)
            return false
        }
        if let error = saveDictionary(DictionaryDocument(entries: entries)) {
            dictionaryEntries = committedDictionaryEntries
            dictionaryMessage.stringValue = error
            return false
        } else {
            dictionaryEntries = entries
            committedDictionaryEntries = dictionaryEntries
            dictionaryMessage.stringValue = "Saved."
            return true
        }
    }
}

private final class DictionaryEditorStack: NSStackView {
    override var isFlipped: Bool { true }
}
