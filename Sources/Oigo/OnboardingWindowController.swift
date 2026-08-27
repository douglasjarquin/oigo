import AppKit
import OigoCore
import OigoHotKey

@available(macOS 26.0, *)
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let support: OigoSystemSupportResult
    private let processingMode: OigoProcessingMode
    private let loadSupportedLanguages: () async -> [String]
    private let checkSpeechAssets: (String) async -> OigoLocaleAssetStatus
    private let saveLanguage: (String) -> Void
    private let saveStep: (OigoOnboardingStep, Bool) -> Void
    private let saveInputSelection: (OigoInputSelection, Int) -> Void
    private let requestMicrophone: () async -> OigoPermissionState
    private let openMicrophoneSettings: () -> Void
    private let registrationStatus: () -> GlobalShortcutRegistrationStatus
    private let registrationError: () -> String?
    private let validateShortcut: (ToggleShortcut) -> OigoShortcutValidation
    private let saveShortcut: (ToggleShortcut) -> OigoShortcutValidation
    private let requestAccessibility: () -> OigoPermissionState
    private let openAccessibilitySettings: () -> Void
    private let retryStorage: () -> Void
    private let openDataLocation: () -> Void
    private let startSourceProbe: (OigoInputSelection, Int, UInt64) -> Void
    private let stopSourceProbe: () -> Void
    private let startTest: (UInt64) -> Void
    private let stopTest: () -> Void
    private let cancelTest: () -> Void
    private let openHistory: () -> Void
    private let onComplete: () -> Void
    private let onClose: () -> Void

    private var currentStep: OigoOnboardingStep
    private var localeSelection: OigoLocaleSelectionState
    private var localeMenuIdentifiers: [String] = []
    private var isLoadingLanguages = false
    private var microphoneState: OigoPermissionState
    private var accessibilityState: OigoPermissionState
    private var accessibilityRequestAttempted = false
    private var evidence = OigoOnboardingEvidenceMachine()
    private var activeTestGeneration: UInt64?
    private var commandAvailability: AppCommandAvailability?
    private var completed = false
    private var copyOnlySetupAccepted = false
    private var storageHealth: DurableSessionHealth
    private var committedShortcut: ToggleShortcut
    private var inputMenuSelections: [OigoInputSelection] = []
    private var selectedInput: OigoInputSelection
    private var selectedInputChannel: Int
    private var inputDevices: [OigoInputDevice]

    private let progressLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let storageStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let checklistTitleLabel = NSTextField(labelWithString: "Try It checklist")
    private let checklistStack = NSStackView()
    private let inputPopup = NSPopUpButton()
    private let inputLabel = NSTextField(labelWithString: "Microphone input")
    private let inputRow = NSStackView()
    private let channelPopup = NSPopUpButton()
    private let channelLabel = NSTextField(labelWithString: "Input channel")
    private let channelRow = NSStackView()
    private let meter = NSLevelIndicator()
    private let quietOverrideButton = NSButton(title: "Continue with quiet environment", target: nil, action: nil)
    private let copyOnlyButton = NSButton(title: "Continue with copy-only", target: nil, action: nil)
    private let languagePopup = NSPopUpButton()
    private let languageLabel = NSTextField(labelWithString: "Dictation language")
    private let languageRow = NSStackView()
    private let shortcutRecorder: ShortcutRecorderControl
    private let testField = NSTextField(string: "")
    private let actionButton = NSButton(title: "", target: nil, action: nil)
    private let skipButton = NSButton(title: "Skip test", target: nil, action: nil)
    private let backButton = NSButton(title: "Back", target: nil, action: nil)
    private let nextButton = NSButton(title: "Continue", target: nil, action: nil)
    private let historyButton = NSButton(title: "Open History", target: nil, action: nil)
    private let retryStorageButton = NSButton(title: "Retry Storage", target: nil, action: nil)
    private let openDataLocationButton = NSButton(title: "Open Data Location", target: nil, action: nil)

    init(
        support: OigoSystemSupportResult,
        initialStep: OigoOnboardingStep = .system,
        processingMode: OigoProcessingMode,
        globalShortcut: ToggleShortcut,
        copyOnlyAccepted: Bool = false,
        inputDevices: [OigoInputDevice],
        selectedInput: OigoInputSelection,
        selectedInputChannel: Int,
        committedLocaleIdentifier: String,
        microphoneState: OigoPermissionState,
        accessibilityState: OigoPermissionState,
        storageHealth: DurableSessionHealth,
        loadSupportedLanguages: @escaping () async -> [String],
        checkSpeechAssets: @escaping (String) async -> OigoLocaleAssetStatus,
        saveLanguage: @escaping (String) -> Void,
        saveStep: @escaping (OigoOnboardingStep, Bool) -> Void,
        saveInputSelection: @escaping (OigoInputSelection, Int) -> Void,
        requestMicrophone: @escaping () async -> OigoPermissionState,
        openMicrophoneSettings: @escaping () -> Void,
        registrationStatus: @escaping () -> GlobalShortcutRegistrationStatus,
        registrationError: @escaping () -> String?,
        validateShortcut: @escaping (ToggleShortcut) -> OigoShortcutValidation,
        saveShortcut: @escaping (ToggleShortcut) -> OigoShortcutValidation,
        requestAccessibility: @escaping () -> OigoPermissionState,
        openAccessibilitySettings: @escaping () -> Void,
        retryStorage: @escaping () -> Void,
        openDataLocation: @escaping () -> Void,
        startSourceProbe: @escaping (OigoInputSelection, Int, UInt64) -> Void,
        stopSourceProbe: @escaping () -> Void,
        startTest: @escaping (UInt64) -> Void,
        stopTest: @escaping () -> Void,
        cancelTest: @escaping () -> Void,
        openHistory: @escaping () -> Void,
        onComplete: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.support = support
        self.processingMode = processingMode
        self.currentStep = initialStep.migratedForFourStageFlow
        self.copyOnlySetupAccepted = copyOnlyAccepted
        self.selectedInput = selectedInput
        self.selectedInputChannel = OigoInputChannelPolicy.sanitized(selectedInputChannel)
        self.inputDevices = inputDevices
        localeSelection = OigoLocaleSelectionState(
            committedIdentifier: committedLocaleIdentifier,
            role: .onboarding,
            preferredIdentifier: committedLocaleIdentifier
        )
        self.loadSupportedLanguages = loadSupportedLanguages
        self.checkSpeechAssets = checkSpeechAssets
        self.saveLanguage = saveLanguage
        self.saveStep = saveStep
        self.saveInputSelection = saveInputSelection
        self.startSourceProbe = startSourceProbe
        self.stopSourceProbe = stopSourceProbe
        self.requestMicrophone = requestMicrophone
        self.openMicrophoneSettings = openMicrophoneSettings
        self.registrationStatus = registrationStatus
        self.registrationError = registrationError
        self.validateShortcut = validateShortcut
        self.saveShortcut = saveShortcut
        self.requestAccessibility = requestAccessibility
        self.openAccessibilitySettings = openAccessibilitySettings
        self.retryStorage = retryStorage
        self.openDataLocation = openDataLocation
        self.startTest = startTest
        self.stopTest = stopTest
        self.cancelTest = cancelTest
        self.openHistory = openHistory
        self.onComplete = onComplete
        self.onClose = onClose
        self.microphoneState = microphoneState
        self.accessibilityState = accessibilityState
        self.storageHealth = storageHealth
        committedShortcut = globalShortcut
        shortcutRecorder = ShortcutRecorderControl(shortcut: globalShortcut)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 640),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Oigo"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        evidence.setStorageHealth(storageHealth)
        evidence.setSelectedSource(input: selectedInput, channel: selectedInputChannel)
        configureInputMenu(devices: inputDevices, selected: selectedInput)
        configureChannelMenu()
        configureWindow()
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var isDrivingProductionTest: Bool {
        evidence.testRunning
    }

    func focusTestField() {
        window?.makeFirstResponder(testField)
    }

    func windowWillClose(_ notification: Notification) {
        _ = notification
        discardShortcutCandidate()
        releaseOnboardingResources(cancelActiveTest: true)
        if support.isSupported, !completed {
            saveInputSelection(selectedInputFromMenu(), selectedChannelFromMenu())
            saveStep(currentStep, copyOnlySetupAccepted)
        }
        onClose()
    }

    func showRegistrationFailure(_ message: String) {
        currentStep = .shortcut
        statusLabel.stringValue = "Global shortcut inactive: " + message
        render()
    }

    func showAndFocus() {
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if currentStep == .language, microphoneState == .granted, !evidence.probeActive {
            restartSourceProbe()
        }
    }

    func updateInputDevices(_ devices: [OigoInputDevice]) {
        selectedInput = selectedInputFromMenu()
        selectedInputChannel = selectedChannelFromMenu()
        inputDevices = devices
        configureInputMenu(devices: devices, selected: selectedInput)
        configureChannelMenu()
        applyCurrentSourceSelection()
        if currentStep == .language, microphoneState == .granted, !evidence.sourceUnavailable {
            restartSourceProbe()
        } else if currentStep == .language {
            releaseOnboardingResources(cancelActiveTest: false)
        }
        renderButtons()
    }

    func applySourceProbeUpdate(_ update: OigoOnboardingSourceProbeUpdate) {
        guard evidence.recordSourceProbe(update) else {
            return
        }
        meter.doubleValue = Double(update.meterLevel)
        renderButtons()
        if currentStep == .language {
            statusLabel.stringValue = microphoneStatusMessage()
        }
    }

    func bindTestSession(_ sessionID: UUID) {
        guard let generation = activeTestGeneration else {
            return
        }
        _ = evidence.bindSession(generation: generation, sessionID: sessionID)
    }

    func applyTestCompletion(
        generation: UInt64,
        sessionID: UUID?,
        report: OigoOnboardingProductionReport,
        selectedInsertionText: String
    ) {
        guard generation == activeTestGeneration else {
            return
        }
        var report = report
        if report.sessionID == nil {
            report.sessionID = sessionID
        } else if let sessionID, report.sessionID != sessionID {
            return
        }
        guard evidence.recordProductionPath(generation: generation, report: report) else {
            return
        }
        if report.insertionPath == .production,
           report.insertionOutcome == .pasted || report.insertionOutcome == .dispatched,
           evidence.outcome != .failed {
            verifyDestinationAfterPaste(
                generation: generation,
                selectedInsertionText: selectedInsertionText
            )
            return
        }
        activeTestGeneration = nil
        render()
    }

    private func configureWindow() {
        guard let contentView = window?.contentView else {
            return
        }
        shortcutRecorder.onValidationError = { [weak self] message in
            self?.statusLabel.stringValue = message
        }
        progressLabel.textColor = .secondaryLabelColor
        titleLabel.font = .boldSystemFont(ofSize: 22)
        bodyLabel.maximumNumberOfLines = 8
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 4
        checklistTitleLabel.font = .boldSystemFont(ofSize: 13)
        checklistStack.orientation = .vertical
        checklistStack.alignment = .leading
        checklistStack.spacing = 5
        checklistStack.translatesAutoresizingMaskIntoConstraints = false
        testField.placeholderString = "Speak after Start. This field must receive the paste."
        testField.isEditable = true
        testField.isSelectable = true
        testField.isEnabled = true
        testField.identifier = NSUserInterfaceItemIdentifier("oigo.onboarding.test-field")
        meter.minValue = 0
        meter.maxValue = 1
        meter.warningValue = 0.85
        meter.criticalValue = 0.98
        meter.levelIndicatorStyle = .continuousCapacity
        meter.heightAnchor.constraint(equalToConstant: 18).isActive = true
        shortcutRecorder.translatesAutoresizingMaskIntoConstraints = false
        languagePopup.target = self
        languagePopup.action = #selector(languageSelectionChanged)
        inputPopup.target = self
        inputPopup.action = #selector(inputSelectionChanged)
        channelPopup.target = self
        channelPopup.action = #selector(inputSelectionChanged)
        historyButton.target = self
        historyButton.action = #selector(openHistoryAction)
        retryStorageButton.target = self
        retryStorageButton.action = #selector(retryStorageAction)
        openDataLocationButton.target = self
        openDataLocationButton.action = #selector(openDataLocationAction)
        actionButton.target = self
        actionButton.action = #selector(performAction)
        skipButton.target = self
        skipButton.action = #selector(skipTestAction)
        copyOnlyButton.target = self
        copyOnlyButton.action = #selector(acceptCopyOnlyAction)
        quietOverrideButton.target = self
        quietOverrideButton.action = #selector(acceptQuietOverrideAction)
        backButton.target = self
        backButton.action = #selector(goBack)
        nextButton.target = self
        nextButton.action = #selector(goForward)

        inputRow.addArrangedSubview(inputLabel)
        inputRow.addArrangedSubview(inputPopup)
        inputRow.orientation = .horizontal
        inputRow.alignment = .centerY
        inputRow.spacing = 8
        inputLabel.setContentHuggingPriority(.required, for: .horizontal)
        channelRow.addArrangedSubview(channelLabel)
        channelRow.addArrangedSubview(channelPopup)
        channelRow.orientation = .horizontal
        channelRow.alignment = .centerY
        channelRow.spacing = 8
        channelLabel.setContentHuggingPriority(.required, for: .horizontal)
        languageRow.addArrangedSubview(languageLabel)
        languageRow.addArrangedSubview(languagePopup)
        languageRow.orientation = .horizontal
        languageRow.alignment = .centerY
        languageRow.spacing = 8
        languageLabel.setContentHuggingPriority(.required, for: .horizontal)
        let stack = NSStackView(views: [
            progressLabel,
            titleLabel,
            bodyLabel,
            inputRow,
            channelRow,
            meter,
            quietOverrideButton,
            languageRow,
            shortcutRecorder,
            testField,
            checklistTitleLabel,
            checklistStack,
            statusLabel,
            storageStatusLabel,
            retryStorageButton,
            openDataLocationButton,
            historyButton,
            actionButton,
            skipButton,
            copyOnlyButton,
            NSView(),
            NSStackView(views: [backButton, nextButton])
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        let buttons = stack.arrangedSubviews.last!
        (buttons as? NSStackView)?.spacing = 8
        (buttons as? NSStackView)?.alignment = .trailing
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -32),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24),
            bodyLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            checklistStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            storageStatusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            inputRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            channelRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            languageRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            meter.widthAnchor.constraint(equalTo: stack.widthAnchor),
            languagePopup.widthAnchor.constraint(equalToConstant: 280),
            shortcutRecorder.widthAnchor.constraint(equalToConstant: 280),
            inputPopup.widthAnchor.constraint(equalToConstant: 280),
            channelPopup.widthAnchor.constraint(equalToConstant: 280),
            testField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actionButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            historyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    private func render() {
        let isSupported = support.isSupported
        let stage = OigoOnboardingStage.from(legacyStep: currentStep)
        progressLabel.stringValue = isSupported
            ? stage == .done ? "Setup complete" : "Stage " + String(stage.ordinal) + " of 4"
            : "Setup unavailable"
        titleLabel.stringValue = isSupported ? stage.title : "This Mac cannot run Oigo"
        bodyLabel.stringValue = isSupported ? body(for: stage) : support.reason
        languageRow.isHidden = currentStep != .language
        shortcutRecorder.isHidden = currentStep != .shortcut
        inputRow.isHidden = currentStep != .language
        channelRow.isHidden = currentStep != .language
        meter.isHidden = currentStep != .language
        quietOverrideButton.isHidden = currentStep != .language
            || evidence.signalHealth != .silent
            || !evidence.acceptedCanonicalBuffer
        testField.isHidden = !isSupported || currentStep != .testDictation
        checklistTitleLabel.isHidden = !isSupported || currentStep != .testDictation
        checklistStack.isHidden = !isSupported || currentStep != .testDictation
        historyButton.isHidden = currentStep != .testDictation
            || !evidence.recoveryActions.contains(.openHistory)
        storageStatusLabel.isHidden = currentStep != .system && storageHealth.isReady
        retryStorageButton.isHidden = storageHealth.isReady
        openDataLocationButton.isHidden = storageHealth.isReady
        skipButton.isHidden = currentStep != .testDictation
        copyOnlyButton.isHidden = currentStep == .shortcut
            ? accessibilityState == .granted || copyOnlySetupAccepted
            : currentStep != .testDictation || !evidence.canAcceptCopyOnly
        statusLabel.stringValue = status(for: stage)
        renderChecklist()
        storageStatusLabel.stringValue = storageHealth.statusMessage
        storageStatusLabel.textColor = storageHealth.isReady ? .secondaryLabelColor : .systemOrange
        actionButton.isHidden = !isSupported || ![.language, .shortcut, .testDictation].contains(currentStep)
        backButton.isHidden = !isSupported || currentStep == .system
        nextButton.isHidden = !isSupported
        if !isSupported {
            actionButton.isHidden = true
            backButton.isHidden = true
            nextButton.title = "Close"
            nextButton.isHidden = false
        }
        if currentStep == .language {
            loadLanguagesIfNeeded()
            actionButton.title = microphoneState == .granted
                ? "Check speech assets"
                : microphoneState == .denied ? "Open Microphone Settings" : "Allow Microphone Access"
        } else if currentStep == .shortcut {
            actionButton.title = accessibilityRequestAttempted && accessibilityState == .denied
                ? "Open Accessibility Settings"
                : "Allow Accessibility (optional)"
        } else if currentStep == .testDictation {
            actionButton.title = onboardingTestAvailability.onboardingTestActionTitle
        }
        renderButtons()
    }

    private func renderButtons() {
        guard support.isSupported else {
            return
        }
        actionButton.isEnabled = true
        nextButton.title = currentStep == .complete ? "Finish setup" : "Continue"
        nextButton.isEnabled = true
        if currentStep == .language {
            nextButton.isEnabled = microphoneState == .granted
                && evidence.microphoneCanAdvance
                && localeSelection.canConfirm
        }
        if currentStep == .shortcut {
            nextButton.isEnabled = accessibilityState == .granted || copyOnlySetupAccepted
        }
        if currentStep == .testDictation {
            nextButton.isEnabled = evidence.canFinishReady
                && !onboardingTestAvailability.isOnboardingTestActive
            actionButton.isEnabled = storageHealth.isReady
                && onboardingTestAvailability.canUseOnboardingTestAction
            skipButton.isEnabled = true
        }
    }

    private func renderChecklist() {
        checklistStack.arrangedSubviews.forEach {
            checklistStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for row in evidence.checklist {
            let label = NSTextField(labelWithString: checklistText(row))
            label.maximumNumberOfLines = 2
            label.identifier = NSUserInterfaceItemIdentifier(
                "oigo.onboarding.checklist." + row.item.rawValue
            )
            checklistStack.addArrangedSubview(label)
        }
    }

    private func checklistText(_ row: OigoOnboardingChecklistRow) -> String {
        let marker: String
        switch row.status {
        case .pending:
            marker = "○"
        case .active:
            marker = "…"
        case .succeeded:
            marker = "✓"
        case .failed:
            marker = "!"
        }
        return marker + " " + row.item.title
    }

    func setStorageHealth(_ health: DurableSessionHealth) {
        storageHealth = health
        evidence.setStorageHealth(health)
        render()
    }

    func setCommandAvailability(_ availability: AppCommandAvailability) {
        commandAvailability = availability
        if currentStep == .testDictation {
            render()
        }
    }

    private var onboardingTestAvailability: AppCommandAvailability {
        commandAvailability ?? AppCommandAvailability.evaluate(
            coordinatorState: evidence.testRunning ? .recording : .idle,
            occupiedKind: evidence.testRunning ? .onboardingTest : nil,
            acceptingCommands: true,
            setupComplete: false,
            storageReady: storageHealth.isReady
        )
    }

    private func body(for stage: OigoOnboardingStage) -> String {
        switch stage {
        case .macAndStorage:
            "Oigo needs macOS 26 or later on Apple silicon. This check runs before setup so unsupported systems fail clearly."
        case .microphoneAndLanguage:
            "Choose the microphone, channel, and language Oigo will use. A local meter confirms the selected source produces a usable buffer, and speech assets are checked before your first valuable dictation."
        case .shortcutAndInsertion:
            "Choose a readable global shortcut. Accessibility enables automatic paste into the field you were using; if you decline, Oigo keeps Copy and History available."
        case .tryIt:
            "Focus the editable field below, then start and stop a real dictation. Setup records each production-path checkpoint and reports only what the owned test field proves."
        case .done:
            completionSummary()
        }
    }

    private func completionSummary() -> String {
        let input = switch selectedInput {
        case .systemDefault:
            "System Default"
        case .pinned(let uid):
            inputDevices.first(where: { $0.uid == uid })?.displayName ?? "Pinned microphone"
        }
        let pastePosture = accessibilityState == .granted
            ? "Automatic paste available"
            : "Copy-only fallback accepted"
        let assetPosture: String
        switch localeSelection.readiness.status {
        case .ready:
            assetPosture = "Ready"
        case .failed(let reason), .unavailable(let reason):
            assetPosture = reason
        case .idle, .checking, .installing, .unsupported:
            assetPosture = "Not verified"
        }
        let testResult: String
        switch evidence.outcome {
        case .passed:
            testResult = "Automatic paste verified"
        case .copyOnlyAccepted:
            testResult = "Copy-only accepted"
        case .skipped:
            testResult = "Test skipped"
        case .failed:
            testResult = "Test failed with recovery available"
        case .pending:
            testResult = "Test not completed"
        }
        return "Shortcut: \(committedShortcut.displayName)\n"
            + "Mode: \(processingMode.displayName)\n"
            + "Microphone: \(input), channel \(selectedInputChannel + 1)\n"
            + "Language: \(localeSelection.committedIdentifier) (assets: \(assetPosture))\n"
            + "Insertion: \(pastePosture)\n"
            + "Try It: \(testResult)\n"
            + "Storage: On this Mac; recovery: Open Data Location"
    }

    private func status(for stage: OigoOnboardingStage) -> String {
        switch stage {
        case .microphoneAndLanguage:
            if microphoneState != .granted || !evidence.microphoneCanAdvance {
                return microphoneStatusMessage()
            }
            return localeSelection.statusMessage
        case .shortcutAndInsertion:
            switch registrationStatus() {
            case .active(let shortcut, _):
                let suffix = registrationError().map { ". Last error: " + $0 } ?? ""
                return "Registered: " + shortcut.displayName + suffix + ". Candidate: " + shortcutRecorder.displayValue
            case .inactive(let message):
                return "Global shortcut inactive: " + (registrationError() ?? message)
            }
        case .tryIt:
            return evidence.statusMessage
        case .macAndStorage, .done:
            return ""
        }
    }

    @objc private func skipTestAction() {
        guard currentStep == .testDictation else {
            return
        }
        releaseOnboardingResources(cancelActiveTest: true)
        activeTestGeneration = nil
        evidence.skip()
        guard let next = nextStep(after: currentStep) else {
            return
        }
        currentStep = next
        saveStep(next, copyOnlySetupAccepted)
        render()
    }

    @objc private func acceptCopyOnlyAction() {
        if currentStep == .shortcut, accessibilityState != .granted {
            copyOnlySetupAccepted = true
            saveStep(.shortcut, true)
            statusLabel.stringValue = "Copy-only setup accepted. Automatic paste remains optional."
            renderButtons()
            return
        }
        if currentStep == .testDictation, evidence.acceptCopyOnly() {
            render()
        }
    }

    @objc private func acceptQuietOverrideAction() {
        guard currentStep == .language, evidence.acceptQuietOverride() else {
            return
        }
        render()
    }

    private func loadLanguagesIfNeeded() {
        guard localeMenuIdentifiers.isEmpty, !isLoadingLanguages else {
            return
        }
        isLoadingLanguages = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let languages = await loadSupportedLanguages()
            isLoadingLanguages = false
            localeSelection.loadSupported(languages)
            syncLanguagePopup()
            statusLabel.stringValue = localeSelection.statusMessage
            renderButtons()
        }
    }

    private func syncLanguagePopup() {
        let items = localeSelection.menuItems
        localeMenuIdentifiers = items.map(\.identifier)
        languagePopup.removeAllItems()
        languagePopup.addItems(withTitles: items.map(\.title))
        if let selected = localeSelection.selectedIdentifier,
           let index = items.firstIndex(where: { $0.identifier == selected }) {
            languagePopup.selectItem(at: index)
        }
    }

    @objc private func languageSelectionChanged() {
        guard currentStep == .language,
              let identifier = selectedLocaleFromMenu() else {
            return
        }
        localeSelection.select(identifier)
        statusLabel.stringValue = localeSelection.statusMessage
        renderButtons()
    }

    private func selectedLocaleFromMenu() -> String? {
        let index = languagePopup.indexOfSelectedItem
        guard localeMenuIdentifiers.indices.contains(index) else {
            return nil
        }
        return localeMenuIdentifiers[index]
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
        applyCurrentSourceSelection(unavailable: items.contains { $0.selection == selected && $0.isUnavailable })
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
        applyCurrentSourceSelection()
        saveInputSelection(selectedInput, selectedInputChannel)
        if currentStep == .language, microphoneState == .granted {
            restartSourceProbe()
        }
        render()
    }

    @objc private func performAction() {
        switch currentStep {
        case .language:
            if microphoneState != .granted {
                if microphoneState == .denied {
                    openMicrophoneSettings()
                } else {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        microphoneState = await requestMicrophone()
                        if microphoneState == .granted {
                            restartSourceProbe()
                        }
                        render()
                    }
                }
                return
            }
            guard let request = localeSelection.beginAssetRequest(status: .installing) else {
                statusLabel.stringValue = localeSelection.statusMessage
                renderButtons()
                return
            }
            statusLabel.stringValue = localeSelection.statusMessage
            actionButton.isEnabled = false
            renderButtons()
            Task { @MainActor [weak self] in
                guard let self else { return }
                let status = await checkSpeechAssets(request.localeIdentifier)
                _ = localeSelection.applyAssetResult(
                    localeIdentifier: request.localeIdentifier,
                    generation: request.generation,
                    status: status
                )
                actionButton.isEnabled = true
                render()
            }
        case .shortcut:
            if accessibilityRequestAttempted && accessibilityState == .denied {
                openAccessibilitySettings()
            } else {
                accessibilityRequestAttempted = true
                accessibilityState = requestAccessibility()
                statusLabel.stringValue = accessibilityState == .granted
                    ? "Automatic paste is ready."
                    : "Copy-only mode remains available. Open System Settings if you want automatic paste."
                render()
            }
        case .complete, .system, .microphone, .insertion, .recovery:
            return
        case .testDictation:
            let availability = onboardingTestAvailability
            if evidence.testRunning || availability.isOnboardingTestActive {
                guard availability.canStopDictation || availability.canCancelOnboardingTest else {
                    statusLabel.stringValue = availability.busyReason?.userMessage
                        ?? "Stop test dictation is unavailable."
                    render()
                    return
                }
                stopTest()
                render()
                return
            }
            guard availability.canRunOnboardingTest else {
                statusLabel.stringValue = availability.busyReason?.userMessage
                    ?? "Start test dictation is unavailable."
                render()
                return
            }
            guard storageHealth.isReady else {
                statusLabel.stringValue = OigoOnboardingEvidenceMachine.statusMessage(for: .storage)
                return
            }
            testField.stringValue = ""
            guard let generation = evidence.beginTest(
                destinationEditable: testField.isEditable && testField.isEnabled
            ) else {
                activeTestGeneration = nil
                statusLabel.stringValue = evidence.statusMessage
                render()
                return
            }
            activeTestGeneration = generation
            _ = evidence.markDestinationCleared(generation: generation)
            window?.makeFirstResponder(testField)
            startTest(generation)
            render()
        }
    }

    @objc private func goForward() {
        guard support.isSupported else {
            window?.close()
            return
        }
        if currentStep == .system, !storageHealth.isReady {
            statusLabel.stringValue = OigoOnboardingEvidenceMachine.statusMessage(for: .storage)
            renderButtons()
            return
        }
        if currentStep == .language {
            guard microphoneState == .granted,
                  evidence.microphoneCanAdvance,
                  localeSelection.canConfirm else {
                statusLabel.stringValue = microphoneStatusMessage()
                renderButtons()
                return
            }
        }
        if currentStep == .shortcut {
            let candidate = shortcutRecorder.shortcut
            let result = validateShortcut(candidate)
            guard result.isAvailable else {
                statusLabel.stringValue = "Global shortcut inactive: " + Self.validationMessage(result)
                renderButtons()
                return
            }
            let saved = saveShortcut(candidate)
            guard saved.isAvailable else {
                statusLabel.stringValue = "Global shortcut inactive: " + Self.validationMessage(saved)
                renderButtons()
                return
            }
            guard registrationStatus().isActive else {
                statusLabel.stringValue = "Global shortcut inactive: " + (registrationError() ?? "Registration is not active")
                renderButtons()
                return
            }
            committedShortcut = candidate
        }
        if currentStep == .language {
            guard let locale = localeSelection.confirm() else {
                statusLabel.stringValue = localeSelection.statusMessage
                renderButtons()
                return
            }
            saveLanguage(locale)
            selectedInput = selectedInputFromMenu()
            selectedInputChannel = selectedChannelFromMenu()
            saveInputSelection(selectedInput, selectedInputChannel)
        }
        if currentStep == .testDictation, !evidence.canFinishReady {
            statusLabel.stringValue = evidence.statusMessage
            renderButtons()
            return
        }
        if currentStep == .shortcut, accessibilityState != .granted, !copyOnlySetupAccepted {
            statusLabel.stringValue = "Allow Accessibility or choose Continue with copy-only."
            renderButtons()
            return
        }
        guard let next = nextStep(after: currentStep) else {
            completed = true
            releaseOnboardingResources(cancelActiveTest: false)
            onComplete()
            window?.close()
            return
        }
        moveToStep(next)
    }

    @objc private func goBack() {
        discardShortcutCandidate()
        guard let previous = previousStep(before: currentStep) else { return }
        moveToStep(previous)
    }

    @objc private func openHistoryAction() {
        openHistory()
    }

    @objc private func retryStorageAction() {
        retryStorage()
    }

    @objc private func openDataLocationAction() {
        openDataLocation()
    }

    private func nextStep(after step: OigoOnboardingStep) -> OigoOnboardingStep? {
        switch step {
        case .system: .language
        case .language, .microphone: .shortcut
        case .shortcut, .insertion: .testDictation
        case .testDictation, .recovery: .complete
        case .complete: nil
        }
    }

    private func previousStep(before step: OigoOnboardingStep) -> OigoOnboardingStep? {
        switch step {
        case .system: nil
        case .language, .microphone: .system
        case .shortcut, .insertion: .language
        case .testDictation, .recovery: .shortcut
        case .complete: .testDictation
        }
    }

    private func discardShortcutCandidate() {
        shortcutRecorder.cancelRecording()
        shortcutRecorder.restoreCandidate(committedShortcut)
    }

    private func moveToStep(_ step: OigoOnboardingStep) {
        let leavingMicrophone = currentStep == .language && step != .language
        let leavingTest = currentStep == .testDictation && step != .testDictation
        if leavingMicrophone || leavingTest {
            releaseOnboardingResources(cancelActiveTest: leavingTest)
        }
        currentStep = step
        if currentStep == .language {
            localeSelection.revalidate()
        }
        if currentStep == .language, microphoneState == .granted {
            restartSourceProbe()
        }
        if currentStep == .testDictation {
            testField.stringValue = ""
        }
        saveStep(step, copyOnlySetupAccepted)
        render()
    }

    private func applyCurrentSourceSelection(unavailable: Bool? = nil) {
        let items = OigoInputMenu.items(devices: inputDevices, selected: selectedInput)
        let isUnavailable = unavailable ?? items.contains {
            $0.selection == selectedInput && $0.isUnavailable
        }
        evidence.setSelectedSource(
            input: selectedInput,
            channel: selectedInputChannel,
            unavailable: isUnavailable
        )
    }

    private func restartSourceProbe() {
        meter.doubleValue = 0
        let generation = evidence.beginSourceProbe()
        startSourceProbe(selectedInput, selectedInputChannel, generation)
    }

    private func releaseOnboardingResources(cancelActiveTest: Bool) {
        evidence.leaveMicrophoneStep()
        stopSourceProbe()
        meter.doubleValue = 0
        if cancelActiveTest {
            activeTestGeneration = nil
            if evidence.testRunning {
                cancelTest()
            }
        }
    }

    private func microphoneStatusMessage() -> String {
        if microphoneState != .granted {
            return "Current microphone state: " + microphoneState.rawValue.capitalized
        }
        if let failedStage = evidence.failedStage,
           failedStage == .selectedSource || failedStage == .canonicalBuffer {
            return OigoOnboardingEvidenceMachine.statusMessage(for: failedStage)
        }
        if evidence.microphoneCanAdvance {
            return "Selected source produced a usable buffer."
        }
        if evidence.acceptedCanonicalBuffer, evidence.signalHealth == .silent {
            return "The selected source is unusually quiet. Retry or continue with a quiet environment."
        }
        if evidence.acceptedCanonicalBuffer, evidence.signalHealth == .clipped {
            return "The selected source looks clipped. Retry after lowering the input level."
        }
        return "Waiting for a usable buffer from the selected source."
    }

    private func verifyDestinationAfterPaste(
        generation: UInt64,
        selectedInsertionText: String
    ) {
        let deadline = Date().addingTimeInterval(0.25)
        while Date() < deadline {
            guard generation == activeTestGeneration, generation == evidence.generation else {
                return
            }
            if !isTestFieldStillSelected() {
                finishDestinationVerification(
                    generation: generation,
                    selectedInsertionText: selectedInsertionText,
                    eventBoundaryCompleted: false,
                    failure: .targetChanged
                )
                return
            }
            if fieldMatchesDurableText(selectedInsertionText) {
                finishDestinationVerification(
                    generation: generation,
                    selectedInsertionText: selectedInsertionText,
                    eventBoundaryCompleted: true
                )
                return
            }
            pumpPostedAppKitEvents(until: min(Date().addingTimeInterval(0.01), deadline))
        }
        guard generation == activeTestGeneration, generation == evidence.generation else {
            return
        }
        if fieldMatchesDurableText(selectedInsertionText) {
            finishDestinationVerification(
                generation: generation,
                selectedInsertionText: selectedInsertionText,
                eventBoundaryCompleted: true
            )
            return
        }
        let hasOtherText = !testField.stringValue.isEmpty
        finishDestinationVerification(
            generation: generation,
            selectedInsertionText: selectedInsertionText,
            eventBoundaryCompleted: hasOtherText,
            failure: hasOtherText ? .mismatch : .timeout
        )
    }

    private func isTestFieldStillSelected() -> Bool {
        OigoOnboardingDestinationFocus.isStillSelected(
            firstResponder: window?.firstResponder.map(ObjectIdentifier.init),
            field: ObjectIdentifier(testField),
            fieldEditor: testField.currentEditor().map(ObjectIdentifier.init)
        )
    }

    private func fieldMatchesDurableText(_ selectedInsertionText: String) -> Bool {
        !selectedInsertionText.isEmpty && testField.stringValue == selectedInsertionText
    }

    private func pumpPostedAppKitEvents(until deadline: Date) {
        while Date() < deadline {
            guard let event = NSApp.nextEvent(
                matching: .any,
                until: deadline,
                inMode: .default,
                dequeue: true
            ) else {
                _ = CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.01, true)
                return
            }
            NSApp.sendEvent(event)
        }
    }

    private func finishDestinationVerification(
        generation: UInt64,
        selectedInsertionText: String,
        eventBoundaryCompleted: Bool,
        failure: OigoOnboardingDestinationFailure? = nil
    ) {
        let matches = fieldMatchesDurableText(selectedInsertionText)
        _ = evidence.completeDestinationVerification(
            generation: generation,
            fieldMatchesDurableSelectedText: matches,
            eventBoundaryCompleted: eventBoundaryCompleted,
            failure: failure
        )
        activeTestGeneration = nil
        render()
    }

    private static func validationMessage(_ validation: OigoShortcutValidation) -> String {
        switch validation {
        case .available:
            "Registration is active"
        case .conflict(let reason), .invalid(let reason):
            reason
        }
    }
}
