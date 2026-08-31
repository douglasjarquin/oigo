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
    private var languageLoadGeneration: UInt64 = 0
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
    private var shortcutValidation: OigoShortcutValidation = .available
    private var committedShortcutCopy: OigoShortcutCopy {
        committedShortcut.copy
    }
    private var inputMenuSelections: [OigoInputSelection] = []
    private var selectedInput: OigoInputSelection
    private var selectedInputChannel: Int
    private var inputDevices: [OigoInputDevice]

    private let progressLabel = NSTextField(labelWithString: "")
    private let chromeTitleLabel = NSTextField(labelWithString: "Set Up Oigo")
    private let progressStages = NSStackView()
    private var progressStageLabels: [NSTextField] = []
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

        let window = OigoUtilityWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: OigoOnboardingShellMetrics.windowWidth,
                height: 680
            ),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = OigoOnboardingShellMetrics.title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: OigoOnboardingShellMetrics.windowWidth, height: 520)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.onEscape = { [weak self] in
            guard let self else { return }
            var available: Set<OigoEscapeAction> = [.closeUtilityWindow]
            if shortcutRecorder.isRecording { available.insert(.cancelEditor) }
            if evidence.probeActive { available.insert(.stopOnboardingProbe) }
            if evidence.testRunning { available.insert(.cancelBoundedHandoff) }
            switch OigoUIIntegrationPolicy.resolveEscapeAction(from: available) {
            case .cancelEditor:
                shortcutRecorder.cancelRecording()
            case .stopOnboardingProbe:
                stopSourceProbe()
            case .cancelBoundedHandoff:
                cancelTest()
            default:
                self.window?.performClose(nil)
            }
        }
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
        languageLoadGeneration &+= 1
        isLoadingLanguages = false
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
        shortcutValidation = .conflict(message)
        render()
    }

    func showAndFocus() {
        showWindow(nil)
        if let window {
            var frame = window.frame
            frame.size = NSSize(width: OigoOnboardingShellMetrics.windowWidth, height: 680)
            window.setFrame(frame, display: false)
        }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        focusCurrentStage()
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
        if let closeButton = window?.standardWindowButton(.closeButton) {
            closeButton.identifier = NSUserInterfaceItemIdentifier("oigo.onboarding.close")
            closeButton.setAccessibilityIdentifier("oigo.onboarding.close")
            closeButton.setAccessibilityLabel("Close")
        }
        shortcutRecorder.onValidationError = { [weak self] message in
            guard let self else { return }
            shortcutValidation = .invalid(message)
            statusLabel.stringValue = committedShortcutCopy.preservedMessage(message)
            renderButtons()
        }
        shortcutRecorder.onCandidateChange = { [weak self] candidate in
            guard let self, currentStep == .shortcut else { return }
            shortcutValidation = validateShortcut(candidate)
            render()
        }
        progressLabel.identifier = NSUserInterfaceItemIdentifier("oigo.onboarding.progress")
        progressLabel.setAccessibilityIdentifier("oigo.onboarding.progress")
        titleLabel.identifier = NSUserInterfaceItemIdentifier("oigo.onboarding.title")
        titleLabel.setAccessibilityIdentifier("oigo.onboarding.title")
        bodyLabel.identifier = NSUserInterfaceItemIdentifier("oigo.onboarding.body")
        bodyLabel.setAccessibilityIdentifier("oigo.onboarding.body")
        statusLabel.identifier = NSUserInterfaceItemIdentifier("oigo.onboarding.status")
        statusLabel.setAccessibilityIdentifier("oigo.onboarding.status")
        progressLabel.textColor = .secondaryLabelColor
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        progressStageLabels = OigoOnboardingShellLayout.configureProgress(
            progressStages,
            titles: OigoOnboardingShellMetrics.stageTitles
        )
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
        testField.setAccessibilityIdentifier("oigo.onboarding.test-field")
        testField.setAccessibilityLabel("Dictation test field")
        meter.minValue = 0
        meter.maxValue = 1
        meter.warningValue = 0.85
        meter.criticalValue = 0.98
        meter.levelIndicatorStyle = .continuousCapacity
        meter.heightAnchor.constraint(equalToConstant: 18).isActive = true
        shortcutRecorder.translatesAutoresizingMaskIntoConstraints = false
        shortcutRecorder.identifier = NSUserInterfaceItemIdentifier("oigo.onboarding.shortcut-recorder")
        shortcutRecorder.setAccessibilityIdentifier("oigo.onboarding.shortcut-recorder")
        shortcutRecorder.setAccessibilityLabel("Dictation shortcut")
        languagePopup.identifier = NSUserInterfaceItemIdentifier("oigo.onboarding.language")
        languagePopup.setAccessibilityIdentifier("oigo.onboarding.language")
        languagePopup.setAccessibilityLabel("Transcription language")
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
        retryStorageButton.identifier = NSUserInterfaceItemIdentifier("oigo.onboarding.retry-storage")
        retryStorageButton.setAccessibilityIdentifier("oigo.onboarding.retry-storage")
        openDataLocationButton.target = self
        openDataLocationButton.action = #selector(openDataLocationAction)
        openDataLocationButton.identifier = NSUserInterfaceItemIdentifier("oigo.onboarding.open-data-location")
        openDataLocationButton.setAccessibilityIdentifier("oigo.onboarding.open-data-location")
        actionButton.target = self
        actionButton.action = #selector(performAction)
        actionButton.identifier = NSUserInterfaceItemIdentifier("oigo.onboarding.stage-action")
        actionButton.setAccessibilityIdentifier("oigo.onboarding.stage-action")
        skipButton.target = self
        skipButton.action = #selector(skipTestAction)
        skipButton.identifier = NSUserInterfaceItemIdentifier("oigo.onboarding.skip")
        skipButton.setAccessibilityIdentifier("oigo.onboarding.skip")
        copyOnlyButton.target = self
        copyOnlyButton.action = #selector(acceptCopyOnlyAction)
        copyOnlyButton.identifier = NSUserInterfaceItemIdentifier("oigo.onboarding.copy-only")
        copyOnlyButton.setAccessibilityIdentifier("oigo.onboarding.copy-only")
        copyOnlyButton.setAccessibilityLabel(copyOnlyButton.title)
        quietOverrideButton.target = self
        quietOverrideButton.action = #selector(acceptQuietOverrideAction)
        backButton.target = self
        backButton.action = #selector(goBack)
        backButton.identifier = NSUserInterfaceItemIdentifier("oigo.onboarding.back")
        backButton.setAccessibilityIdentifier("oigo.onboarding.back")
        backButton.bezelStyle = .rounded
        backButton.setAccessibilityLabel("Back")
        nextButton.target = self
        nextButton.action = #selector(goForward)
        nextButton.identifier = NSUserInterfaceItemIdentifier("oigo.onboarding.continue")
        nextButton.setAccessibilityIdentifier("oigo.onboarding.continue")
        nextButton.bezelStyle = .rounded
        nextButton.keyEquivalent = "\r"
        nextButton.setAccessibilityLabel("Continue")

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
            progressStages,
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
        OigoOnboardingShellLayout.install(
            window: window!,
            contentView: contentView,
            chromeTitleLabel: chromeTitleLabel,
            progressStages: progressStages,
            stack: stack,
            backButton: backButton,
            nextButton: nextButton
        )
        NSLayoutConstraint.activate([
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
            shortcutRecorder.heightAnchor.constraint(equalToConstant: 44),
            inputPopup.widthAnchor.constraint(equalToConstant: 280),
            channelPopup.widthAnchor.constraint(equalToConstant: 280),
            testField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actionButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            historyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
        ])
    }

    private func render() {
        let isSupported = support.isSupported
        let stage = OigoOnboardingStage.from(legacyStep: currentStep)
        progressLabel.stringValue = isSupported
            ? stage == .done ? "Setup complete" : "Stage " + String(stage.ordinal) + " of 4"
            : "Setup unavailable"
        titleLabel.stringValue = isSupported ? stage.title : "This Mac cannot run Oigo"
        let activeOrdinal = stage.ordinal
        for (index, label) in progressStageLabels.enumerated() {
            let isActive = activeOrdinal == index + 1
            let isComplete = activeOrdinal > index + 1
            label.textColor = isActive || isComplete ? .controlAccentColor : .secondaryLabelColor
            label.font = .systemFont(ofSize: 11, weight: isActive ? .semibold : .medium)
            label.setAccessibilityLabel(
                "Stage " + String(index + 1) + ". "
                    + label.stringValue.drop(while: { $0.isNumber || $0 == " " })
                    + (isActive ? ". Current stage" : isComplete ? ". Complete" : ". Not started")
            )
        }
        bodyLabel.stringValue = isSupported ? body(for: stage) : support.reason
        titleLabel.setAccessibilityLabel(titleLabel.stringValue)
        bodyLabel.setAccessibilityLabel(bodyLabel.stringValue)
        progressLabel.setAccessibilityLabel(progressLabel.stringValue)
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
        statusLabel.setAccessibilityLabel(statusLabel.stringValue)
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
        actionButton.setAccessibilityLabel(actionButton.title)
        renderButtons()
    }

    private func renderButtons() {
        guard support.isSupported else {
            return
        }
        actionButton.isEnabled = true
        nextButton.title = currentStep == .complete ? "Finish setup" : "Continue"
        nextButton.setAccessibilityLabel(nextButton.title)
        nextButton.isEnabled = true
        if currentStep == .system {
            nextButton.isEnabled = storageHealth.isReady
        }
        if currentStep == .language {
            nextButton.isEnabled = microphoneState == .granted
                && evidence.microphoneCanAdvance
                && localeSelection.canConfirm
        }
        if currentStep == .shortcut {
            nextButton.isEnabled = (accessibilityState == .granted || copyOnlySetupAccepted)
                && shortcutValidation.isAvailable
                && !shortcutRecorder.isRecording
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
            let label = NSTextField(wrappingLabelWithString: checklistText(row))
            label.maximumNumberOfLines = 2
            label.lineBreakMode = .byWordWrapping
            label.translatesAutoresizingMaskIntoConstraints = false
            label.identifier = NSUserInterfaceItemIdentifier(
                "oigo.onboarding.checklist." + row.item.rawValue
            )
            checklistStack.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: checklistStack.widthAnchor).isActive = true
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
            "Oigo checks that this Mac can record durably before anything else."
        case .microphoneAndLanguage:
            "Choose what Oigo listens to and which language it transcribes."
        case .shortcutAndInsertion:
            "Hold a global shortcut to dictate. Accessibility enables automatic paste."
        case .tryIt:
            "One real dictation, end to end, into a field Oigo owns."
        case .done:
            "You can change any of this later in Settings.\n" + completionSummary()
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
        return "Shortcut: \(committedShortcutCopy.displayName)\n"
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
            if !shortcutValidation.isAvailable {
                return committedShortcutCopy.preservedMessage(
                    Self.validationMessage(shortcutValidation)
                )
            }
            if accessibilityState != .granted, copyOnlySetupAccepted {
                let saveGuidance = shortcutRecorder.shortcut == committedShortcut
                    ? committedShortcutCopy.savedPendingActivationStatus
                    : "Current shortcut: " + committedShortcutCopy.displayName
                        + ". Continue to save the recorded candidate."
                return "Copy-only setup accepted. " + saveGuidance
            }
            if shortcutRecorder.shortcut != committedShortcut {
                return "Current shortcut: " + committedShortcutCopy.displayName
                    + ". Continue to save the recorded candidate."
            }
            switch registrationStatus() {
            case .active:
                let suffix = registrationError().map { ". Last error: " + $0 } ?? ""
                return committedShortcutCopy.registeredStatus + suffix
                    + ". Candidate: " + shortcutRecorder.displayValue
            case .inactive(let message):
                if message == "Global shortcut registration is waiting for setup" {
                    return committedShortcutCopy.savedPendingActivationStatus
                }
                return committedShortcutCopy.unavailableMessage(registrationError() ?? message)
            }
        case .tryIt:
            return evidence.statusMessage
        case .macAndStorage, .done:
            return ""
        }
    }

    func task8ShortcutObservation() -> Task8ControlObservation {
        render()
        return Task8ControlObservation(
            status: statusLabel.stringValue,
            hint: bodyLabel.stringValue,
            recorderDisplay: shortcutRecorder.displayValue,
            recorderAccessibilityValue: shortcutRecorder.accessibilityValue() as? String ?? ""
        )
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
            statusLabel.stringValue = "Copy-only setup accepted. Dictation results stay available in Copy and History."
            render()
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
        languageLoadGeneration &+= 1
        let requestGeneration = languageLoadGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            let languages = await loadSupportedLanguages()
            guard self.currentStep == .language,
                  self.languageLoadGeneration == requestGeneration else {
                return
            }
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
        languageLoadGeneration &+= 1
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
            let requestGeneration = languageLoadGeneration
            Task { @MainActor [weak self] in
                guard let self else { return }
                let status = await checkSpeechAssets(request.localeIdentifier)
                guard self.currentStep == .language,
                      self.languageLoadGeneration == requestGeneration else {
                    return
                }
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
            guard accessibilityState == .granted || copyOnlySetupAccepted else {
                statusLabel.stringValue = "Allow Accessibility or choose Continue with copy-only."
                renderButtons()
                return
            }
            let candidate = shortcutRecorder.shortcut
            let result = validateShortcut(candidate)
            shortcutValidation = result
            guard result.isAvailable else {
                statusLabel.stringValue = committedShortcutCopy.preservedMessage(
                    Self.validationMessage(result)
                )
                renderButtons()
                return
            }
            let saved = saveShortcut(candidate)
            shortcutValidation = saved
            guard saved.isAvailable else {
                shortcutRecorder.restoreCandidate(committedShortcut)
                statusLabel.stringValue = committedShortcutCopy.preservedMessage(
                    Self.validationMessage(saved)
                )
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
        shortcutValidation = .available
    }

    private func moveToStep(_ step: OigoOnboardingStep) {
        if currentStep == .language, step != .language {
            languageLoadGeneration &+= 1
            isLoadingLanguages = false
        }
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
        focusCurrentStage()
    }

    private func focusCurrentStage() {
        guard let window else { return }
        let target: NSView
        switch currentStep {
        case .system, .complete, .microphone, .insertion, .recovery:
            target = nextButton
        case .language:
            target = languagePopup
        case .shortcut:
            target = shortcutRecorder
        case .testDictation:
            target = testField
        }
        _ = window.makeFirstResponder(target)
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
