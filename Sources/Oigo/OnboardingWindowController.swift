import AppKit
import OigoCore
import OigoHotKey

@available(macOS 26.0, *)
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let support: OigoSystemSupportResult
    private let loadSupportedLanguages: () async -> [String]
    private let checkSpeechAssets: (String) async -> OigoLocaleAssetStatus
    private let saveLanguage: (String) -> Void
    private let saveStep: (OigoOnboardingStep) -> Void
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
    private let startTest: () -> Void
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
        globalShortcut: ToggleShortcut,
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
        saveStep: @escaping (OigoOnboardingStep) -> Void,
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
        startTest: @escaping () -> Void,
        stopTest: @escaping () -> Void,
        cancelTest: @escaping () -> Void,
        openHistory: @escaping () -> Void,
        onComplete: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.support = support
        self.currentStep = initialStep
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
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
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
            saveStep(currentStep)
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
        if currentStep == .microphone, microphoneState == .granted, !evidence.probeActive {
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
        if currentStep == .microphone {
            restartSourceProbe()
        }
        renderButtons()
    }

    func applySourceProbeUpdate(_ update: OigoOnboardingSourceProbeUpdate) {
        guard evidence.recordSourceProbe(update) else {
            return
        }
        meter.doubleValue = Double(update.meterLevel)
        renderButtons()
        if currentStep == .microphone {
            statusLabel.stringValue = microphoneStatusMessage()
        }
    }

    func applyTestCompletion(
        report: OigoOnboardingProductionReport,
        selectedInsertionText: String
    ) {
        guard let generation = activeTestGeneration,
              evidence.recordProductionPath(generation: generation, report: report) else {
            return
        }
        activeTestGeneration = nil
        if report.insertionPath == .production,
           report.insertionOutcome == .pasted || report.insertionOutcome == .dispatched {
            Task { @MainActor [weak self] in
                await Self.waitForEventBoundary()
                self?.finishDestinationVerification(
                    generation: generation,
                    selectedInsertionText: selectedInsertionText
                )
            }
            return
        }
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
        let stack = NSStackView(views: [
            progressLabel,
            titleLabel,
            bodyLabel,
            inputRow,
            channelRow,
            meter,
            quietOverrideButton,
            languagePopup,
            shortcutRecorder,
            testField,
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
            storageStatusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            inputRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            channelRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
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
        progressLabel.stringValue = isSupported
            ? "Step " + String(min(currentStep.ordinal, 7)) + " of 7"
            : "Setup unavailable"
        titleLabel.stringValue = isSupported ? currentStep.title : "This Mac cannot run Oigo"
        bodyLabel.stringValue = isSupported ? body(for: currentStep) : support.reason
        languagePopup.isHidden = currentStep != .language
        shortcutRecorder.isHidden = currentStep != .shortcut
        inputRow.isHidden = currentStep != .microphone
        channelRow.isHidden = currentStep != .microphone
        meter.isHidden = currentStep != .microphone
        quietOverrideButton.isHidden = currentStep != .microphone
            || evidence.signalHealth != .silent
            || !evidence.acceptedCanonicalBuffer
        testField.isHidden = !isSupported || currentStep != .testDictation
        historyButton.isHidden = currentStep != .recovery && evidence.failedStage != .durableCAF
            && evidence.failedStage != .speech
            && evidence.failedStage != .destinationVerification
        storageStatusLabel.isHidden = storageHealth.isReady
        retryStorageButton.isHidden = storageHealth.isReady
        openDataLocationButton.isHidden = storageHealth.isReady
        skipButton.isHidden = currentStep != .testDictation
        copyOnlyButton.isHidden = currentStep != .testDictation || !evidence.canAcceptCopyOnly
        statusLabel.stringValue = status(for: currentStep)
        storageStatusLabel.stringValue = storageHealth.statusMessage
        storageStatusLabel.textColor = storageHealth.isReady ? .secondaryLabelColor : .systemOrange
        actionButton.isHidden = !isSupported || ![.language, .microphone, .insertion, .testDictation].contains(currentStep)
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
            actionButton.title = "Check speech assets"
        } else if currentStep == .microphone {
            actionButton.title = microphoneState == .denied ? "Open Microphone Settings" : "Allow Microphone Access"
        } else if currentStep == .insertion {
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
        nextButton.title = currentStep == .recovery ? "Finish setup" : "Continue"
        nextButton.isEnabled = currentStep != .microphone || microphoneState == .granted
        if currentStep == .language {
            nextButton.isEnabled = localeSelection.canConfirm
        }
        if currentStep == .microphone {
            nextButton.isEnabled = microphoneState == .granted && evidence.microphoneCanAdvance
        }
        if currentStep == .testDictation {
            nextButton.isEnabled = evidence.canFinishReady
                && !onboardingTestAvailability.isOnboardingTestActive
            actionButton.isEnabled = storageHealth.isReady
                && onboardingTestAvailability.canUseOnboardingTestAction
            skipButton.isEnabled = true
        }
        if currentStep == .recovery {
            nextButton.isEnabled = evidence.canFinishReady && registrationStatus().isActive
        }
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

    private func body(for step: OigoOnboardingStep) -> String {
        switch step {
        case .system:
            "Oigo needs macOS 26 or later on Apple silicon. This check runs before setup so unsupported systems fail clearly."
        case .language:
            "Choose a language supported by Oigo's on-device speech module. Oigo picks the closest supported system locale and checks speech assets before your first valuable dictation."
        case .microphone:
            "Choose the microphone and channel Oigo will record. A local meter confirms the selected source produces a usable buffer. We ask for microphone access only after this explanation."
        case .shortcut:
            "Choose a readable global shortcut. The shipped default is \(ToggleShortcut.default.displayName), and Oigo keeps the previous working choice when registration fails."
        case .insertion:
            "Accessibility lets Oigo paste one completed transcript into the field you were using. If you decline, Copy and History still work."
        case .testDictation:
            "Focus the editable field below, then start and stop a real dictation. Setup passes only when that field receives the inserted transcript."
        case .recovery:
            "History is available from the Oigo menu bar item. It keeps saved recordings and lets you retry a failed transcription."
        case .complete:
            "Oigo is ready."
        }
    }

    private func status(for step: OigoOnboardingStep) -> String {
        switch step {
        case .microphone:
            return microphoneStatusMessage()
        case .insertion:
            return "Current Accessibility state: " + accessibilityState.rawValue.capitalized
        case .shortcut:
            switch registrationStatus() {
            case .active(let shortcut, _):
                let suffix = registrationError().map { ". Last error: " + $0 } ?? ""
                return "Registered: " + shortcut.displayName + suffix + ". Candidate: " + shortcutRecorder.displayValue
            case .inactive(let message):
                return "Global shortcut inactive: " + (registrationError() ?? message)
            }
        case .testDictation:
            return evidence.statusMessage
        case .language:
            return localeSelection.statusMessage
        default:
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
        saveStep(next)
        render()
    }

    @objc private func acceptCopyOnlyAction() {
        guard currentStep == .testDictation, evidence.acceptCopyOnly() else {
            return
        }
        render()
    }

    @objc private func acceptQuietOverrideAction() {
        guard currentStep == .microphone, evidence.acceptQuietOverride() else {
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
        if currentStep == .microphone, microphoneState == .granted {
            restartSourceProbe()
        }
        render()
    }

    @objc private func performAction() {
        switch currentStep {
        case .language:
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
                let applied = localeSelection.applyAssetResult(
                    localeIdentifier: request.localeIdentifier,
                    generation: request.generation,
                    status: status
                )
                if applied {
                    statusLabel.stringValue = localeSelection.statusMessage
                }
                actionButton.isEnabled = true
                renderButtons()
            }
        case .microphone:
            if microphoneState == .denied {
                openMicrophoneSettings()
            } else {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    microphoneState = await requestMicrophone()
                    if microphoneState == .granted {
                        restartSourceProbe()
                    }
                    statusLabel.stringValue = microphoneStatusMessage()
                    render()
                }
            }
        case .insertion:
            if accessibilityRequestAttempted && accessibilityState == .denied {
                openAccessibilitySettings()
            } else {
                accessibilityRequestAttempted = true
                accessibilityState = requestAccessibility()
                statusLabel.stringValue = accessibilityState == .granted
                    ? "Automatic paste is ready."
                    : "Copy-only mode remains available. Open System Settings if you want automatic paste."
                if accessibilityState == .denied {
                    actionButton.title = "Open Accessibility Settings"
                }
                renderButtons()
            }
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
            startTest()
            render()
        default:
            break
        }
    }

    @objc private func goForward() {
        guard support.isSupported else {
            window?.close()
            return
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
        }
        if currentStep == .recovery, !evidence.canFinishReady {
            statusLabel.stringValue = storageHealth.isReady
                ? evidence.statusMessage
                : OigoOnboardingEvidenceMachine.statusMessage(for: .storage)
            return
        }
        if currentStep == .testDictation, !evidence.canFinishReady {
            statusLabel.stringValue = evidence.statusMessage
            renderButtons()
            return
        }
        if currentStep == .microphone {
            guard microphoneState == .granted, evidence.microphoneCanAdvance else {
                statusLabel.stringValue = microphoneStatusMessage()
                renderButtons()
                return
            }
            selectedInput = selectedInputFromMenu()
            selectedInputChannel = selectedChannelFromMenu()
            saveInputSelection(selectedInput, selectedInputChannel)
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
        case .language: .microphone
        case .microphone: .shortcut
        case .shortcut: .insertion
        case .insertion: .testDictation
        case .testDictation: .recovery
        case .recovery, .complete: nil
        }
    }

    private func previousStep(before step: OigoOnboardingStep) -> OigoOnboardingStep? {
        switch step {
        case .system, .complete: nil
        case .language: .system
        case .microphone: .language
        case .shortcut: .microphone
        case .insertion: .shortcut
        case .testDictation: .insertion
        case .recovery: .testDictation
        }
    }

    private func discardShortcutCandidate() {
        shortcutRecorder.cancelRecording()
        shortcutRecorder.restoreCandidate(committedShortcut)
    }

    private func moveToStep(_ step: OigoOnboardingStep) {
        let leavingMicrophone = currentStep == .microphone && step != .microphone
        let leavingTest = currentStep == .testDictation && step != .testDictation
        if leavingMicrophone || leavingTest {
            releaseOnboardingResources(cancelActiveTest: leavingTest)
        }
        currentStep = step
        if currentStep == .language {
            localeSelection.revalidate()
        }
        if currentStep == .microphone, microphoneState == .granted {
            restartSourceProbe()
        }
        if currentStep == .testDictation {
            testField.stringValue = ""
        }
        saveStep(step)
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
        if cancelActiveTest, evidence.testRunning {
            cancelTest()
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

    private func finishDestinationVerification(
        generation: UInt64,
        selectedInsertionText: String
    ) {
        let matches = testField.stringValue == selectedInsertionText && !selectedInsertionText.isEmpty
        _ = evidence.completeDestinationVerification(
            generation: generation,
            fieldMatchesDurableSelectedText: matches,
            eventBoundaryCompleted: true
        )
        render()
    }

    private static func waitForEventBoundary() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
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
