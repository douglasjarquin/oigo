import AppKit
import AVFAudio
import ApplicationServices
import Darwin
import Foundation
import OigoCore
import OigoCapture
import OigoTranscription
import OigoInsertion
import OigoHotKey

@available(macOS 26.0, *)
@MainActor
final class OigoAppDelegate: NSObject, NSApplicationDelegate {
    private let coordinator = DictationCoordinator()
    private let performanceInstrumentation: PerformanceInstrumentation = OSLogPerformanceInstrumentation()
    private let deviceMonitor = SystemAudioDeviceMonitor()
    private let deviceInventoryMonitor = SystemAudioDeviceMonitor()
    private lazy var recorder = AudioRecorder(deviceMonitor: deviceMonitor)
    private var transcription: TranscriptionService?
    private lazy var insertion = InsertionService()
    private let playback = AudioPlayback()
    private let shortcutRegistrar = CarbonGlobalShortcutRegistrar()
    private lazy var shortcutBridge = GlobalShortcutOperationBridge(
        state: { [weak self] in self?.coordinator.state ?? .failed },
        start: { [weak self] in self?.startKeyboardDictation() },
        stop: { [weak self] in self?.requestKeyboardStop() },
        feedback: { [weak self] result in self?.showShortcutFeedback(result) }
    )
    private lazy var shortcutConfiguration = ShortcutConfigurationTransaction(
        committedShortcut: settings.globalShortcut,
        registrar: shortcutRegistrar,
        onEvent: { [weak self] event in self?.handleGlobalShortcut(event) }
    )
    private let statusSurface = StatusSurfaceController()
    private let settingsStore = OigoSettingsStore()
    private let onboardingStore = OigoOnboardingStore()
    private let storageCapability: DurableSessionCapability
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
    private var pendingSessionBoundary: DictationSession?
    private var reportedMalformedSessionCount = 0
    private var livePreview = ""
    private var settingsWindow: SettingsWindowController?
    private var historyWindow: HistoryWindowController?
    private var statusItem: NSStatusItem?
    private var toggleItem: NSMenuItem?
    private var shortcutStatusItem: NSMenuItem?
    private var modeMenuItem: NSMenuItem?
    private var instantModeItem: NSMenuItem?
    private var cleanModeItem: NSMenuItem?
    private var storageStatusItem: NSMenuItem?
    private var retryStorageItem: NSMenuItem?
    private var launchAtLoginItem: NSMenuItem?
    private var settings = OigoSettingsStore().load()
    private var targetSnapshot: InsertionTargetSnapshot?
    private var insertionDisplayStatus: OigoHUDProcessingState?
    private var failureDetail: String?
    private var onboardingWindow: OnboardingWindowController?
    private var recordingStartedAt: Date?
    private var previewThrottle = OigoHUDPreviewThrottle()
    private var toggleTask: Task<Void, Never>?
    private var finishRequestedAfterStart = false
    private var shortcutFeedbackDetail: String?
    private var cleanAgainTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var workspaceInterruptionTask: Task<Void, Never>?
    private var workspaceInterruptionOperationID: UUID?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var shortcutRegistered = false
    private let lifecycleOperationRegistry = OperationTaskRegistry()
    private let lifecycleOperationID = UUID()

