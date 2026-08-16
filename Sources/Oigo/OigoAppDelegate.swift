import AppKit
import AVFAudio
import ApplicationServices
import Foundation
import OigoCore
import OigoCapture
import OigoTranscription
import OigoInsertion

@available(macOS 26.0, *)
@MainActor
final class OigoAppDelegate: NSObject, NSApplicationDelegate {
    private let coordinator = DictationCoordinator()
    private let recorder = AudioRecorder()
    private var transcription: TranscriptionService?
    private let insertion = InsertionService()
    private let playback = AudioPlayback()
    private let shortcutRegistrar = CarbonGlobalShortcutRegistrar()
    private let statusSurface = StatusSurfaceController()
    private let settingsStore = OigoSettingsStore()
    private let onboardingStore = OigoOnboardingStore()
    private let launchAtLoginController = OigoLaunchAtLoginController(client: SystemLaunchAtLoginClient())
    private let transcriptCleanupMetrics = TranscriptCleanupMetrics()
    private lazy var transcriptCleanup: TranscriptCleanupCoordinator = {
        let metrics = transcriptCleanupMetrics
        return TranscriptCleanupCoordinator(
            cleanerFactory: {
                FoundationModelsTranscriptCleaner(instrumentation: metrics)
            },
            instrumentation: metrics
        )
    }()
    private var sessionStore: SessionStore?
    private var lastSession: DictationSession?
    private var livePreview = ""
    private var settingsWindow: SettingsWindowController?
    private var historyWindow: HistoryWindowController?
    private var statusItem: NSStatusItem?
    private var toggleItem: NSMenuItem?
    private var modeMenuItem: NSMenuItem?
    private var instantModeItem: NSMenuItem?
    private var cleanModeItem: NSMenuItem?
    private var launchAtLoginItem: NSMenuItem?
    private var settings = OigoSettingsStore().load()
    private var targetSnapshot: InsertionTargetSnapshot?
    private var insertionDisplayStatus: OigoHUDProcessingState?
    private var onboardingWindow: OnboardingWindowController?
    private var recordingStartedAt: Date?
    private var previewThrottle = OigoHUDPreviewThrottle()
    private var toggleTask: Task<Void, Never>?
    private var cleanAgainTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
        NSApp.setActivationPolicy(.accessory)
        let support = OigoSystemSupportEvaluator.current()
        guard support.isSupported else {
            showOnboarding(support)
            return
        }
        prepareSessionStore()
        configureStatusItem()
        if onboardingStore.load().isComplete {
            registerShortcut()
        } else {
            showOnboarding(support)
        }
        updateSurface()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        _ = sender
        shortcutRegistrar.unregister()
        statusSurface.hide()
        playback.stop()
        let activeToggleTask = toggleTask
        let activeCleanAgainTask = cleanAgainTask
        let activeRetryTask = retryTask
        activeToggleTask?.cancel()
        activeCleanAgainTask?.cancel()
        if coordinator.hasActiveWork
            || activeToggleTask != nil
            || activeCleanAgainTask != nil
            || activeRetryTask != nil {
            Task { @MainActor [weak self] in
                if let activeToggleTask {
                    await activeToggleTask.value
                }
                if let activeCleanAgainTask {
                    await activeCleanAgainTask.value
                }
                if self?.coordinator.hasActiveTranscription == true {
                    await self?.coordinator.shutdownWithTranscription()
                } else {
                    await self?.coordinator.shutdownAndWait()
                }
                if let activeRetryTask {
                    await activeRetryTask.value
                }
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        coordinator.shutdown()
        return .terminateNow
    }

    @objc private func toggleDictation() {
        handleToggle()
    }

    @objc private func openSettings() {
        if let settingsWindow, settingsWindow.window?.isVisible == true {
            settingsWindow.showWindow(nil)
            settingsWindow.window?.makeKeyAndOrderFront(nil)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let supportedLocales = await self.transcriptionService().supportedLocaleIdentifiers()
            self.presentSettings(supportedLocales: supportedLocales)
        }
    }

    private func presentSettings(supportedLocales: [String]) {
        let window = SettingsWindowController(
            settings: settings,
            supportedLocales: supportedLocales,
            microphoneState: microphonePermissionState(),
            accessibilityState: accessibilityPermissionState(),
            save: { [weak self] settings in
                self?.applySettings(settings) ?? "Oigo is no longer available."
            },
            refreshPermissions: { [weak self] in
                guard let self else {
                    return (.unknown, .unknown)
                }
                return (self.microphonePermissionState(), self.accessibilityPermissionState())
            },
            openMicrophoneSettings: { [weak self] in
                self?.openSystemSettings(OigoPermissionPresentation.microphone(.denied).settingsURL)
            },
            openAccessibilitySettings: { [weak self] in
                self?.openSystemSettings(OigoPermissionPresentation.accessibility(.denied).settingsURL)
            },
            rerunOnboarding: { [weak self] in
                self?.rerunOnboarding()
            },
            openHistory: { [weak self] in
                self?.openHistory()
            },
            openDataFolder: { [weak self] in
                self?.openDataFolder()
            },
            deleteAllHistory: { [weak self] in
                self?.deleteAllHistory()
            }
        )
        settingsWindow = window
        window.showWindow(nil)
        window.window?.center()
        window.window?.makeKeyAndOrderFront(nil)
    }

    private func showOnboarding(_ support: OigoSystemSupportResult) {
        let storedState = onboardingStore.load()
        let initialStep = storedState.isComplete ? .system : storedState.step
        let window = OnboardingWindowController(
            support: support,
            initialStep: initialStep,
            globalShortcut: settings.globalShortcut,
            microphoneState: microphonePermissionState(),
            accessibilityState: accessibilityPermissionState(),
            loadSupportedLanguages: { [weak self] in
                guard let self else { return [] }
                let service = self.transcriptionService()
                let identifiers = await service.supportedLocaleIdentifiers()
                guard let closest = OigoSupportedLocaleResolver.closest(
                    to: self.settings.localeIdentifier,
                    among: identifiers
                ) else {
                    return identifiers
                }
                return [closest] + identifiers.filter { $0 != closest }
            },
            checkSpeechAssets: { [weak self] identifier in
                guard let self else {
                    return .unavailable("Oigo is no longer available")
                }
                let service = self.transcriptionService(for: identifier)
                do {
                    return try await service.installSpeechAssets()
                } catch {
                    return service.currentAssetState
                }
            },
            saveLanguage: { [weak self] identifier in
                guard let self else { return }
                self.settings = self.settings.with(localeIdentifier: identifier)
                self.settingsStore.save(self.settings)
                self.transcription = nil
            },
            saveStep: { [weak self] step in
                self?.onboardingStore.save(OigoOnboardingState(step: step))
            },
            requestMicrophone: {
                _ = await AudioRecorder.requestMicrophonePermission()
                return Self.currentMicrophonePermissionState()
            },
            openMicrophoneSettings: { [weak self] in
                self?.openSystemSettings(OigoPermissionPresentation.microphone(.denied).settingsURL)
            },
            validateShortcut: { [weak self] candidate in
                self?.validateShortcut(candidate) ?? .invalid("Oigo is no longer available")
            },
            saveShortcut: { [weak self] candidate in
                self?.saveShortcut(candidate) ?? .invalid("Oigo is no longer available")
            },
            requestAccessibility: {
                Self.requestAccessibilityPermission()
            },
            openAccessibilitySettings: { [weak self] in
                self?.openSystemSettings(OigoPermissionPresentation.accessibility(.denied).settingsURL)
            },
            startTest: { [weak self] in
                self?.onboardingWindow?.focusTestField()
                self?.handleToggle(allowBeforeSetup: true)
            },
            stopTest: { [weak self] in
                self?.stopTestDictation()
            },
            openHistory: { [weak self] in
                self?.openHistory()
            },
            onComplete: { [weak self] in
                guard let self else { return }
                self.onboardingStore.markCompleted()
                self.onboardingWindow = nil
                self.registerShortcut()
                self.updateSurface()
            },
            onClose: { [weak self] in
                self?.onboardingWindow = nil
            }
        )
        onboardingWindow = window
        window.showAndFocus()
    }

    @objc private func openHistory() {
        if historyWindow == nil {
            historyWindow = HistoryWindowController(
                loadTranscript: { [weak self] entry, source in
                    self?.loadTranscript(for: entry, source: source)
                        ?? .failure(SessionStoreError.missingSession(entry.id))
                },
                copyRawTranscript: { [weak self] entry in
                    self?.copyRawTranscript(for: entry)
                },
                copyCleanTranscript: { [weak self] entry in
                    self?.copyCleanTranscript(for: entry)
                },
                pasteAgain: { [weak self] entry in
                    self?.pasteAgain(for: entry)
                },
                pasteCleanAgain: { [weak self] entry in
                    self?.pasteCleanAgain(for: entry)
                },
                cleanAgain: { [weak self] entry in
                    self?.cleanAgain(for: entry)
                },
                playRecording: { [weak self] entry in
                    self?.playRecording(for: entry)
                },
                retryTranscription: { [weak self] entry in
                    self?.retryTranscription(for: entry)
                },
                revealRecording: { [weak self] entry in
                    self?.revealRecording(for: entry)
                },
                deleteSession: { [weak self] entry in
                    self?.confirmDelete(entry)
                },
                runIdleMaintenance: { [weak self] in
                    self?.runIdleMaintenance()
                }
            )
        }
        refreshHistory()
        historyWindow?.showAndFocus()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Oigo"

        let menu = NSMenu()
        menu.autoenablesItems = false
        let toggle = NSMenuItem(
            title: "Start Dictation",
            action: #selector(toggleDictation),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)

        let mode = NSMenuItem(
            title: "Mode",
            action: nil,
            keyEquivalent: ""
        )
        let modeMenu = NSMenu()
        let instant = NSMenuItem(
            title: OigoProcessingMode.instant.displayName,
            action: #selector(selectInstantMode),
            keyEquivalent: ""
        )
        instant.target = self
        let clean = NSMenuItem(
            title: OigoProcessingMode.clean.displayName,
            action: #selector(selectCleanMode),
            keyEquivalent: ""
        )
        clean.target = self
        modeMenu.addItem(instant)
        modeMenu.addItem(clean)
        mode.submenu = modeMenu
        menu.addItem(mode)

        let history = NSMenuItem(
            title: "Recent Dictations…",
            action: #selector(openHistory),
            keyEquivalent: ""
        )
        history.target = self
        menu.addItem(history)

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        let launchAtLogin = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchAtLogin.target = self
        menu.addItem(launchAtLogin)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit Oigo",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
        toggleItem = toggle
        modeMenuItem = mode
        instantModeItem = instant
        cleanModeItem = clean
        launchAtLoginItem = launchAtLogin
    }

    private func registerShortcut() {
        shortcutRegistrar.unregister()
        do {
            try shortcutRegistrar.register(shortcut: settings.globalShortcut) { [weak self] in
                self?.handleToggle()
            }
        } catch {
            NSLog("Oigo could not register the global toggle shortcut: %@", String(describing: error))
        }
    }

    private func handleToggle(allowBeforeSetup: Bool = false) {
        guard allowBeforeSetup || onboardingStore.load().isComplete else {
            showOnboarding(OigoSystemSupportEvaluator.current())
            return
        }
        if let toggleTask {
            toggleTask.cancel()
            return
        }
        do {
            toggleTask = try coordinator.startTask { @MainActor [weak self] in
                defer { self?.toggleTask = nil }
                await self?.performToggle()
            }
        } catch {
            NSLog("Oigo could not start its coordinator-owned toggle task: %@", String(describing: error))
        }
    }

    private func stopTestDictation() {
        let activeToggleTask = toggleTask
        activeToggleTask?.cancel()
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let activeToggleTask {
                await activeToggleTask.value
            }
            guard self.coordinator.hasActiveTranscription else {
                self.recordingStartedAt = nil
                self.targetSnapshot = nil
                self.statusSurface.hide()
                self.updateSurface()
                return
            }
            _ = try? await self.coordinator.cancelRecordingWithTranscription()
            self.recordingStartedAt = nil
            self.targetSnapshot = nil
            self.insertionDisplayStatus = nil
            self.statusSurface.hide()
            self.updateSurface()
        }
    }

    private func performToggle() async {
        do {
            switch coordinator.state {
            case .idle, .complete, .failed, .cancelled, .interrupted:
                guard let sessionStore else {
                    throw SessionStoreError.invalidSessionDirectory(
                        SessionStore.defaultRootDirectory()
                    )
                }
                insertionDisplayStatus = nil
                try await ensureMicrophonePermission()
                targetSnapshot = insertion.captureTarget()
                let format = try recorder.captureFormat()
                let service = transcriptionService()
                recordingStartedAt = Date()
                previewThrottle = OigoHUDPreviewThrottle()
                lastSession = try await coordinator.startRecordingWithTranscription(
                    using: recorder,
                    store: sessionStore,
                    transcription: service,
                    format: format,
                    onUpdate: { [weak self] update in
                        Task { @MainActor [weak self] in
                            self?.applyTranscriptionUpdate(update)
                        }
                    }
                )
            case .recording:
                let terminalMode = transcriptCleanupMode(for: settings.defaultMode)
                insertionDisplayStatus = .finalizing
                updateSurface()
                _ = try await coordinator.stopRecordingWithTranscription()
                recordingStartedAt = nil
                guard let snapshot = targetSnapshot,
                      let store = sessionStore else {
                    throw DictationCoordinatorError.recordingNotActive
                }
                let insertionSession = try coordinator.beginInsertion(
                    using: store,
                    requiresCleanup: settings.defaultMode == .clean
                )
                if terminalMode == .clean {
                    insertionDisplayStatus = .cleaning
                }
                updateSurface()
                let decision = try await resolveCleanup(
                    for: insertionSession,
                    store: store,
                    mode: terminalMode
                )
                try Task.checkCancellation()
                if terminalMode == .clean {
                    _ = try coordinator.finishCleanup()
                }
                try Task.checkCancellation()
                insertionDisplayStatus = .pasting
                updateSurface()
                explainAccessibilityBeforePaste()
                let result = insertion.insertText(
                    for: insertionSession,
                    source: decision.insertionSource,
                    store: store,
                    target: snapshot
                )
                lastSession = try coordinator.finishInsertion(
                    outcome: result.outcome,
                    reason: result.reason,
                    insertionSource: decision.insertionSource,
                    cleanupFallbackReason: decision.fallbackReason?.description
                )
                let rawText = (try? store.readRawText(for: insertionSession)) ?? ""
                onboardingWindow?.setTestResult(
                    transcript: rawText,
                    mode: settings.defaultMode,
                    copied: result.outcome.clipboardOutputAvailable
                )
                if let fallbackReason = decision.fallbackReason {
                    historyWindow?.showMessage(
                        "Clean unavailable. Inserted the raw transcript: " + fallbackReason.description
                    )
                }
                insertionDisplayStatus = Self.displayStatus(for: result.outcome)
                targetSnapshot = nil
                livePreview = ""
            case .preparing, .finalizing, .cleaning, .inserting:
                throw DictationTransitionError.illegal(
                    from: coordinator.state,
                    event: .start
                )
            }
            if historyWindow != nil {
                refreshHistory()
            }
            updateSurface()
        } catch is CancellationError {
            await coordinator.cancelActiveWork()
            lastSession = coordinator.currentSession ?? lastSession
            recordingStartedAt = nil
            targetSnapshot = nil
            livePreview = ""
            if !coordinator.hasActiveWork {
                insertionDisplayStatus = nil
            }
            updateSurface()
            return
        } catch {
            if coordinator.hasActiveWork {
                await coordinator.cancelActiveWork(reason: String(describing: error))
            }
            lastSession = coordinator.currentSession ?? lastSession
            targetSnapshot = nil
            recordingStartedAt = nil
            insertionDisplayStatus = .failed
            if let session = coordinator.currentSession,
               [.failed, .interrupted].contains(session.metadata.state) {
                lastSession = session
            }
            historyWindow?.showMessage(Self.friendlyError("Dictation failed", error))
            onboardingWindow?.setTestResult(
                transcript: "",
                mode: settings.defaultMode,
                copied: false
            )
            NSLog("Oigo rejected the toggle command: %@", String(describing: error))
            updateSurface()
        }
    }

    @objc private func retryLastTranscription() {
        guard let session = lastSession else {
            return
        }
        startRetry(for: session)
    }

    private func retryTranscription(for entry: SessionHistoryEntry) {
        startRetry(for: entry.session)
    }

    private func startRetry(for session: DictationSession) {
        guard retryTask == nil else {
            return
        }
        do {
            retryTask = try coordinator.startTask { @MainActor [weak self] in
                defer { self?.retryTask = nil }
                await self?.performRetry(for: session)
            }
        } catch {
            historyWindow?.showMessage(Self.friendlyError("Retry failed", error))
        }
    }

    private func performRetry(for session: DictationSession) async {
        guard let store = sessionStore,
              [.failed, .interrupted].contains(session.metadata.state),
              FileManager.default.fileExists(atPath: session.audioURL.path) else {
            updateSurface()
            return
        }

        do {
            livePreview = ""
            historyWindow?.showMessage("Retrying transcription from the saved recording…")
            lastSession = try await coordinator.retryRecordingWithTranscription(
                for: session,
                using: transcriptionService(),
                store: store
            )
            historyWindow?.showMessage("Transcription retry completed.")
        } catch {
            lastSession = try? store.load(id: session.id)
            historyWindow?.showMessage(Self.friendlyError("Retry failed", error))
            NSLog("Oigo could not retry the saved transcription: %@", Self.friendlyError("Retry failed", error))
        }
        refreshHistory()
        updateSurface()
    }

    private func loadTranscript(
        for entry: SessionHistoryEntry,
        source: SessionTextSource
    ) -> Result<String, Error> {
        guard let store = sessionStore else {
            return .failure(SessionStoreError.missingSession(entry.id))
        }
        do {
            let transcript = switch source {
            case .raw:
                try store.readRawText(for: entry.session)
            case .processed:
                try store.readCleanText(for: entry.session)
            }
            return .success(transcript)
        } catch {
            return .failure(error)
        }
    }

    private func resolveCleanup(
        for session: DictationSession,
        store: SessionStore,
        mode: TranscriptCleanupMode
    ) async throws -> TranscriptCleanupDecision {
        let rawText = try store.readRawText(for: session)
        guard mode == .clean else {
            return TranscriptCleanupDecision(
                rawText: rawText,
                insertionText: rawText,
                cleanText: nil,
                insertionSource: .raw
            )
        }

        var decision = await transcriptCleanup.resolve(
            mode: .clean,
            rawText: rawText,
            deadlineNanoseconds: 4_000_000_000
        )
        try Task.checkCancellation()
        if let cleanText = decision.cleanText {
            try Task.checkCancellation()
            do {
                _ = try store.persistCleanText(
                    cleanText,
                    for: session
                )
            } catch {
                transcriptCleanupMetrics.record(.fallback)
                decision = TranscriptCleanupDecision(
                    rawText: rawText,
                    insertionText: rawText,
                    cleanText: nil,
                    insertionSource: .raw,
                    fallbackReason: .persistenceFailure(String(describing: error)),
                    chunkCount: decision.chunkCount
                )
            }
        }
        return decision
    }

    private func copyRawTranscript(for entry: SessionHistoryEntry) {
        guard let store = sessionStore else {
            return
        }
        do {
            let rawText = try store.readRawText(for: entry.session)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setString(rawText, forType: .string) else {
                historyWindow?.showMessage("Copy failed: the raw transcript could not be placed on the clipboard.")
                return
            }
            historyWindow?.showMessage("Raw transcript copied to the clipboard.")
        } catch {
            historyWindow?.showMessage(Self.friendlyError("Copy failed", error))
        }
    }

    private func copyCleanTranscript(for entry: SessionHistoryEntry) {
        guard let store = sessionStore else {
            return
        }
        do {
            let cleanText = try store.readCleanText(for: entry.session)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setString(cleanText, forType: .string) else {
                historyWindow?.showMessage("Copy failed: the clean transcript could not be placed on the clipboard.")
                return
            }
            historyWindow?.showMessage("Clean transcript copied to the clipboard.")
        } catch {
            historyWindow?.showMessage(Self.friendlyError("Copy failed", error))
        }
    }

    private func cleanAgain(for entry: SessionHistoryEntry) {
        guard cleanAgainTask == nil,
              let store = sessionStore else {
            return
        }
        historyWindow?.setCleanAgainEnabled(false)
        historyWindow?.showMessage("Cleaning the saved raw transcript…")
        do {
            cleanAgainTask = try coordinator.startTask { @MainActor [weak self] in
                defer {
                    self?.cleanAgainTask = nil
                    self?.historyWindow?.setCleanAgainEnabled(true)
                }
                await self?.performCleanAgain(for: entry, store: store)
            }
        } catch {
            historyWindow?.setCleanAgainEnabled(true)
            historyWindow?.showMessage(Self.friendlyError("Clean Again failed", error))
        }
    }

    private func performCleanAgain(
        for entry: SessionHistoryEntry,
        store: SessionStore
    ) async {
        do {
            let rawText = try store.readRawText(for: entry.session)
            let decision = await transcriptCleanup.resolve(
                mode: .clean,
                rawText: rawText,
                deadlineNanoseconds: 4_000_000_000
            )
            try Task.checkCancellation()
            guard let cleanText = decision.cleanText else {
                let fallbackReason = decision.fallbackReason?.description
                    ?? "cleanup did not complete"
                try Task.checkCancellation()
                _ = try store.update(
                    entry.session,
                    state: entry.session.metadata.state,
                    cleanupFallbackReason: fallbackReason
                )
                historyWindow?.showMessage(
                    "Clean Again used no output. Raw transcript remains available: "
                        + fallbackReason
                )
                refreshHistory()
                return
            }
            try Task.checkCancellation()
            do {
                _ = try store.persistCleanText(
                    cleanText,
                    for: entry.session
                )
            } catch let error as SessionStoreError {
                if case .rawTextChanged = error {
                    throw error
                }
                let fallbackReason = TranscriptCleanupFallbackReason
                    .persistenceFailure(String(describing: error))
                    .description
                try Task.checkCancellation()
                _ = try store.update(
                    entry.session,
                    state: entry.session.metadata.state,
                    insertionTextSource: .raw,
                    cleanupFallbackReason: fallbackReason
                )
                historyWindow?.showMessage(
                    "Clean Again could not save clean.txt. Raw transcript remains available: "
                        + fallbackReason
                )
                refreshHistory()
                return
            }
            try Task.checkCancellation()
            historyWindow?.showMessage("Clean transcript saved. Raw transcript was unchanged.")
            refreshHistory()
        } catch SessionStoreError.rawTextChanged {
            guard !Task.isCancelled else {
                return
            }
            let fallbackReason = "raw transcript changed while Clean Again was running"
            do {
                _ = try store.update(
                    entry.session,
                    state: entry.session.metadata.state,
                    insertionTextSource: .raw,
                    cleanupFallbackReason: fallbackReason
                )
                historyWindow?.showMessage(
                    "Clean Again discarded stale output. Raw transcript remains available."
                )
                refreshHistory()
            } catch {
                historyWindow?.showMessage(Self.friendlyError("Clean Again failed", error))
            }
        } catch is CancellationError {
            return
        } catch {
            historyWindow?.showMessage(Self.friendlyError("Clean Again failed", error))
        }
    }

    private func pasteCleanAgain(for entry: SessionHistoryEntry) {
        guard let store = sessionStore else {
            return
        }
        historyWindow?.window?.orderOut(nil)
        NSApp.hide(nil)
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            defer {
                self.historyWindow?.showAndFocus()
                self.historyWindow?.showCleanTranscript()
                self.updateSurface()
            }
            let target = self.insertion.captureTarget()
            let result = self.insertion.pasteAgain(
                for: entry.session,
                source: .clean,
                store: store,
                target: target
            )
            do {
                let updated = try store.update(
                    entry.session,
                    state: entry.session.metadata.state,
                    at: Date(),
                    insertionOutcome: result.outcome,
                    insertionFailureReason: result.reason,
                    insertionTextSource: .clean
                )
                self.lastSession = updated
                self.insertionDisplayStatus = Self.displayStatus(for: result.outcome)
                switch result.outcome {
                case .pasted:
                    self.historyWindow?.showMessage("Clean transcript pasted again.")
                case .copied, .secureRejected:
                    self.historyWindow?.showMessage("Clean transcript copied. " + (result.reason ?? "Paste was not sent."))
                case .failed:
                    self.historyWindow?.showMessage("Paste Clean Again failed: " + (result.reason ?? "the paste could not be completed"))
                }
                self.refreshHistory()
            } catch {
                self.historyWindow?.showMessage(Self.friendlyError("Paste Clean Again failed", error))
            }
        }
    }

