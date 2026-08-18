import AppKit
import OigoCore
import OigoTranscription
import OigoHotKey

@available(macOS 26.0, *)
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let support: OigoSystemSupportResult
    private let loadSupportedLanguages: () async -> [String]
    private let checkSpeechAssets: (String) async -> SpeechAssetState
    private let saveLanguage: (String) -> Void
    private let saveStep: (OigoOnboardingStep) -> Void
    private let requestMicrophone: () async -> OigoPermissionState
    private let openMicrophoneSettings: () -> Void
    private let registrationStatus: () -> GlobalShortcutRegistrationStatus
    private let registrationError: () -> String?
    private let validateShortcut: (ToggleShortcut) -> OigoShortcutValidation
    private let saveShortcut: (ToggleShortcut) -> OigoShortcutValidation
    private let requestAccessibility: () -> OigoPermissionState
    private let openAccessibilitySettings: () -> Void
    private let startTest: () -> Void
    private let stopTest: () -> Void
    private let cancelTest: () -> Void
    private let openHistory: () -> Void
    private let onComplete: () -> Void
    private let onClose: () -> Void

    private var currentStep: OigoOnboardingStep
    private var languageReady = false
    private var microphoneState: OigoPermissionState
    private var accessibilityState: OigoPermissionState
    private var accessibilityRequestAttempted = false
    private var testOutcome: OigoOnboardingTestOutcome = .pending
    private var testRunning = false
    private var completed = false
    private var committedShortcut: ToggleShortcut

    private let progressLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let languagePopup = NSPopUpButton()
    private let shortcutRecorder: ShortcutRecorderControl
    private let testField = NSTextField(string: "")
    private let actionButton = NSButton(title: "", target: nil, action: nil)
    private let skipButton = NSButton(title: "Skip test", target: nil, action: nil)
    private let backButton = NSButton(title: "Back", target: nil, action: nil)
    private let nextButton = NSButton(title: "Continue", target: nil, action: nil)
    private let historyButton = NSButton(title: "Open History", target: nil, action: nil)

    init(
        support: OigoSystemSupportResult,
        initialStep: OigoOnboardingStep = .system,
        globalShortcut: ToggleShortcut,
        microphoneState: OigoPermissionState,
        accessibilityState: OigoPermissionState,
        loadSupportedLanguages: @escaping () async -> [String],
        checkSpeechAssets: @escaping (String) async -> SpeechAssetState,
        saveLanguage: @escaping (String) -> Void,
        saveStep: @escaping (OigoOnboardingStep) -> Void,
        requestMicrophone: @escaping () async -> OigoPermissionState,
        openMicrophoneSettings: @escaping () -> Void,
        registrationStatus: @escaping () -> GlobalShortcutRegistrationStatus,
        registrationError: @escaping () -> String?,
        validateShortcut: @escaping (ToggleShortcut) -> OigoShortcutValidation,
        saveShortcut: @escaping (ToggleShortcut) -> OigoShortcutValidation,
        requestAccessibility: @escaping () -> OigoPermissionState,
        openAccessibilitySettings: @escaping () -> Void,
        startTest: @escaping () -> Void,
        stopTest: @escaping () -> Void,
        cancelTest: @escaping () -> Void,
        openHistory: @escaping () -> Void,
        onComplete: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.support = support
        self.currentStep = initialStep
        self.loadSupportedLanguages = loadSupportedLanguages
        self.checkSpeechAssets = checkSpeechAssets
        self.saveLanguage = saveLanguage
        self.saveStep = saveStep
        self.requestMicrophone = requestMicrophone
        self.openMicrophoneSettings = openMicrophoneSettings
        self.registrationStatus = registrationStatus
        self.registrationError = registrationError
        self.validateShortcut = validateShortcut
        self.saveShortcut = saveShortcut
        self.requestAccessibility = requestAccessibility
        self.openAccessibilitySettings = openAccessibilitySettings
        self.startTest = startTest
        self.stopTest = stopTest
        self.cancelTest = cancelTest
        self.openHistory = openHistory
        self.onComplete = onComplete
        self.onClose = onClose
        self.microphoneState = microphoneState
        self.accessibilityState = accessibilityState
        committedShortcut = globalShortcut
        shortcutRecorder = ShortcutRecorderControl(shortcut: globalShortcut)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Oigo"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        configureWindow()
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        _ = notification
        discardShortcutCandidate()
        if testRunning {
            testRunning = false
            cancelTest()
        }
        if support.isSupported, !completed {
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
    }

    func focusTestField() {
        guard currentStep == .testDictation,
              let window else {
            return
        }
        window.makeFirstResponder(testField)
    }

    func setTestResult(transcript: String, mode: OigoProcessingMode, copied: Bool) {
        testOutcome = transcript.isEmpty ? .pending : .passed
        testRunning = false
        testField.stringValue = transcript
        let clipboardStatus = copied ? "ready" : "not available"
        statusLabel.stringValue = testOutcome == .passed
            ? "Recording and transcription succeeded in " + mode.displayName + " mode. Clipboard output: " + clipboardStatus + "."
            : "The test did not produce a transcript. Try again or skip the test."
        actionButton.title = "Start test dictation"
        renderButtons()
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
        testField.placeholderString = "Your test transcript appears here"
        testField.isEditable = false
        testField.isSelectable = true
        shortcutRecorder.translatesAutoresizingMaskIntoConstraints = false
        historyButton.target = self
        historyButton.action = #selector(openHistoryAction)
        actionButton.target = self
        actionButton.action = #selector(performAction)
        skipButton.target = self
        skipButton.action = #selector(skipTestAction)
        backButton.target = self
        backButton.action = #selector(goBack)
        nextButton.target = self
        nextButton.action = #selector(goForward)

        let stack = NSStackView(views: [
            progressLabel,
            titleLabel,
            bodyLabel,
            languagePopup,
            shortcutRecorder,
            testField,
            statusLabel,
            historyButton,
            actionButton,
            skipButton,
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
            languagePopup.widthAnchor.constraint(equalToConstant: 280),
            shortcutRecorder.widthAnchor.constraint(equalToConstant: 280),
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
        testField.isHidden = !isSupported || currentStep != .testDictation
        historyButton.isHidden = currentStep != .recovery
        skipButton.isHidden = currentStep != .testDictation
        statusLabel.stringValue = status(for: currentStep)
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
            actionButton.title = testRunning ? "Stop test dictation" : "Start test dictation"
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
            nextButton.isEnabled = languageReady
        }
        if currentStep == .testDictation {
            nextButton.isEnabled = testOutcome.allowsContinue
        }
        if currentStep == .recovery {
            nextButton.isEnabled = registrationStatus().isActive
        }
    }

    private func body(for step: OigoOnboardingStep) -> String {
        switch step {
        case .system:
            "Oigo needs macOS 26 or later on Apple silicon. This check runs before setup so unsupported systems fail clearly."
        case .language:
            "Choose a language supported by Oigo's on-device speech module. Oigo picks the closest supported system locale and checks speech assets before your first valuable dictation."
        case .microphone:
            "Oigo records audio so every dictation can be retried from History. We ask for microphone access only after this explanation."
        case .shortcut:
            "Choose a readable global shortcut. The shipped default is \(ToggleShortcut.default.displayName), and Oigo keeps the previous working choice when registration fails."
        case .insertion:
            "Accessibility lets Oigo paste one completed transcript into the field you were using. If you decline, Copy and History still work."
        case .testDictation:
            "Use the Oigo-owned field below to verify recording, transcription, the selected mode, and clipboard output."
        case .recovery:
            "History is available from the Oigo menu bar item. It keeps saved recordings and lets you retry a failed transcription."
        case .complete:
            "Oigo is ready."
        }
    }

    private func status(for step: OigoOnboardingStep) -> String {
        switch step {
        case .microphone:
            return "Current microphone state: " + microphoneState.rawValue.capitalized
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
        case .testDictation where testOutcome == .passed:
            return "Test complete."
        case .testDictation where testOutcome == .skipped:
            return "Test skipped. You can run it later from Settings."
        default:
            return ""
        }
    }

    @objc private func skipTestAction() {
        guard currentStep == .testDictation else {
            return
        }
        if testRunning {
            testRunning = false
            cancelTest()
        }
        testOutcome = .skipped
        guard let next = nextStep(after: currentStep) else {
            return
        }
        currentStep = next
        saveStep(next)
        render()
    }

    private func loadLanguagesIfNeeded() {
        guard languagePopup.numberOfItems == 0 else {
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let languages = await loadSupportedLanguages()
            languagePopup.removeAllItems()
            languagePopup.addItems(withTitles: languages)
            if languages.isEmpty {
                statusLabel.stringValue = "No supported speech locales were found."
                return
            }
            languagePopup.selectItem(at: 0)
            saveLanguage(languagePopup.selectedItem?.title ?? languages[0])
        }
    }

    @objc private func performAction() {
        switch currentStep {
        case .language:
            statusLabel.stringValue = "Speech assets: installing…"
            actionButton.isEnabled = false
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let selectedLanguage = languagePopup.selectedItem?.title else {
                    statusLabel.stringValue = "Choose a supported speech language first."
                    actionButton.isEnabled = true
                    return
                }
                let state = await checkSpeechAssets(selectedLanguage)
                statusLabel.stringValue = "Speech assets: " + state.description
                languageReady = if case .ready = state { true } else { false }
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
                    statusLabel.stringValue = microphoneState == .granted
                        ? "Microphone access is ready."
                        : "Microphone access was denied. Open System Settings to recover."
                    renderButtons()
                    if microphoneState == .denied { actionButton.title = "Open Microphone Settings" }
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
            testRunning.toggle()
            if testRunning { startTest() } else { stopTest() }
            actionButton.title = testRunning ? "Stop test dictation" : "Start test dictation"
            renderButtons()
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
        if currentStep == .language,
           let selectedLanguage = languagePopup.selectedItem?.title {
            saveLanguage(selectedLanguage)
        }
        guard let next = nextStep(after: currentStep) else {
            completed = true
            onComplete()
            window?.close()
            return
        }
        currentStep = next
        saveStep(next)
        render()
    }

    @objc private func goBack() {
        discardShortcutCandidate()
        guard let previous = previousStep(before: currentStep) else { return }
        currentStep = previous
        saveStep(previous)
        render()
    }

    @objc private func openHistoryAction() {
        openHistory()
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

    private static func validationMessage(_ validation: OigoShortcutValidation) -> String {
        switch validation {
        case .available:
            "Registration is active"
        case .conflict(let reason), .invalid(let reason):
            reason
        }
    }
}