    init(
        storageBootstrapper: any DurableSessionBootstrapping = DurableSessionBootstrapper()
    ) {
        storageCapability = DurableSessionCapability(bootstrapper: storageBootstrapper)
        super.init()
        storageCapability.onChange = { [weak self] in
            self?.storageCapabilityDidChange()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
        NSApp.setActivationPolicy(.accessory)
        startInputDeviceInventoryMonitor()
        let support = OigoSystemSupportEvaluator.current()
        guard support.isSupported else {
            showOnboarding(support)
            return
        }
        installWorkspaceInterruptionObservers()
        configureStatusItem()
        storageCapability.start()
        if onboardingStore.load().isComplete {
            updateSurface()
        } else {
            showOnboarding(support)
        }
        updateSurface()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        _ = sender
        unregisterShortcut()
        shortcutBridge.reset()
        let storageWasChecking = storageCapability.health == .checking
        storageCapability.shutdown()
        deviceInventoryMonitor.stop()
        removeWorkspaceInterruptionObservers()
        statusSurface.hide()
        playback.stop()
        let activeToggleTask = toggleTask
        let activeCleanAgainTask = cleanAgainTask
        let activeRetryTask = retryTask
        let activeWorkspaceInterruptionTask = workspaceInterruptionTask
        activeToggleTask?.cancel()
        activeCleanAgainTask?.cancel()
        activeRetryTask?.cancel()
        activeWorkspaceInterruptionTask?.cancel()
        if coordinator.hasActiveWork
            || activeToggleTask != nil
            || activeCleanAgainTask != nil
            || activeRetryTask != nil
            || activeWorkspaceInterruptionTask != nil
            || storageWasChecking {
            Task { @MainActor [weak self] in
                guard let self else {
                    NSApp.reply(toApplicationShouldTerminate: true)
                    return
                }
                _ = try? await BoundedOperation.run(
                    operationID: self.lifecycleOperationID,
                    stage: .shutdown,
                    timeout: TranscriptionTimeoutPolicy.production.budget(for: .shutdown),
                    registry: self.lifecycleOperationRegistry
                ) { @MainActor [weak self] in
                    guard let self else {
                        return
                    }
                    await self.finishApplicationTermination(
                        activeToggleTask: activeToggleTask,
                        activeCleanAgainTask: activeCleanAgainTask,
                        activeRetryTask: activeRetryTask,
                        activeWorkspaceInterruptionTask: activeWorkspaceInterruptionTask
                    )
                }
                await self.storageCapability.waitForCurrentAttempt()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        coordinator.shutdown()
        return .terminateNow
    }

    private func finishApplicationTermination(
        activeToggleTask: Task<Void, Never>?,
        activeCleanAgainTask: Task<Void, Never>?,
        activeRetryTask: Task<Void, Never>?,
        activeWorkspaceInterruptionTask: Task<Void, Never>?
    ) async {
        if let activeToggleTask {
            _ = try? await BoundedOperation.run(
                operationID: lifecycleOperationID,
                stage: .shutdown,
                timeout: TranscriptionTimeoutPolicy.production.budget(for: .shutdown),
                registry: lifecycleOperationRegistry
            ) {
                await activeToggleTask.value
            }
        }
        if let activeCleanAgainTask {
            _ = try? await BoundedOperation.run(
                operationID: lifecycleOperationID,
                stage: .shutdown,
                timeout: TranscriptionTimeoutPolicy.production.budget(for: .shutdown),
                registry: lifecycleOperationRegistry
            ) {
                await activeCleanAgainTask.value
            }
        }
        if coordinator.hasActiveTranscription {
            await coordinator.shutdownWithTranscription()
        } else {
            await coordinator.shutdownAndWait()
        }
        if let activeRetryTask {
            _ = try? await BoundedOperation.run(
                operationID: lifecycleOperationID,
                stage: .shutdown,
                timeout: TranscriptionTimeoutPolicy.production.budget(for: .shutdown),
                registry: lifecycleOperationRegistry
            ) {
                await activeRetryTask.value
            }
        }
        if let activeWorkspaceInterruptionTask {
            _ = try? await BoundedOperation.run(
                operationID: lifecycleOperationID,
                stage: .shutdown,
                timeout: TranscriptionTimeoutPolicy.production.budget(for: .shutdown),
                registry: lifecycleOperationRegistry
            ) {
                await activeWorkspaceInterruptionTask.value
            }
        }
    }

    @objc private func toggleDictation() {
        handleMouseToggle()
    }

    @objc private func openSettings() {
        if let settingsWindow, settingsWindow.window?.isVisible == true {
            settingsWindow.showWindow(nil)
            settingsWindow.window?.makeKeyAndOrderFront(nil)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let supportedLocales = self.storageCapability.health.isReady
                ? await self.transcriptionService().supportedLocaleIdentifiers()
                : []
            self.presentSettings(supportedLocales: supportedLocales)
        }
    }

    private func presentSettings(supportedLocales: [String]) {
        let window = SettingsWindowController(
            settings: settings,
            inputDevices: currentInputDevices(),
            supportedLocales: supportedLocales,
            microphoneState: microphonePermissionState(),
            accessibilityState: accessibilityPermissionState(),
            storageHealth: displayedStorageHealth,
            registrationStatus: { [weak self] in
                self?.shortcutRegistrar.status ?? .inactive("Global shortcut is not registered")
            },
            registrationError: { [weak self] in
                self?.shortcutConfiguration.lastError ?? self?.shortcutRegistrar.lastError
            },
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
            retryStorage: { [weak self] in
                self?.retryStorageAction()
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
            inputDevices: currentInputDevices(),
            selectedInput: settings.selectedInput,
            microphoneState: microphonePermissionState(),
            accessibilityState: accessibilityPermissionState(),
            storageHealth: displayedStorageHealth,
            loadSupportedLanguages: { [weak self] in
                guard let self else { return [] }
                guard self.storageCapability.health.isReady else { return [] }
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
                guard self.storageCapability.health.isReady else {
                    return .unavailable("durable storage is unavailable")
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
                let updatedSettings = self.settings.with(localeIdentifier: identifier)
                do {
                    try self.settingsStore.save(updatedSettings)
                    self.settings = updatedSettings
                    self.transcription = nil
                } catch {
                    self.showSettingsPersistenceFailure(error)
                }
            },
            saveStep: { [weak self] step in
                self?.onboardingStore.save(OigoOnboardingState(step: step))
            },
            saveInputSelection: { [weak self] selection in
                guard let self else { return }
                let updatedSettings = self.settings.with(selectedInput: selection)
                do {
                    try self.settingsStore.save(updatedSettings)
                    self.settings = updatedSettings
                    self.recorder.setInputSelection(selection)
                } catch {
                    self.showSettingsPersistenceFailure(error)
                }
            },
            requestMicrophone: {
                _ = await AudioRecorder.requestMicrophonePermission()
                return Self.currentMicrophonePermissionState()
            },
            openMicrophoneSettings: { [weak self] in
                self?.openSystemSettings(OigoPermissionPresentation.microphone(.denied).settingsURL)
            },
            registrationStatus: { [weak self] in
                self?.shortcutRegistrar.status ?? .inactive("Global shortcut is not registered")
            },
            registrationError: { [weak self] in
                self?.shortcutConfiguration.lastError ?? self?.shortcutRegistrar.lastError
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
            retryStorage: { [weak self] in
                self?.retryStorageAction()
            },
            openDataLocation: { [weak self] in
                self?.openDataFolder()
            },
            startTest: { [weak self] in
                self?.onboardingWindow?.focusTestField()
                self?.handleMouseToggle(allowBeforeSetup: true)
            },
            stopTest: { [weak self] in
                self?.finishTestDictation()
            },
            cancelTest: { [weak self] in
                self?.cancelTestDictation()
            },
            openHistory: { [weak self] in
                self?.openHistory()
            },
            onComplete: { [weak self] in
                guard let self else { return }
                guard self.storageCapability.health.isReady else {
                    self.updateSurface()
                    return
                }
                guard self.shortcutRegistrar.status.isActive else {
                    self.onboardingWindow?.showRegistrationFailure(
                        self.shortcutRegistrar.lastError ?? self.shortcutRegistrar.status.message
                    )
                    self.updateSurface()
                    return
                }
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

        let storageStatus = NSMenuItem(
            title: DurableSessionHealth.checking.statusMessage,
            action: nil,
            keyEquivalent: ""
        )
        storageStatus.isEnabled = false
        menu.addItem(storageStatus)

        let retryStorage = NSMenuItem(
            title: "Retry Storage",
            action: #selector(retryStorageAction),
            keyEquivalent: ""
        )
        retryStorage.target = self
        menu.addItem(retryStorage)
        let shortcutStatus = NSMenuItem(
            title: "Global Shortcut Inactive - Open Settings…",
            action: #selector(openSettings),
            keyEquivalent: ""
        )
        shortcutStatus.target = self
        menu.addItem(shortcutStatus)

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
        shortcutStatusItem = shortcutStatus
        modeMenuItem = mode
        instantModeItem = instant
        cleanModeItem = clean
        storageStatusItem = storageStatus
        retryStorageItem = retryStorage
        launchAtLoginItem = launchAtLogin
    }

    private func registerShortcut() {
        guard storageCapability.health.isReady,
              onboardingStore.load().isComplete,
              !shortcutRegistered else {
            return
        }
        do {
            try shortcutRegistrar.register(shortcut: settings.globalShortcut) { [weak self] event in
                self?.handleGlobalShortcut(event)
            }
            shortcutConfiguration.clearError()
            shortcutBridge.reset()
            shortcutRegistered = true
        } catch {
            NSLog("Oigo could not register the global toggle shortcut: %@", Self.failureReason(for: error))
            shortcutBridge.reset()
            updateSurface()
        }
    }

    private func unregisterShortcut() {
        shortcutRegistrar.unregister()
        shortcutRegistered = false
    }

    private func installWorkspaceInterruptionObservers() {
        removeWorkspaceInterruptionObservers()
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            NSWorkspace.willSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification
        ].map { name in
            center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                let reason = name == NSWorkspace.willSleepNotification
                    ? "system sleep interrupted dictation operation"
                    : "screen lock interrupted dictation operation"
                Task { @MainActor [weak self] in
                    self?.handleWorkspaceInterruption(reason)
                }
            }
        }
    }

    private func removeWorkspaceInterruptionObservers() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
        workspaceObservers.removeAll(keepingCapacity: false)
    }

    private func handleWorkspaceInterruption(_ reason: String) {
        workspaceInterruptionTask?.cancel()
        let operationID = UUID()
        workspaceInterruptionOperationID = operationID
        workspaceInterruptionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = try? await BoundedOperation.run(
                operationID: operationID,
                stage: .interruption,
                timeout: TranscriptionTimeoutPolicy.production.budget(for: .interruption),
                registry: lifecycleOperationRegistry
            ) { @MainActor [weak self] in
                guard let self else {
                    return
                }
                let activeToggleTask = self.toggleTask
                let activeCleanAgainTask = self.cleanAgainTask
                let activeRetryTask = self.retryTask
                activeToggleTask?.cancel()
                activeCleanAgainTask?.cancel()
                activeRetryTask?.cancel()
                await self.coordinator.cancelActiveWork(reason: reason)
                if let activeToggleTask {
                    await activeToggleTask.value
                }
                if let activeCleanAgainTask {
                    await activeCleanAgainTask.value
                }
                if let activeRetryTask {
                    await activeRetryTask.value
                }
                self.lastSession = self.coordinator.currentSession ?? self.lastSession
                self.recordingStartedAt = nil
                self.targetSnapshot = nil
                self.livePreview = ""
                self.insertionDisplayStatus = nil
            }
            guard self.workspaceInterruptionOperationID == operationID else {
                return
            }
            self.shortcutBridge.reset()
            self.updateSurface()
            self.workspaceInterruptionTask = nil
            self.workspaceInterruptionOperationID = nil
        }
    }

    private func handleMouseToggle(allowBeforeSetup: Bool = false) {
        performanceInstrumentation.mark(.shortcutReceived)
        guard allowBeforeSetup || onboardingStore.load().isComplete else {
            showOnboarding(OigoSystemSupportEvaluator.current())
            return
        }
        guard storageCapability.health.isReady else {
            updateSurface()
            return
        }

        switch coordinator.state {
        case .idle, .complete, .failed, .cancelled, .interrupted:
            startDictation()
        case .recording:
            finishDictation()
        case .preparing, .finalizing, .cleaning, .inserting:
            showShortcutFeedback(.ignoredProcessing(coordinator.state))
        }
    }

    private func handleGlobalShortcut(_ event: GlobalShortcutEvent) {
        performanceInstrumentation.mark(.shortcutReceived)
        let edge: GlobalShortcutIntentEdge = switch event.edge {
        case .pressed:
            .pressed
        case .released:
            .released
        }
        _ = shortcutBridge.receive(edge)
    }

    private func startKeyboardDictation() {
        guard onboardingStore.load().isComplete else {
            shortcutBridge.reset()
            return
        }
        startDictation()
    }

    private func requestKeyboardStop() {
        if toggleTask != nil {
            finishRequestedAfterStart = true
            return
        }
        finishDictation()
    }

    private func startDictation() {
        guard storageCapability.health.isReady else {
            updateSurface()
            return
        }
        guard toggleTask == nil else {
            showShortcutFeedback(.ignoredBusy(coordinator.state))
            return
        }
        do {
            toggleTask = try coordinator.startTask { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    let shouldFinish = self.finishRequestedAfterStart
                    self.finishRequestedAfterStart = false
                    self.toggleTask = nil
                    if shouldFinish {
                        self.scheduleFinishAfterCurrentTask()
                    }
                }
                await self.performStartDictation()
                if self.coordinator.state == .recording {
                    _ = self.shortcutBridge.observeState()
                } else {
                    self.shortcutBridge.reset()
                }
            }
        } catch {
            shortcutBridge.reset()
            NSLog("Oigo could not start its coordinator-owned dictation task: %@", Self.failureReason(for: error))
        }
    }

    private func finishDictation() {
        guard toggleTask == nil else {
            showShortcutFeedback(.ignoredBusy(coordinator.state))
            return
        }
        do {
            toggleTask = try coordinator.startTask { @MainActor [weak self] in
                guard let self else { return }
                defer { self.toggleTask = nil }
                await self.performFinishDictation()
            }
        } catch {
            shortcutBridge.reset()
            NSLog("Oigo could not start its coordinator-owned finish task: %@", Self.failureReason(for: error))
        }
    }

    private func cancelTestDictation() {
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

    private func finishTestDictation() {
        let activeToggleTask = toggleTask
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let activeToggleTask {
                await activeToggleTask.value
            }
            guard self.coordinator.state == .recording else {
                return
            }
            self.finishDictation()
        }
    }

    private func performStartDictation() async {
        do {
            switch coordinator.state {
            case .idle, .complete, .failed, .cancelled, .interrupted:
                insertionDisplayStatus = nil
                lastSession = try await DurableSessionDictationBoundary.withPersistedSession(
                    using: storageCapability
                ) { [self] persistedSession, store in
                    pendingSessionBoundary = persistedSession
                    lastSession = persistedSession
                    failureDetail = nil
                    insertionDisplayStatus = nil
                    try await ensureMicrophonePermission()
                    try Task.checkCancellation()
                    targetSnapshot = insertion.captureTarget()
                    recorder.setInputSelection(settings.selectedInput)
                    let format = try recorder.captureFormat()
                    try Task.checkCancellation()
                    let service = transcriptionService()
                    recordingStartedAt = Date()
                    previewThrottle = OigoHUDPreviewThrottle()
                    return try await coordinator.startPersistedRecordingWithTranscription(
                        persistedSession,
                        using: recorder,
                        store: store,
                        transcription: service,
                        format: format,
                        onUpdate: { [weak self] update in
                            Task { @MainActor [weak self] in
                                self?.applyTranscriptionUpdate(update)
                            }
                        }
                    )
                }
                pendingSessionBoundary = nil
            case .recording:
                guard storageCapability.health.isReady else {
                    throw DurableSessionAccessError.storageUnavailable(
                        storageCapability.health.failureCategory
                    )
                }
                let terminalMode = transcriptCleanupMode(for: settings.defaultMode)
                insertionDisplayStatus = .finalizing
                updateSurface()
                _ = try await coordinator.stopRecordingWithTranscription()
                recordingStartedAt = nil
                guard storageCapability.health.isReady,
                      let snapshot = targetSnapshot,
                      let store = sessionStore else {
                    throw DurableSessionAccessError.storageUnavailable(
                        storageCapability.health.failureCategory
                    )
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
                guard storageCapability.health.isReady else {
                    throw DurableSessionAccessError.storageUnavailable(
                        storageCapability.health.failureCategory
                    )
                }
                insertionDisplayStatus = .pasting
                updateSurface()
                explainAccessibilityBeforePaste()
                let result: InsertionResult = {
                    performanceInstrumentation.mark(.insertionStart)
                    defer { performanceInstrumentation.mark(.insertionEnd) }
                    return insertion.insertText(
                        for: insertionSession,
                        source: decision.insertionSource,
                        store: store,
                        target: snapshot
                    )
                }()
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
            settlePendingSessionBoundary(
                reason: "dictation operation cancelled",
                cancelled: true
            )
            lastSession = coordinator.currentSession ?? lastSession
            recordingStartedAt = nil
            targetSnapshot = nil
            livePreview = ""
            if !coordinator.hasActiveWork {
                insertionDisplayStatus = nil
            }
            failureDetail = nil
            updateSurface()
        } catch {
            let failureReason = Self.failureReason(for: error)
            if coordinator.hasActiveWork {
                await coordinator.cancelActiveWork(reason: failureReason)
            }
            settlePendingSessionBoundary(
                reason: failureReason,
                cancelled: false
            )
            markStorageUnhealthyIfNeeded(error)
            shortcutBridge.reset()
            lastSession = coordinator.currentSession ?? lastSession
            targetSnapshot = nil
            recordingStartedAt = nil
            insertionDisplayStatus = .failed
            failureDetail = Self.friendlyError("Dictation failed", error)
            if let session = coordinator.currentSession,
               [.failed, .interrupted].contains(session.metadata.state) {
                lastSession = session
            }
            historyWindow?.showMessage(failureDetail ?? Self.friendlyError("Dictation failed", error))
            onboardingWindow?.setTestResult(
                transcript: "",
                mode: settings.defaultMode,
                copied: false
            )
            NSLog("Oigo rejected the dictation start command: %@", failureReason)
            updateSurface()
        }
    }

    private func performFinishDictation() async {
        do {
            guard coordinator.state == .recording else {
                throw DictationTransitionError.illegal(
                    from: coordinator.state,
                    event: .stop
                )
            }
            let terminalMode = transcriptCleanupMode(for: settings.defaultMode)
            insertionDisplayStatus = .finalizing
            shortcutFeedbackDetail = nil
            updateSurface()
            _ = try await coordinator.stopRecordingWithTranscription()
            recordingStartedAt = nil
            guard storageCapability.health.isReady else {
                throw DurableSessionAccessError.storageUnavailable(
                    storageCapability.health.failureCategory
                )
            }
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
            guard storageCapability.health.isReady else {
                throw DurableSessionAccessError.storageUnavailable(
                    storageCapability.health.failureCategory
                )
            }
            insertionDisplayStatus = .pasting
            updateSurface()
            explainAccessibilityBeforePaste()
            let result: InsertionResult = {
                performanceInstrumentation.mark(.insertionStart)
                defer { performanceInstrumentation.mark(.insertionEnd) }
                return insertion.insertText(
                    for: insertionSession,
                    source: decision.insertionSource,
                    store: store,
                    target: snapshot
                )
            }()
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
            if historyWindow != nil {
                refreshHistory()
            }
            updateSurface()
        } catch is CancellationError {
            await coordinator.cancelActiveWork()
            shortcutBridge.reset()
            lastSession = coordinator.currentSession ?? lastSession
            recordingStartedAt = nil
            targetSnapshot = nil
            livePreview = ""
            if !coordinator.hasActiveWork {
                insertionDisplayStatus = nil
            }
            updateSurface()
        } catch {
            let failureReason = Self.failureReason(for: error)
            if coordinator.hasActiveWork {
                await coordinator.cancelActiveWork(reason: failureReason)
            }
            markStorageUnhealthyIfNeeded(error)
            shortcutBridge.reset()
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
            NSLog("Oigo rejected the dictation finish command: %@", failureReason)
            updateSurface()
        }
    }

    private func scheduleFinishAfterCurrentTask() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            while self.coordinator.activeTaskCount != 0 {
                await Task.yield()
            }
            self.finishDictation()
        }
    }

    private func showShortcutFeedback(_ result: GlobalShortcutIntentResult) {
        switch result {
        case .ignoredProcessing(let state):
            let displayState: OigoHUDProcessingState?
            switch state {
            case .finalizing:
                displayState = .finalizing
            case .cleaning:
                displayState = .cleaning
            case .inserting:
                displayState = .pasting
            default:
                displayState = nil
            }
            guard let displayState else { return }
            insertionDisplayStatus = displayState
            shortcutFeedbackDetail = "Shortcut ignored while \(state.rawValue.capitalized) is running"
            updateSurface()
        case .ignoredRecordingNotOwned:
            statusItem?.button?.toolTip = "Shortcut ignored: recording was started from the menu"
        case .ignoredBusy(let state):
            statusItem?.button?.toolTip = "Shortcut ignored while \(state.rawValue.capitalized) is running"
        default:
            break
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
        guard storageCapability.health.isReady,
              let store = sessionStore,
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
            markStorageUnhealthyIfNeeded(error)
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

        performanceInstrumentation.mark(.cleanupStart)
        defer { performanceInstrumentation.mark(.cleanupEnd) }
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
                if Self.storageFailureCategory(error) != nil {
                    throw error
                }
                transcriptCleanupMetrics.record(.fallback)
                decision = TranscriptCleanupDecision(
                    rawText: rawText,
                    insertionText: rawText,
                    cleanText: nil,
                    insertionSource: .raw,
                    fallbackReason: .persistenceFailure(Self.failureReason(for: error)),
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
        guard storageCapability.health.isReady,
              cleanAgainTask == nil,
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
            guard storageCapability.health.isReady else {
                return
            }
            let rawText = try store.readRawText(for: entry.session)
            let decision = await transcriptCleanup.resolve(
                mode: .clean,
                rawText: rawText,
                deadlineNanoseconds: 4_000_000_000
            )
            try Task.checkCancellation()
            guard storageCapability.health.isReady else {
                return
            }
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
                if Self.storageFailureCategory(error) != nil {
                    throw error
                }
                let fallbackReason = TranscriptCleanupFallbackReason
                    .persistenceFailure(Self.failureReason(for: error))
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
                markStorageUnhealthyIfNeeded(error)
                historyWindow?.showMessage(Self.friendlyError("Clean Again failed", error))
            }
        } catch is CancellationError {
            return
        } catch {
            markStorageUnhealthyIfNeeded(error)
            historyWindow?.showMessage(Self.friendlyError("Clean Again failed", error))
        }
    }

    private func pasteCleanAgain(for entry: SessionHistoryEntry) {
        guard storageCapability.health.isReady,
              let store = sessionStore else {
            return
        }
        historyWindow?.window?.orderOut(nil)
        NSApp.hide(nil)
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            guard self.storageCapability.health.isReady else {
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
                case .dispatched:
                    self.historyWindow?.showMessage(
                        "Clean transcript paste attempted. Clipboard retained."
                    )
                case .copied, .secureRejected:
                    self.historyWindow?.showMessage("Clean transcript copied. " + (result.reason ?? "Paste was not sent."))
                case .failed:
                    self.historyWindow?.showMessage("Paste Clean Again failed: " + (result.reason ?? "the paste could not be completed"))
                }
                self.refreshHistory()
            } catch {
                self.markStorageUnhealthyIfNeeded(error)
                self.historyWindow?.showMessage(Self.friendlyError("Paste Clean Again failed", error))
            }
        }
    }

    private func pasteAgain(for entry: SessionHistoryEntry) {
        guard storageCapability.health.isReady,
              let store = sessionStore else {
            return
        }
        historyWindow?.window?.orderOut(nil)
        NSApp.hide(nil)
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            guard self.storageCapability.health.isReady else {
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
                case .dispatched:
                    self.historyWindow?.showMessage("Paste attempted. Clipboard retained.")
                case .copied, .secureRejected:
                    self.historyWindow?.showMessage("Raw transcript copied. " + (result.reason ?? "Paste was not sent."))
                case .failed:
                    self.historyWindow?.showMessage("Paste Again failed: " + (result.reason ?? "the paste could not be completed"))
                }
                self.refreshHistory()
            } catch {
                self.markStorageUnhealthyIfNeeded(error)
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
        guard storageCapability.health.isReady,
              let store = sessionStore else {
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
            markStorageUnhealthyIfNeeded(error)
            historyWindow?.showMessage(Self.friendlyError("Delete failed", error))
        }
        updateSurface()
    }

    private func refreshHistory() {
        guard storageCapability.health.isReady,
              let store = sessionStore else {
            return
        }
        do {
            let report = try store.listHistoryReport()
            reportedMalformedSessionCount = report.malformedSessionCount
            lastSession = report.entries.first?.session
            historyWindow?.reload(entries: report.entries)
            settingsWindow?.setStorageHealth(displayedStorageHealth)
            onboardingWindow?.setStorageHealth(displayedStorageHealth)
        } catch {
            markStorageUnhealthyIfNeeded(error)
            historyWindow?.showMessage(
                storageCapability.health.failureCategory == nil
                    ? Self.friendlyError("History unavailable", error)
                    : storageCapability.health.statusMessage
            )
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
        guard storageCapability.health.isReady,
              let store = sessionStore else {
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
            markStorageUnhealthyIfNeeded(error)
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
        let storageReady = storageCapability.health.isReady
        let canToggle = [
            .idle,
            .recording,
            .complete,
            .failed,
            .cancelled,
            .interrupted
        ].contains(coordinator.state)
        toggleItem?.title = storageReady
            ? (isRecording ? "Stop Dictation" : "Start Dictation")
            : "Storage unavailable"
        toggleItem?.action = storageReady ? #selector(toggleDictation) : #selector(retryStorageAction)
        toggleItem?.isEnabled = setupComplete && (storageReady ? canToggle : true)
        instantModeItem?.state = settings.defaultMode == .instant ? .on : .off
        cleanModeItem?.state = settings.defaultMode == .clean ? .on : .off
        modeMenuItem?.isEnabled = setupComplete && storageReady && !isRecording
        storageStatusItem?.title = displayedStorageHealth.statusMessage
        retryStorageItem?.isEnabled = !storageReady && storageCapability.health != .checking
        launchAtLoginItem?.state = launchAtLoginController.isEnabled ? .on : .off
        statusItem?.button?.title = "Oigo"
        switch shortcutRegistrar.status {
        case .active(let shortcut, _):
            if let error = shortcutConfiguration.lastError {
                shortcutStatusItem?.title = "Global Shortcut Active - Open Settings…"
                statusItem?.button?.toolTip = "Global shortcut active: \(shortcut.displayName). Last registration error: \(error)"
            } else {
                shortcutStatusItem?.title = "Global Shortcut: " + shortcut.displayName
                statusItem?.button?.toolTip = shortcutFeedbackDetail
                    ?? "Global shortcut active: " + shortcut.displayName
            }
        case .inactive(let message):
            let error = shortcutConfiguration.lastError ?? message
            shortcutStatusItem?.title = "Global Shortcut Inactive - Open Settings…"
            statusItem?.button?.toolTip = "Global Shortcut Inactive: " + error
        }

        if isRecording {
            statusSurface.showRecording(
                startedAt: recordingStartedAt ?? Date(),
                preview: settings.showVolatilePreview ? livePreview : "",
                anchoredTo: statusItem?.button
            )
        } else if let insertionDisplayStatus {
            statusSurface.showProcessing(
                insertionDisplayStatus,
                detail: shortcutFeedbackDetail
                    ?? failureDetail
                    ?? Self.hudDetail(for: insertionDisplayStatus),
                anchoredTo: statusItem?.button
            )
        } else {
            statusSurface.hide()
        }
    }

    @objc private func selectInstantMode() {
        let updatedSettings = settings.with(defaultMode: .instant)
        do {
            try settingsStore.save(updatedSettings)
            settings = updatedSettings
            updateSurface()
        } catch {
            showSettingsPersistenceFailure(error)
        }
    }

    @objc private func selectCleanMode() {
        let updatedSettings = settings.with(defaultMode: .clean)
        do {
            try settingsStore.save(updatedSettings)
            settings = updatedSettings
            updateSurface()
        } catch {
            showSettingsPersistenceFailure(error)
        }
    }

    @objc private func toggleLaunchAtLogin() {
        let enabled = !launchAtLoginController.isEnabled
        let previousSettings = settings
        let updatedSettings = settings.with(launchAtLogin: enabled)
        do {
            try launchAtLoginController.setEnabled(enabled)
            do {
                try settingsStore.save(updatedSettings)
            } catch {
                var message = error.localizedDescription
                do {
                    try launchAtLoginController.setEnabled(previousSettings.launchAtLogin)
                } catch let restoreError {
                    message += "; Launch at Login could not be restored: \(restoreError)"
                }
                showSettingsPersistenceFailure(message: message)
                return
            }
            settings = updatedSettings
            updateSurface()
        } catch {
            showSettingsPersistenceFailure(
                title: "Launch at Login could not be changed",
                message: Self.failureReason(for: error)
            )
        }
    }

    @objc private func playLastRecording() {
        guard let session = lastSession else {
            return
        }
        do {
            _ = try playback.play(url: session.audioURL)
        } catch {
            NSLog("Oigo could not play the last recording: %@", Self.failureReason(for: error))
        }
    }

    @objc private func revealLastRecording() {
        guard let session = lastSession else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([session.directoryURL])
    }

    @objc private func retryStorageAction() {
        _ = storageCapability.retry()
        updateSurface()
    }

    private func settlePendingSessionBoundary(reason: String, cancelled: Bool) {
        guard let pendingSessionBoundary else {
            return
        }
        self.pendingSessionBoundary = nil
        guard coordinator.currentSession?.id != pendingSessionBoundary.id,
              let store = sessionStore else {
            return
        }
        let state: DictationSessionState = cancelled ? .cancelled : .failed
        let failureCode = cancelled
            ? DictationFailureCode.cancelled
            : DictationFailureCode.infer(from: reason)
        lastSession = (try? store.update(
            pendingSessionBoundary,
            state: state,
            failureReason: reason,
            failureCode: failureCode
        )) ?? pendingSessionBoundary
    }

    private func storageCapabilityDidChange() {
        sessionStore = storageCapability.store
        if storageCapability.health.isReady {
            if case .ready(let report) = storageCapability.health {
                reportedMalformedSessionCount = report.malformedSessionCount
            }
            lastSession = storageCapability.history.first?.session
            historyWindow?.reload(entries: storageCapability.history)
            if onboardingStore.load().isComplete {
                registerShortcut()
            }
        } else {
            unregisterShortcut()
            reportedMalformedSessionCount = 0
            historyWindow?.showMessage(displayedStorageHealth.statusMessage)
        }
        settingsWindow?.setStorageHealth(displayedStorageHealth)
        onboardingWindow?.setStorageHealth(displayedStorageHealth)
        updateSurface()
    }

    private var displayedStorageHealth: DurableSessionHealth {
        guard case .ready(let report) = storageCapability.health else {
            return storageCapability.health
        }
        return .ready(
            DurableSessionBootstrapReport(
                recoveredSessionCount: report.recoveredSessionCount,
                historyEntryCount: report.historyEntryCount,
                malformedSessionCount: reportedMalformedSessionCount
            )
        )
    }

    private func markStorageUnhealthyIfNeeded(_ error: Error) {
        guard let category = Self.storageFailureCategory(error) else {
            return
        }
        storageCapability.markUnhealthy(category)
    }

    private static func storageFailureCategory(_ error: Error) -> DurableSessionFailureCategory? {
        if let failure = error as? DurableSessionBootstrapFailure {
            return failure.category
        }
        guard let error = error as? SessionStoreError else {
            return nil
        }
        switch error {
        case .applicationSupportUnavailable:
            return .unavailableParent
        case .stateChanged:
            return .metadataRecoveryFailure
        case .invalidMetadata,
             .invalidSessionDirectory:
            return .metadataRecoveryFailure
        case .missingSession,
             .transcriptTooLarge,
             .insertionAlreadyAttempted,
             .activeSession,
             .rawTextChanged,
             .deletionConfirmationRequired:
            return nil
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
        let service = TranscriptionService(
            locale: Locale(identifier: identifier),
            instrumentation: performanceInstrumentation
        )
        transcription = service
        return service
    }

    private func transcriptCleanupMode(for mode: OigoProcessingMode) -> TranscriptCleanupMode {
        TranscriptCleanupMode(rawValue: mode.rawValue) ?? .instant
    }

    private func applySettings(_ newSettings: OigoSettings) -> String? {
        let previousSettings = settings
        let shortcutChanged = previousSettings.globalShortcut != newSettings.globalShortcut
        let launchAtLoginChanged = previousSettings.launchAtLogin != newSettings.launchAtLogin

        if launchAtLoginChanged {
            do {
                try launchAtLoginController.setEnabled(newSettings.launchAtLogin)
            } catch {
                registerShortcut()
                return "Launch at Login could not be changed: " + Self.failureReason(for: error)
            }
        }

        if shortcutChanged {
            let shortcutValidation = shortcutConfiguration.save(
                newSettings.globalShortcut,
                persist: { [weak self] shortcut in
                    guard let self else { throw OigoSettingsStoreError.storeUnavailable }
                    try self.settingsStore.save(newSettings.with(globalShortcut: shortcut))
                },
                restore: { [weak self] in
                    guard let self else { throw OigoSettingsStoreError.storeUnavailable }
                    try self.settingsStore.save(previousSettings)
                }
            )
            guard shortcutValidation.isAvailable else {
                let shortcutError = Self.shortcutValidationMessage(shortcutValidation)
                guard launchAtLoginChanged else {
                    updateSurface()
                    return shortcutError
                }
                do {
                    try launchAtLoginController.setEnabled(previousSettings.launchAtLogin)
                } catch {
                    updateSurface()
                    return shortcutError + "; Launch at Login could not be restored: " + Self.failureReason(for: error)
                }
                updateSurface()
                return shortcutError
            }
        } else {
            do {
                try settingsStore.save(newSettings)
            } catch {
                var message = "Settings could not be saved: \(error)"
                guard launchAtLoginChanged else {
                    updateSurface()
                    return message
                }
                do {
                    try launchAtLoginController.setEnabled(previousSettings.launchAtLogin)
                } catch let restoreError {
                    message += "; Launch at Login could not be restored: \(restoreError)"
                }
                updateSurface()
                return message
            }
        }

        settings = newSettings
        recorder.setInputSelection(settings.selectedInput)
        if previousSettings.localeIdentifier != settings.localeIdentifier {
            transcription = nil
        }
        if !shortcutRegistrar.status.isActive {
            registerShortcut()
        }
        updateSurface()
        return nil
    }

    private func currentInputDevices() -> [OigoInputDevice] {
        (try? deviceInventoryMonitor.currentDevices()) ?? []
    }

    private func startInputDeviceInventoryMonitor() {
        deviceInventoryMonitor.start { [weak self] devices in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.settingsWindow?.updateInputDevices(devices)
                self.onboardingWindow?.updateInputDevices(devices)
            }
        }
    }

    private func validateShortcut(_ candidate: ToggleShortcut) -> OigoShortcutValidation {
        guard storageCapability.health.isReady else {
            return .invalid("Storage unavailable. Retry storage before enabling a shortcut.")
        }
        shortcutConfiguration.setCandidate(candidate)
        return shortcutConfiguration.validate(candidate)
    }

    private func saveShortcut(_ candidate: ToggleShortcut) -> OigoShortcutValidation {
        let previousSettings = settings
        let validation = shortcutConfiguration.save(
            candidate,
            persist: { [weak self] shortcut in
                guard let self else { throw OigoSettingsStoreError.storeUnavailable }
                try self.settingsStore.save(previousSettings.with(globalShortcut: shortcut))
            },
            restore: { [weak self] in
                guard let self else { throw OigoSettingsStoreError.storeUnavailable }
                try self.settingsStore.save(previousSettings)
            }
        )
        guard validation.isAvailable else {
            updateSurface()
            return validation
        }
        settings = previousSettings.with(globalShortcut: candidate)
        updateSurface()
        return .available
    }

    private static func shortcutValidationMessage(_ validation: OigoShortcutValidation) -> String {
        switch validation {
        case .available:
            ""
        case .conflict(let reason), .invalid(let reason):
            reason
        }
    }

    private func showSettingsPersistenceFailure(_ error: Error) {
        showSettingsPersistenceFailure(message: error.localizedDescription)
    }

    private func showSettingsPersistenceFailure(message: String) {
        showSettingsPersistenceFailure(title: "Settings could not be saved", message: message)
    }

    private func showSettingsPersistenceFailure(title: String, message: String) {
        NSLog("Oigo settings persistence failed: %@", message)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    private func rerunOnboarding() {
        onboardingStore.rerun()
        showOnboarding(OigoSystemSupportEvaluator.current())
    }

    @objc private func openDataFolder() {
        guard let root = try? SessionStore.defaultRootDirectory() else {
            return
        }
        NSWorkspace.shared.open(root)
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
            alert.informativeText = Self.failureReason(for: error)
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
        case .pasteAttempted:
            "Paste attempted; clipboard retained"
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
        return prefix + ": " + failureReason(for: error)
    }

    private static func failureReason(for error: Error) -> String {
        if let category = storageFailureCategory(error) {
            return "storage failure: " + category.statusDescription
        }
        if let error = error as? SessionStoreError {
            switch error {
            case .stateChanged:
                return "saved session state changed"
            case .transcriptTooLarge:
                return "saved transcript is too large"
            case .rawTextChanged:
                return "saved transcript changed before cleanup completed"
            case .missingSession:
                return "saved session is unavailable"
            case .insertionAlreadyAttempted:
                return "saved session insertion was already attempted"
            case .activeSession:
                return "saved session is still active"
            case .deletionConfirmationRequired:
                return "history deletion requires confirmation"
            case .applicationSupportUnavailable,
                 .invalidMetadata,
                 .invalidSessionDirectory:
                return "durable session storage is unavailable"
            }
        }
        return "operation failed"
    }

    private static func displayStatus(for outcome: InsertionOutcome) -> OigoHUDProcessingState {
        switch outcome {
        case .pasted:
            .pasted
        case .dispatched:
            .pasteAttempted
        case .copied, .secureRejected:
            .copied
        case .failed:
            .failed
        }
    }
}