    private func pasteAgain(for entry: SessionHistoryEntry) {
        guard let store = sessionStore else {
            return
        }
        historyWindow?.window?.orderOut(nil)
        NSApp.hide(nil)
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            defer {
                self.historyWindow?.showAndFocus()
                self.updateSurface()
            }
            let target = self.insertion.captureTarget()
            let result = self.insertion.pasteAgain(
                for: entry.session,
                store: store,
                target: target
            )
            do {
                let updated = try store.update(
                    entry.session,
                    state: entry.session.metadata.state,
                    at: Date(),
                    insertionOutcome: result.outcome,
                    insertionFailureReason: result.reason,
                    insertionTextSource: .raw
                )
                self.lastSession = updated
                self.insertionDisplayStatus = Self.displayStatus(for: result.outcome)
                switch result.outcome {
                case .pasted:
                    self.historyWindow?.showMessage("Pasted again.")
                case .copied, .secureRejected:
                    self.historyWindow?.showMessage("Raw transcript copied. " + (result.reason ?? "Paste was not sent."))
                case .failed:
                    self.historyWindow?.showMessage("Paste Again failed: " + (result.reason ?? "the paste could not be completed"))
                }
                self.refreshHistory()
            } catch {
                self.historyWindow?.showMessage(Self.friendlyError("Paste Again failed", error))
            }
        }
    }

    private func playRecording(for entry: SessionHistoryEntry) {
        do {
            _ = try playback.play(url: entry.session.audioURL)
            historyWindow?.showMessage("Playing the saved recording.")
        } catch {
            historyWindow?.showMessage(Self.friendlyError("Playback failed", error))
        }
    }

    private func revealRecording(for entry: SessionHistoryEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([entry.session.directoryURL])
        historyWindow?.showMessage("Revealed the session folder in Finder.")
    }

    private func confirmDelete(_ entry: SessionHistoryEntry) {
        guard !entry.session.metadata.state.isUnfinished else {
            historyWindow?.showMessage("Active sessions cannot be deleted.")
            return
        }
        guard let window = historyWindow?.window else {
            delete(entry)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Delete this session?"
        alert.informativeText = "The recording and transcript files will be removed from Oigo."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else {
                return
            }
            Task { @MainActor [weak self] in
                self?.delete(entry)
            }
        }
    }

    private func delete(_ entry: SessionHistoryEntry) {
        guard let store = sessionStore else {
            return
        }
        do {
            try store.remove(id: entry.id)
            if lastSession?.id == entry.id {
                lastSession = nil
            }
            historyWindow?.showMessage("Session deleted.")
            refreshHistory()
        } catch {
            historyWindow?.showMessage(Self.friendlyError("Delete failed", error))
        }
        updateSurface()
    }

    private func refreshHistory() {
        guard let store = sessionStore else {
            return
        }
        do {
            let entries = try store.listHistory()
            lastSession = entries.first?.session
            historyWindow?.reload(entries: entries)
        } catch {
            historyWindow?.showMessage(Self.friendlyError("History unavailable", error))
        }
        updateSurface()
    }

    private func runIdleMaintenance() {
        let canRunMaintenance = [
            .idle,
            .complete,
            .failed,
            .cancelled,
            .interrupted
        ].contains(coordinator.state) && !coordinator.hasActiveTranscription
        guard canRunMaintenance else {
            historyWindow?.showMessage("Idle maintenance is unavailable while dictation is active.")
            updateSurface()
            return
        }
        guard let store = sessionStore else {
            return
        }
        do {
            let lifetime = settings.keepSuccessfulAudioIndefinitely
                ? Double.greatestFiniteMagnitude
                : settings.audioRetention.duration
            let policy = SessionRetentionPolicy(
                successfulAudioLifetime: lifetime
            )
            let result = try store.performIdleMaintenance(policy: policy)
            refreshHistory()
            let removed = result.removedSessionIDs.count + result.removedAudioSessionIDs.count
            historyWindow?.showMessage(
                removed == 0
                    ? "Idle maintenance found nothing to remove."
                    : "Idle maintenance removed \(removed) expired artifact set\(removed == 1 ? "" : "s")."
            )
        } catch {
            historyWindow?.showMessage(Self.friendlyError("Maintenance failed", error))
        }
    }

    private func applyTranscriptionUpdate(_ update: TranscriptionUpdate) {
        guard previewThrottle.shouldPublish(at: Date().timeIntervalSinceReferenceDate) else {
            return
        }
        let text = update.isFinal
            ? (update.finalizedSegment ?? update.volatilePreview)
            : update.volatilePreview
        livePreview = OigoHUDPreviewPolicy.bounded(
            text.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        updateSurface()
    }

    private func updateSurface() {
        let isRecording = coordinator.state == .recording
        let setupComplete = onboardingStore.load().isComplete
        let canToggle = [
            .idle,
            .recording,
            .complete,
            .failed,
            .cancelled,
            .interrupted
        ].contains(coordinator.state)
        toggleItem?.title = isRecording ? "Stop Dictation" : "Start Dictation"
        toggleItem?.isEnabled = setupComplete && canToggle
        instantModeItem?.state = settings.defaultMode == .instant ? .on : .off
        cleanModeItem?.state = settings.defaultMode == .clean ? .on : .off
        modeMenuItem?.isEnabled = setupComplete && !isRecording
        launchAtLoginItem?.state = launchAtLoginController.isEnabled ? .on : .off
        statusItem?.button?.title = "Oigo"

        if isRecording {
            statusSurface.showRecording(
                startedAt: recordingStartedAt ?? Date(),
                preview: settings.showVolatilePreview ? livePreview : "",
                anchoredTo: statusItem?.button
            )
        } else if let insertionDisplayStatus {
            statusSurface.showProcessing(
                insertionDisplayStatus,
                detail: Self.hudDetail(for: insertionDisplayStatus),
                anchoredTo: statusItem?.button
            )
        } else {
            statusSurface.hide()
        }
    }

    @objc private func selectInstantMode() {
        settings = settings.with(defaultMode: .instant)
        settingsStore.save(settings)
        updateSurface()
    }

    @objc private func selectCleanMode() {
        settings = settings.with(defaultMode: .clean)
        settingsStore.save(settings)
        updateSurface()
    }

    @objc private func toggleLaunchAtLogin() {
        let enabled = !launchAtLoginController.isEnabled
        do {
            try launchAtLoginController.setEnabled(enabled)
            settings = settings.with(launchAtLogin: enabled)
            settingsStore.save(settings)
            updateSurface()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Launch at Login could not be changed"
            alert.informativeText = String(describing: error)
            alert.runModal()
        }
    }

    @objc private func playLastRecording() {
        guard let session = lastSession else {
            return
        }
        do {
            _ = try playback.play(url: session.audioURL)
        } catch {
            NSLog("Oigo could not play the last recording: %@", String(describing: error))
        }
    }

    @objc private func revealLastRecording() {
        guard let session = lastSession else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([session.directoryURL])
    }

    private func prepareSessionStore() {
        do {
            let store = try SessionStore()
            sessionStore = store
            _ = try store.recoverUnfinishedSessions()
            lastSession = try store.listHistory(limit: 1).first?.session
        } catch {
            NSLog("Oigo could not prepare durable sessions: %@", String(describing: error))
        }
    }

    private func transcriptionService(for requestedIdentifier: String? = nil) -> TranscriptionService {
        let identifier = requestedIdentifier ?? (settings.localeIdentifier.isEmpty
            ? Locale.current.identifier
            : settings.localeIdentifier)
        if let transcription,
           transcription.configuredLocaleIdentifier == identifier {
            return transcription
        }
        let service = TranscriptionService(locale: Locale(identifier: identifier))
        transcription = service
        return service
    }

    private func transcriptCleanupMode(for mode: OigoProcessingMode) -> TranscriptCleanupMode {
        TranscriptCleanupMode(rawValue: mode.rawValue) ?? .instant
    }

    private func applySettings(_ newSettings: OigoSettings) -> String? {
        let shortcutValidation = validateShortcut(newSettings.globalShortcut)
        if !shortcutValidation.isAvailable {
            switch shortcutValidation {
            case .conflict(let reason), .invalid(let reason):
                return reason
            case .available:
                return nil
            }
        }

        let previousSettings = settings
        if previousSettings.launchAtLogin != newSettings.launchAtLogin {
            do {
                try launchAtLoginController.setEnabled(newSettings.launchAtLogin)
            } catch {
                registerShortcut()
                return "Launch at Login could not be changed: " + String(describing: error)
            }
        }
        settings = newSettings
        settingsStore.save(settings)
        if previousSettings.localeIdentifier != settings.localeIdentifier {
            transcription = nil
        }
        registerShortcut()
        updateSurface()
        return nil
    }

    private func validateShortcut(_ candidate: ToggleShortcut) -> OigoShortcutValidation {
        let basicValidation = OigoShortcutValidator.validate(candidate, occupied: [])
        guard basicValidation.isAvailable else {
            return basicValidation
        }
        shortcutRegistrar.unregister()
        do {
            try shortcutRegistrar.register(shortcut: candidate) { }
            shortcutRegistrar.unregister()
            return .available
        } catch {
            shortcutRegistrar.unregister()
            registerShortcut()
            return .conflict(String(describing: error))
        }
    }

    private func saveShortcut(_ candidate: ToggleShortcut) -> OigoShortcutValidation {
        let validation = validateShortcut(candidate)
        guard validation.isAvailable else {
            return validation
        }
        settings = settings.with(globalShortcut: candidate)
        settingsStore.save(settings)
        registerShortcut()
        updateSurface()
        return .available
    }

    private func rerunOnboarding() {
        onboardingStore.rerun()
        showOnboarding(OigoSystemSupportEvaluator.current())
    }

    private func openDataFolder() {
        NSWorkspace.shared.open(SessionStore.defaultRootDirectory())
    }

    private func deleteAllHistory() {
        guard let store = sessionStore else {
            return
        }
        do {
            _ = try store.deleteAllHistory(confirmed: true)
            lastSession = nil
            refreshHistory()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Delete All History failed"
            alert.informativeText = String(describing: error)
            alert.runModal()
        }
    }

    private func ensureMicrophonePermission() async throws {
        switch microphonePermissionState() {
        case .granted:
            return
        case .unknown:
            let presentation = OigoPermissionPresentation.microphone(.unknown)
            let alert = NSAlert()
            alert.messageText = presentation.title
            alert.informativeText = presentation.explanation
            alert.addButton(withTitle: "Allow Microphone")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else {
                throw AudioRecorderError.microphonePermission("permission request was cancelled")
            }
            guard await AudioRecorder.requestMicrophonePermission() else {
                throw AudioRecorderError.microphonePermission("denied")
            }
        case .denied:
            let presentation = OigoPermissionPresentation.microphone(.denied)
            let alert = NSAlert()
            alert.messageText = presentation.title
            alert.informativeText = presentation.explanation
            alert.addButton(withTitle: "Open Microphone Settings")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                openSystemSettings(presentation.settingsURL)
            }
            throw AudioRecorderError.microphonePermission("denied")
        }
    }

    private func explainAccessibilityBeforePaste() {
        guard accessibilityPermissionState() != .granted else {
            return
        }
        let presentation = OigoPermissionPresentation.accessibility(.denied)
        let alert = NSAlert()
        alert.messageText = presentation.title
        alert.informativeText = presentation.explanation
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Copy Only")
        if alert.runModal() == .alertFirstButtonReturn {
            openSystemSettings(presentation.settingsURL)
        }
    }

    private func openSystemSettings(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private func microphonePermissionState() -> OigoPermissionState {
        Self.currentMicrophonePermissionState()
    }

    private static func currentMicrophonePermissionState() -> OigoPermissionState {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            .granted
        case .denied:
            .denied
        case .undetermined:
            .unknown
        @unknown default:
            .unknown
        }
    }

    private func accessibilityPermissionState() -> OigoPermissionState {
        Self.currentAccessibilityPermissionState()
    }

    private static func currentAccessibilityPermissionState() -> OigoPermissionState {
        AXIsProcessTrusted() ? .granted : .denied
    }

    private static func requestAccessibilityPermission() -> OigoPermissionState {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        return currentAccessibilityPermissionState()
    }

    private static func hudDetail(for state: OigoHUDProcessingState) -> String {
        switch state {
        case .finalizing:
            "Finishing the saved transcript"
        case .cleaning:
            "Applying Clean mode when available"
        case .pasting:
            "Sending the completed transcript to the original field"
        case .pasted:
            "Transcript inserted"
        case .copied:
            "Copied to clipboard. Open History to retry paste."
        case .failed:
            "Failed. Open History to retry the saved recording."
        }
    }

    private static func friendlyError(_ prefix: String, _ error: Error) -> String {
        if let transcriptionError = error as? TranscriptionError {
            return prefix + ": " + transcriptionError.description
        }
        return prefix + ": " + String(describing: error)
    }

    private static func displayStatus(for outcome: InsertionOutcome) -> OigoHUDProcessingState {
        switch outcome {
        case .pasted:
            .pasted
        case .copied, .secureRejected:
            .copied
        case .failed:
            .failed
        }
    }
}
