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

@MainActor
private final class DestinationHandoffWaiter {
    private var observer: NSObjectProtocol?
    private var continuation: CheckedContinuation<Void, Never>?
    private var finished = false

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.continuation = continuation
            observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.finish()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.finish()
            }
        }
    }

    private func finish() {
        guard !finished else {
            return
        }
        finished = true
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        self.observer = nil
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume()
    }
}

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
    private var dictionaryStore: DictionaryStore?
    private var dictionaryDocument = DictionaryDocument.empty
    private var dictionaryLoadError: String?
    private var lastSession: DictationSession?
    private var pendingSessionBoundary: DictationSession?
    private var reportedMalformedSessionCount = 0
    private var livePreview = ""
    private var settingsWindow: SettingsWindowController?
    private var settingsSessionID: UUID?
    private var historyWindow: HistoryWindowController?
    private var historyLoadGeneration = HistoryLoadGeneration()
    private var historyCursor: SessionHistoryCursor?
    private var historyHasMore = false
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
    private var lastFailureCode: String?
    private lazy var insertionTargetHandoff = InsertionTargetHandoff(
        waitForDestination: { [weak self] in
            await self?.waitForDestinationHandoff()
        }
    )
    private lazy var pasteAgainFlow = InsertionPasteAgainFlow(handoff: insertionTargetHandoff)
    private var onboardingWindow: OnboardingWindowController?
    private var onboardingSourceProbe: OnboardingSourceProbe?
    private var onboardingTestGeneration: UInt64?
    private var onboardingTestSessionID: UUID?
    private var recordingStartedAt: Date?
    private var previewThrottle = OigoHUDPreviewThrottle()
    private let operationGate = AppOperationGate()
    private var maintenanceHandle: AppOperationHandle?
    nonisolated(unsafe) private var maintenanceStore: SessionStore?
    nonisolated(unsafe) private var maintenancePolicy = SessionRetentionPolicy.default
    private lazy var maintenanceCoordinator = SessionMaintenanceCoordinator(
        canRun: { [weak self] in
            guard let self else {
                return false
            }
            return self.commandAvailability.canRunMaintenance
                && !self.coordinator.hasActiveTranscription
                && !self.playback.hasActivePlayback
        },
        beginRun: { [weak self] in
            guard let self else {
                return false
            }
            switch self.operationGate.begin(.maintenance) {
            case .success(let handle):
                self.maintenanceHandle = handle
                return true
            case .failure:
                return false
            }
        },
        endRun: { [weak self] in
            guard let self, let handle = self.maintenanceHandle else {
                return
            }
            self.operationGate.complete(handle)
            self.maintenanceHandle = nil
        },
        perform: { [weak self] cursor in
            guard let self, let store = self.maintenanceStore else {
                return SessionMaintenanceResult()
            }
            return try store.performIdleMaintenance(
                at: Date(),
                policy: self.maintenancePolicy,
                cursor: cursor,
                shouldContinue: { !Task.isCancelled }
            )
        },
        onComplete: { [weak self] summary in
            self?.historyWindow?.showMessage(summary.sanitizedMessage)
            if self?.historyWindow != nil {
                self?.refreshHistory()
            }
            self?.updateSurface()
        }
    )
    private var finishRequestedAfterStart = false
    private var shortcutFeedbackDetail: String?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var shortcutRegistered = false

    init(
        storageBootstrapper: any DurableSessionBootstrapping = DurableSessionBootstrapper()
    ) {
        storageCapability = DurableSessionCapability(bootstrapper: storageBootstrapper)
        super.init()
        storageCapability.onChange = { [weak self] in
            self?.storageCapabilityDidChange()
        }
        playback.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                self?.handlePlaybackState(state)
            }
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
        loadDictionary()
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
        operationGate.cancelCurrent()
        let needsBoundedQuit = coordinator.hasActiveWork
            || operationGate.currentHandle != nil
            || operationGate.fencedLoserCount > 0
            || storageWasChecking
        if needsBoundedQuit {
            Task { @MainActor [weak self] in
                guard let self else {
                    NSApp.reply(toApplicationShouldTerminate: true)
                    return
                }
                _ = await self.operationGate.finishShutdown(
                    timeout: AppOperationTimeoutPolicy.production.quit
                ) {
                    await self.finishApplicationTermination()
                    await self.storageCapability.waitForCurrentAttempt()
                }
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        _ = operationGate.enterShutdown()
        coordinator.shutdown()
        return .terminateNow
    }

    private func finishApplicationTermination() async {
        operationGate.cancelCurrent()
        await coordinator.cancelActiveWork(reason: "application shutdown")
        if coordinator.hasActiveTranscription {
            await coordinator.shutdownWithTranscription()
        } else {
            await coordinator.shutdownAndWait()
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
        let sessionID = UUID()
        let window = SettingsWindowController(
            settings: settings,
            inputDevices: currentInputDevices(),
            supportedLocales: supportedLocales,
            microphoneState: microphonePermissionState(),
            accessibilityState: accessibilityPermissionState(),
            storageHealth: displayedStorageHealth,
            launchAtLoginStatus: launchAtLoginController.status,
            launchAtLoginStatusProvider: { [weak self] in
                self?.launchAtLoginController.status ?? .unknown
            },
            openLoginItemsSettings: { [weak self] in
                self?.launchAtLoginController.openLoginItemsSettings()
            },
            registrationStatus: { [weak self] in
                self?.shortcutRegistrar.status ?? .inactive("Global shortcut is not registered")
            },
            registrationError: { [weak self] in
                self?.shortcutConfiguration.lastError ?? self?.shortcutRegistrar.lastError
            },
            save: { [weak self] settings in
                self?.applySettings(settings) ?? "Oigo is no longer available."
            },
            checkSpeechAssets: { [weak self] identifier in
                await self?.inspectSpeechAssets(for: identifier) ?? .unavailable("Oigo is no longer available")
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
            },
            exportDiagnostics: { [weak self] in
                guard let self else {
                    throw OigoSettingsStoreError.storeUnavailable
                }
                return try self.makeDiagnosticsExport()
            },
            dictionaryDocument: dictionaryDocument,
            saveDictionary: { [weak self] document in
                self?.saveDictionaryDocument(document)
            },
            previewDictionary: { [weak self] sample in
                self?.previewDictionarySample(sample) ?? sample
            },
            addStarterTerms: { [weak self] in
                self?.addDictionaryStarterTerms()
                    ?? (DictionaryDocument.empty, "The custom dictionary could not be saved.")
            },
            isPresented: { [weak self] in
                self?.settingsSessionID == sessionID
            },
            onClose: { [weak self] in
                guard self?.settingsSessionID == sessionID else {
                    return
                }
                self?.settingsSessionID = nil
                self?.settingsWindow = nil
            }
        )
        settingsSessionID = sessionID
        settingsWindow = window
        window.setDictionaryStatus(dictionaryLoadError)
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
            selectedInputChannel: settings.selectedInputChannel,
            committedLocaleIdentifier: settings.localeIdentifier,
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
                await self?.inspectSpeechAssets(for: identifier) ?? .unavailable("Oigo is no longer available")
            },
            saveLanguage: { [weak self] identifier in
                guard let self else { return }
                let updatedSettings = self.settings.with(localeIdentifier: identifier)
                do {
                    try self.settingsStore.save(updatedSettings)
                    self.settings = updatedSettings
                    if NextDictationSettingsPolicy.mayReplaceOwnedTranscription(
                        isOperationActive: self.coordinator.hasActiveTranscription
                    ) {
                        self.transcription = nil
                    }
                } catch {
                    self.showSettingsPersistenceFailure(error)
                }
            },
            saveStep: { [weak self] step in
                self?.onboardingStore.save(OigoOnboardingState(step: step))
            },
            saveInputSelection: { [weak self] selection, channel in
                guard let self else { return }
                let updatedSettings = self.settings.with(
                    selectedInput: selection,
                    selectedInputChannel: channel
                )
                do {
                    try self.settingsStore.save(updatedSettings)
                    self.settings = updatedSettings
                    if NextDictationSettingsPolicy.mayReplaceOwnedCapture(
                        isOperationActive: self.coordinator.hasActiveWork
                    ) {
                        self.recorder.setInputSelection(selection, channel: channel)
                    }
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
            startSourceProbe: { [weak self] selection, channel, generation in
                self?.startOnboardingSourceProbe(
                    selection: selection,
                    channel: channel,
                    generation: generation
                )
            },
            stopSourceProbe: { [weak self] in
                self?.stopOnboardingSourceProbe()
            },
            startTest: { [weak self] generation in
                self?.onboardingWindow?.focusTestField()
                self?.beginOnboardingProductionTest(generation: generation)
                _ = self?.shortcutBridge.receive(.pressed)
            },
            stopTest: { [weak self] in
                _ = self?.shortcutBridge.receive(.released)
            },
            cancelTest: { [weak self] in
                self?.clearOnboardingTestBinding()
                self?.shortcutBridge.reset()
                self?.cancelTestDictation()
            },
            openHistory: { [weak self] in
                self?.openHistory()
            },
            onComplete: { [weak self] in
                guard let self else { return }
                self.stopOnboardingSourceProbe()
                self.shortcutBridge.reset()
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
                self?.stopOnboardingSourceProbe()
                self?.shortcutBridge.reset()
                self?.onboardingWindow = nil
            }
        )
        onboardingWindow = window
        window.showAndFocus()
    }

    @objc private func openHistory() {
        if historyWindow == nil {
            historyWindow = HistoryWindowController(
                loadTranscript: { [weak self] entry, source, completion in
                    self?.loadTranscript(for: entry, source: source, completion: completion)
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
                reapplyDictionary: { [weak self] entry in
                    self?.reapplyDictionary(for: entry)
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
                },
                loadMore: { [weak self] in
                    self?.loadMoreHistory()
                },
                onClose: { [weak self] in
                    self?.closeHistoryWindow()
                }
            )
        }
        refreshHistory()
        historyWindow?.showAndFocus()
    }

    private func closeHistoryWindow() {
        playback.stop()
        _ = historyLoadGeneration.next()
        historyCursor = nil
        historyHasMore = false
        historyWindow = nil
        maintenanceCoordinator.resumeIfNeeded()
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
        guard operationGate.isAcceptingCommands else {
            return
        }
        let handle = operationGate.preempt(.interruption)
        operationGate.run(handle, completes: true) { @MainActor [weak self] in
            guard let self else {
                return
            }
            await self.coordinator.cancelActiveWork(reason: reason)
            guard self.operationGate.isCurrent(handle) else {
                return
            }
            self.lastSession = self.coordinator.currentSession ?? self.lastSession
            self.recordingStartedAt = nil
            self.clearTargetSnapshot()
            self.livePreview = ""
            self.insertionDisplayStatus = nil
            self.shortcutBridge.reset()
            self.updateSurface()
        }
    }

    private func handleMouseToggle(allowBeforeSetup: Bool = false) {
        performanceInstrumentation.mark(.shortcutReceived)
        guard allowBeforeSetup || onboardingStore.load().isComplete else {
            showOnboarding(OigoSystemSupportEvaluator.current())
            return
        }
        guard storageCapability.health.isReady else {
            reportOnboardingTestFailure()
            updateSurface()
            return
        }

        switch coordinator.state {
        case .idle, .complete, .failed, .cancelled, .interrupted:
            startDictation(kind: allowBeforeSetup ? .onboardingTest : .dictation)
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
        let onboardingAllowsTest = onboardingWindow?.isDrivingProductionTest == true
        guard onboardingStore.load().isComplete || onboardingAllowsTest else {
            shortcutBridge.reset()
            return
        }
        startDictation(kind: onboardingAllowsTest ? .onboardingTest : .dictation)
    }

    private func requestKeyboardStop() {
        if operationGate.currentKind?.isDictationLifecycle == true,
           coordinator.state != .recording {
            finishRequestedAfterStart = true
            return
        }
        finishDictation()
    }

    private func startDictation(kind: AppOperationKind = .dictation) {
        maintenanceCoordinator.preempt()
        guard storageCapability.health.isReady else {
            reportOnboardingTestFailure()
            updateSurface()
            return
        }
        let availability = commandAvailability
        guard kind == .onboardingTest ? availability.canRunOnboardingTest : availability.canStartDictation else {
            if let reason = availability.busyReason {
                showBusy(reason)
            } else {
                showShortcutFeedback(.ignoredBusy(coordinator.state))
            }
            shortcutBridge.reset()
            return
        }
        switch operationGate.beginAndRun(kind, completes: false, operation: { @MainActor [weak self] in
            guard let self else {
                return
            }
            await self.performStartDictation()
            guard let handle = self.operationGate.currentHandle,
                  self.operationGate.isCurrent(handle) else {
                return
            }
            if self.coordinator.state == .recording {
                _ = self.shortcutBridge.observeState()
                if self.finishRequestedAfterStart {
                    self.finishRequestedAfterStart = false
                    await self.performFinishDictation()
                    if self.operationGate.isCurrent(handle) {
                        self.operationGate.complete(handle)
                    }
                }
            } else {
                self.shortcutBridge.reset()
                self.operationGate.complete(handle)
            }
        }) {
        case .failure(let reason):
            shortcutBridge.reset()
            showBusy(reason)
        case .success:
            updateSurface()
        }
    }

    private func finishDictation() {
        let availability = commandAvailability
        guard availability.canStopDictation else {
            if coordinator.state != .recording,
               operationGate.currentKind?.isDictationLifecycle == true {
                finishRequestedAfterStart = true
                return
            }
            if let reason = availability.busyReason {
                showBusy(reason)
            } else {
                showShortcutFeedback(.ignoredBusy(coordinator.state))
            }
            shortcutBridge.reset()
            return
        }
        continueDictationStop()
    }

    private func continueDictationStop() {
        if coordinator.state != .recording,
           operationGate.currentKind?.isDictationLifecycle == true {
            finishRequestedAfterStart = true
            updateSurface()
            return
        }
        guard coordinator.state == .recording,
              let handle = operationGate.currentHandle,
              handle.kind.isDictationLifecycle else {
            shortcutBridge.reset()
            updateSurface()
            return
        }
        operationGate.run(handle, completes: true) { @MainActor [weak self] in
            await self?.performFinishDictation()
        }
        updateSurface()
    }

    private func cancelTestDictation() {
        let handle = operationGate.currentHandle
        operationGate.cancelCurrent()
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.coordinator.hasActiveTranscription else {
                if let handle, self.operationGate.isCurrent(handle) {
                    self.operationGate.complete(handle)
                }
                self.recordingStartedAt = nil
                self.clearTargetSnapshot()
                self.statusSurface.hide()
                self.updateSurface()
                return
            }
            _ = try? await self.coordinator.cancelRecordingWithTranscription()
            if let handle, self.operationGate.isCurrent(handle) {
                self.operationGate.complete(handle)
            }
            self.recordingStartedAt = nil
            self.clearTargetSnapshot()
            self.insertionDisplayStatus = nil
            self.statusSurface.hide()
            self.updateSurface()
        }
    }

    private func performStartDictation() async {
        do {
            switch coordinator.state {
            case .idle, .complete, .failed, .cancelled, .interrupted:
                insertionDisplayStatus = nil
                failureDetail = nil
                lastFailureCode = nil
                shortcutFeedbackDetail = nil
                let microphoneStateBeforeRequest = microphonePermissionState()
                targetSnapshot = try await insertion.captureTargetBeforeMicrophonePermission {
                    try await self.ensureMicrophonePermission()
                }
                try Task.checkCancellation()
                guard microphoneStateBeforeRequest == .granted else {
                    clearTargetSnapshot()
                    shortcutBridge.reset()
                    failureDetail = "microphone_permission_retry_required"
                    lastFailureCode = "microphone_permission_retry_required"
                    shortcutFeedbackDetail = "Microphone permission granted. Press the shortcut again to start dictation."
                    historyWindow?.showMessage(shortcutFeedbackDetail ?? "Press the shortcut again to start dictation.")
                    reportOnboardingTestFailure()
                    updateSurface()
                    return
                }
                lastSession = try await DurableSessionDictationBoundary.withPersistedSession(
                    using: storageCapability
                ) { [self] persistedSession, store in
                    pendingSessionBoundary = persistedSession
                    lastSession = persistedSession
                    bindOnboardingTestSession(persistedSession.id)
                    recorder.setInputSelection(
                        settings.selectedInput,
                        channel: settings.selectedInputChannel
                    )
                    let format = try recorder.captureFormat()
                    try Task.checkCancellation()
                    let service = transcriptionService()
                    self.applyRecognitionContext(to: service, localeIdentifier: service.configuredLocaleIdentifier)
                    let snapshot = self.makeConfigurationSnapshot(
                        format: format,
                        localeIdentifier: service.configuredLocaleIdentifier
                    )
                    recordingStartedAt = Date()
                    previewThrottle = OigoHUDPreviewThrottle()
                    return try await coordinator.startPersistedRecordingWithTranscription(
                        persistedSession,
                        using: recorder,
                        store: store,
                        transcription: service,
                        format: format,
                        configuration: snapshot,
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
                let configuration = frozenConfiguration()
                let terminalMode = transcriptCleanupMode(for: configuration.processingMode)
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
                    requiresCleanup: configuration.requiresCleanup
                )
                if terminalMode == .clean {
                    insertionDisplayStatus = .cleaning
                }
                updateSurface()
                let decision = try await resolveCleanup(
                    for: insertionSession,
                    store: store,
                    mode: terminalMode,
                    deadlineNanoseconds: configuration.cleanupDeadlineNanoseconds
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
                reportOnboardingTest(
                    session: lastSession,
                    store: store,
                    result: result,
                    insertionSource: decision.insertionSource
                )
                if let fallbackReason = decision.fallbackReason {
                    historyWindow?.showMessage(
                        Self.cleanFallbackMessage(result: result, reason: fallbackReason.description)
                    )
                }
                insertionDisplayStatus = Self.displayStatus(for: result.outcome)
                clearTargetSnapshot()
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
            scheduleIdleMaintenance(.sessionTerminal)
            updateSurface()
        } catch is CancellationError {
            await coordinator.cancelActiveWork()
            settlePendingSessionBoundary(
                reason: "dictation operation cancelled",
                cancelled: true
            )
            lastSession = coordinator.currentSession ?? lastSession
            recordingStartedAt = nil
            clearTargetSnapshot()
            livePreview = ""
            applyTerminalDisplay(cancelled: true)
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
            clearTargetSnapshot()
            recordingStartedAt = nil
            applyTerminalDisplay(error: error, cancelled: false)
            if let session = coordinator.currentSession,
               [.failed, .interrupted].contains(session.metadata.state) {
                lastSession = session
            }
            reportOnboardingTestFailure()
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
            let configuration = frozenConfiguration()
            let terminalMode = transcriptCleanupMode(for: configuration.processingMode)
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
                requiresCleanup: configuration.requiresCleanup
            )
            if terminalMode == .clean {
                insertionDisplayStatus = .cleaning
            }
            updateSurface()
            let decision = try await resolveCleanup(
                for: insertionSession,
                store: store,
                mode: terminalMode,
                deadlineNanoseconds: configuration.cleanupDeadlineNanoseconds
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
            reportOnboardingTest(
                session: lastSession,
                store: store,
                result: result,
                insertionSource: decision.insertionSource
            )
            if let fallbackReason = decision.fallbackReason {
                historyWindow?.showMessage(
                    Self.cleanFallbackMessage(result: result, reason: fallbackReason.description)
                )
            }
            insertionDisplayStatus = Self.displayStatus(for: result.outcome)
            clearTargetSnapshot()
            livePreview = ""
            if historyWindow != nil {
                refreshHistory()
            }
            scheduleIdleMaintenance(.sessionTerminal)
            updateSurface()
        } catch is CancellationError {
            await coordinator.cancelActiveWork()
            shortcutBridge.reset()
            lastSession = coordinator.currentSession ?? lastSession
            recordingStartedAt = nil
            clearTargetSnapshot()
            livePreview = ""
            applyTerminalDisplay(cancelled: true)
            updateSurface()
        } catch {
            let failureReason = Self.failureReason(for: error)
            if coordinator.hasActiveWork {
                await coordinator.cancelActiveWork(reason: failureReason)
            }
            markStorageUnhealthyIfNeeded(error)
            shortcutBridge.reset()
            lastSession = coordinator.currentSession ?? lastSession
            clearTargetSnapshot()
            recordingStartedAt = nil
            applyTerminalDisplay(error: error, cancelled: false)
            if let session = coordinator.currentSession,
               [.failed, .interrupted].contains(session.metadata.state) {
                lastSession = session
            }
            reportOnboardingTestFailure()
            NSLog("Oigo rejected the dictation finish command: %@", failureReason)
            updateSurface()
        }
    }

    private func showBusy(_ reason: AppOperationBusyReason) {
        shortcutFeedbackDetail = reason.userMessage
        historyWindow?.showMessage(reason.userMessage)
        updateSurface()
    }

    private var commandAvailability: AppCommandAvailability {
        operationGate.availability(
            coordinatorState: coordinator.state,
            setupComplete: onboardingStore.load().isComplete,
            storageReady: storageCapability.health.isReady
        )
    }

    private func frozenConfiguration() -> DictationConfigurationSnapshot {
        coordinator.activeConfiguration
            ?? lastSession?.metadata.configurationSnapshot
            ?? makeConfigurationSnapshot(
                format: AudioCaptureFormat(sampleRate: 16_000, channelCount: 1),
                localeIdentifier: transcription?.configuredLocaleIdentifier ?? settings.localeIdentifier
            )
    }

    private func makeConfigurationSnapshot(
        format: AudioCaptureFormat,
        localeIdentifier: String
    ) -> DictationConfigurationSnapshot {
        let resolvedUID = try? OigoInputDeviceCatalog.resolve(
            settings.selectedInput,
            from: currentInputDevices()
        ).uid
        let resolvedLocale = localeIdentifier.isEmpty
            ? Locale.current.identifier
            : localeIdentifier
        return DictationConfigurationSnapshot.resolve(
            settings: settings,
            resolvedLocaleIdentifier: resolvedLocale,
            resolvedDeviceUID: resolvedUID,
            format: format,
            dictionaryRevision: compiledDictionary(for: resolvedLocale).revision
        )
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
            if let busy = commandAvailability.busyReason {
                showBusy(busy)
                return
            }
            guard let displayState else { return }
            insertionDisplayStatus = displayState
            shortcutFeedbackDetail = "Shortcut ignored while \(state.rawValue.capitalized) is running"
            updateSurface()
        case .ignoredRecordingNotOwned:
            statusItem?.button?.toolTip = "Shortcut ignored: recording was started from the menu"
        case .ignoredBusy(_):
            if let busy = commandAvailability.busyReason {
                showBusy(busy)
            } else {
                statusItem?.button?.toolTip = "Oigo is busy. Try again in a moment."
                shortcutFeedbackDetail = "Oigo is busy. Try again in a moment."
                updateSurface()
            }
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
        guard commandAvailability.canRetry else {
            if let reason = commandAvailability.busyReason {
                showBusy(reason)
            }
            return
        }
        switch operationGate.beginAndRun(.retry, completes: true, operation: { @MainActor [weak self] in
            await self?.performRetry(for: session)
        }) {
        case .failure(let reason):
            showBusy(reason)
        case .success:
            break
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
            let currentSnapshot = makeConfigurationSnapshot(
                format: AudioCaptureFormat(sampleRate: 16_000, channelCount: 1),
                localeIdentifier: transcription?.configuredLocaleIdentifier ?? settings.localeIdentifier
            )
            let resolved = DictationRetryConfiguration.resolve(
                session: session.metadata,
                explicitOverride: nil,
                currentSettingsSnapshot: currentSnapshot
            )
            let service = transcriptionService(for: resolved.snapshot.resolvedLocaleIdentifier)
            applyRecognitionContext(to: service, localeIdentifier: resolved.snapshot.resolvedLocaleIdentifier)
            lastSession = try await coordinator.retryRecordingWithTranscription(
                for: session,
                using: service,
                store: store,
                configurationOverride: resolved.overrideRecorded ? resolved.snapshot : nil
            )
            guard operationGate.currentKind == .retry else {
                return
            }
            historyWindow?.showMessage("Transcription retry completed.")
        } catch {
            guard operationGate.currentKind == .retry else {
                return
            }
            markStorageUnhealthyIfNeeded(error)
            lastSession = try? store.load(id: session.id)
            historyWindow?.showMessage(Self.friendlyError("Retry failed", error))
        }
        refreshHistory()
        scheduleIdleMaintenance(.sessionTerminal)
        updateSurface()
    }

    private func loadTranscript(
        for entry: SessionHistoryEntry,
        source: SessionTextSource,
        completion: @escaping @Sendable (Result<String, Error>) -> Void
    ) {
        guard storageCapability.health.isReady,
              let store = sessionStore else {
            completion(.failure(SessionStoreError.missingSession(entry.id)))
            return
        }
        if source == .processed, !FileManager.default.fileExists(atPath: entry.session.cleanTextURL.path) {
            completion(.failure(SessionStoreError.missingSession(entry.id)))
            return
        }
        if source == .normalized, !FileManager.default.fileExists(atPath: entry.session.normalizedTextURL.path) {
            completion(.failure(SessionStoreError.missingSession(entry.id)))
            return
        }
        Task.detached {
            let result: Result<String, Error>
            do {
                let transcript = switch source {
                case .raw:
                    try store.readRawText(for: entry.session)
                case .normalized:
                    try store.readNormalizedText(for: entry.session)
                case .processed:
                    try store.readCleanText(for: entry.session)
                }
                result = .success(transcript)
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                completion(result)
            }
        }
    }

    private func resolveCleanup(
        for session: DictationSession,
        store: SessionStore,
        mode: TranscriptCleanupMode,
        deadlineNanoseconds: UInt64 = DictationConfigurationSnapshot.defaultCleanupDeadlineNanoseconds
    ) async throws -> TranscriptCleanupDecision {
        if mode == .clean {
            performanceInstrumentation.mark(.cleanupStart)
        }
        defer {
            if mode == .clean {
                performanceInstrumentation.mark(.cleanupEnd)
            }
        }
        let locale = frozenConfiguration().resolvedLocaleIdentifier
        let snapshot = compiledDictionary(for: locale)
        let result = try await DictionaryTranscriptFinalizer.resolve(
            mode: mode,
            session: session,
            store: store,
            snapshot: snapshot,
            cleanup: transcriptCleanup,
            deadlineNanoseconds: deadlineNanoseconds
        )
        lastSession = result.session
        if result.decision.fallbackReason != nil {
            transcriptCleanupMetrics.record(.fallback)
        }
        return result.decision
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
              let store = sessionStore else {
            return
        }
        guard commandAvailability.canCleanAgain else {
            if let reason = commandAvailability.busyReason {
                showBusy(reason)
            }
            return
        }
        historyWindow?.setCleanAgainEnabled(false)
        historyWindow?.showMessage("Cleaning the saved raw transcript…")
        switch operationGate.beginAndRun(.cleanAgain, completes: true, operation: { @MainActor [weak self] in
            defer {
                self?.historyWindow?.setCleanAgainEnabled(self?.commandAvailability.canCleanAgain == true)
            }
            await self?.performCleanAgain(for: entry, store: store)
        }) {
        case .failure(let reason):
            historyWindow?.setCleanAgainEnabled(true)
            showBusy(reason)
        case .success:
            break
        }
    }

    private func performCleanAgain(
        for entry: SessionHistoryEntry,
        store: SessionStore
    ) async {
        var current = entry.session
        do {
            guard storageCapability.health.isReady else {
                return
            }
            let locale = current.metadata.configurationSnapshot?.resolvedLocaleIdentifier
                ?? settings.localeIdentifier
            let finalized = try await DictionaryTranscriptFinalizer.resolve(
                mode: .clean,
                session: current,
                store: store,
                snapshot: compiledDictionary(for: locale),
                cleanup: transcriptCleanup,
                deadlineNanoseconds: 4_000_000_000
            )
            current = finalized.session
            let decision = finalized.decision
            try Task.checkCancellation()
            guard storageCapability.health.isReady else {
                return
            }
            if decision.cleanText == nil {
                let fallbackReason = decision.fallbackReason?.description
                    ?? "cleanup did not complete"
                try Task.checkCancellation()
                _ = try store.update(
                    current,
                    state: current.metadata.state,
                    cleanupFallbackReason: fallbackReason
                )
                historyWindow?.showMessage(
                    "Clean Again used no output. Normalized transcript remains available: "
                        + fallbackReason
                )
                refreshHistory()
                return
            }
            try Task.checkCancellation()
            historyWindow?.showMessage("Clean transcript saved. Raw transcript was unchanged.")
            refreshHistory()
        } catch let error as SessionStoreError where {
            if case .rawTextChanged = error { return true }
            if case .normalizedTextChanged = error { return true }
            return false
        }() {
            guard !Task.isCancelled else {
                return
            }
            let fallbackReason = "raw or normalized transcript changed while Clean Again was running"
            do {
                _ = try store.update(
                    current,
                    state: current.metadata.state,
                    insertionTextSource: current.metadata.insertionTextSource,
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

    private func reapplyDictionary(for entry: SessionHistoryEntry) {
        guard storageCapability.health.isReady,
              let store = sessionStore else {
            return
        }
        guard commandAvailability.canReapplyDictionary else {
            if let reason = commandAvailability.busyReason {
                showBusy(reason)
            }
            return
        }
        historyWindow?.showMessage("Reapplying the dictionary to the preserved raw transcript…")
        switch operationGate.beginAndRun(.reapplyDictionary, completes: true, operation: { @MainActor [weak self] in
            await self?.performReapplyDictionary(for: entry, store: store)
        }) {
        case .failure(let reason):
            showBusy(reason)
        case .success:
            break
        }
    }

    private func performReapplyDictionary(
        for entry: SessionHistoryEntry,
        store: SessionStore
    ) async {
        do {
            let locale = entry.session.metadata.configurationSnapshot?.resolvedLocaleIdentifier
                ?? settings.localeIdentifier
            let snapshot = compiledDictionary(for: locale)
            let result = try await DictionaryTranscriptFinalizer.reapply(
                session: entry.session,
                store: store,
                snapshot: snapshot,
                cleanup: transcriptCleanup,
                deadlineNanoseconds: DictationConfigurationSnapshot.defaultCleanupDeadlineNanoseconds
            )
            try Task.checkCancellation()
            if lastSession?.id == result.session.id {
                lastSession = result.session
            }
            if result.decision.insertionSource == .clean {
                historyWindow?.showMessage("Dictionary reapplied. Normalized and clean transcripts were updated from raw.txt.")
            } else if result.decision.fallbackReason != nil {
                historyWindow?.showMessage(
                    "Dictionary reapplied. Normalized transcript was updated and stale clean output was removed."
                )
            } else {
                historyWindow?.showMessage("Dictionary reapplied. Normalized transcript was updated from raw.txt.")
            }
            refreshHistory()
        } catch is CancellationError {
            return
        } catch {
            markStorageUnhealthyIfNeeded(error)
            historyWindow?.showMessage(Self.friendlyError("Reapply Dictionary failed", error))
        }
        updateSurface()
    }

    private func pasteCleanAgain(for entry: SessionHistoryEntry) {
        beginPasteAgain(for: entry, source: .clean)
    }

    private func pasteAgain(for entry: SessionHistoryEntry) {
        beginPasteAgain(for: entry, source: .raw)
    }

    private func beginPasteAgain(
        for entry: SessionHistoryEntry,
        source: TranscriptInsertionSource
    ) {
        guard storageCapability.health.isReady,
              let store = sessionStore else {
            return
        }
        guard commandAvailability.canPasteAgain else {
            if let reason = commandAvailability.busyReason {
                showBusy(reason)
            } else {
                historyWindow?.showMessage(
                    "Paste Again is unavailable while dictation or another insertion is active."
                )
            }
            return
        }
        historyWindow?.window?.orderOut(nil)
        NSApp.hide(nil)
        switch operationGate.beginAndRun(.pasteAgain, completes: true, operation: { @MainActor [weak self] in
            guard let self else {
                return
            }
            defer {
                self.updateSurface()
            }
            guard self.storageCapability.health.isReady else {
                self.historyWindow?.showMessage(self.storageCapability.health.statusMessage)
                self.historyWindow?.showAndFocus()
                if source == .clean {
                    self.historyWindow?.showCleanTranscript()
                }
                return
            }
            _ = await self.pasteAgainFlow.run(
                capture: {
                    self.insertion.captureTarget()
                },
                paste: { target in
                    self.insertion.pasteAgain(
                        for: entry.session,
                        source: source,
                        store: store,
                        target: target
                    )
                },
                copyOnly: { selection in
                    let reasonCode: InsertionReasonCode = switch selection {
                    case .timedOut:
                        .targetHandoffTimedOut
                    case .cancelled:
                        .targetHandoffCancelled
                    case .ready:
                        .targetHandoffCancelled
                    }
                    return self.insertion.copyText(
                        for: entry.session,
                        source: source,
                        store: store,
                        reasonCode: reasonCode
                    )
                },
                recordOutcome: { result in
                    guard self.operationGate.currentKind == .pasteAgain else {
                        return
                    }
                    do {
                        let updated = try store.update(
                            entry.session,
                            state: entry.session.metadata.state,
                            at: Date(),
                            insertionOutcome: result.outcome,
                            insertionFailureReason: result.reason,
                            insertionTextSource: source
                        )
                        self.lastSession = updated
                        self.insertionDisplayStatus = Self.displayStatus(for: result.outcome)
                        self.historyWindow?.showMessage(
                            Self.pasteAgainMessage(source: source, result: result)
                        )
                        self.refreshHistory()
                    } catch {
                        self.markStorageUnhealthyIfNeeded(error)
                        self.historyWindow?.showMessage(
                            Self.friendlyError("Paste Again failed", error)
                        )
                    }
                    self.historyWindow?.showAndFocus()
                    if source == .clean {
                        self.historyWindow?.showCleanTranscript()
                    }
                },
                discard: { target in
                    self.insertion.discardTarget(target)
                }
            )
        }) {
        case .failure(let reason):
            showBusy(reason)
        case .success:
            break
        }
    }

    private func playRecording(for entry: SessionHistoryEntry) {
        if playback.isPlaying(sessionID: entry.id) {
            playback.stop()
            historyWindow?.showMessage("Playback stopped.")
            return
        }
        do {
            _ = try playback.play(url: entry.session.audioURL, sessionID: entry.id)
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
        if playback.isPlaying(sessionID: entry.id) {
            playback.stop()
        }
        do {
            try store.remove(id: entry.id)
            if lastSession?.id == entry.id {
                lastSession = nil
            }
            historyWindow?.showMessage("Session deleted.")
            refreshHistory()
            scheduleIdleMaintenance(.sessionTerminal)
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
        let generation = historyLoadGeneration.next()
        historyCursor = nil
        historyHasMore = false
        historyWindow?.setLoading(true)
        let historyIsOpen = historyWindow?.window?.isVisible == true
        Task.detached { [weak self] in
            do {
                let latest = try store.listHistoryReport(
                    limit: 1,
                    maxDirectoriesToInspect: 64
                )
                let page: SessionHistoryEnumeration
                if historyIsOpen {
                    page = try store.listHistoryReport(
                        limit: 50,
                        maxDirectoriesToInspect: 256
                    )
                } else {
                    page = latest
                }
                await MainActor.run {
                    guard let self, self.historyLoadGeneration.isCurrent(generation) else {
                        return
                    }
                    self.reportedMalformedSessionCount = page.malformedSessionCount
                    self.lastSession = latest.entries.first?.session
                    self.historyCursor = page.cursor
                    self.historyHasMore = page.hasMore
                    self.historyWindow?.reload(
                        entries: page.entries,
                        hasMore: page.hasMore,
                        isLoading: false
                    )
                    self.settingsWindow?.setStorageHealth(self.displayedStorageHealth)
                    self.onboardingWindow?.setStorageHealth(self.displayedStorageHealth)
                    self.updateSurface()
                }
            } catch {
                await MainActor.run {
                    guard let self, self.historyLoadGeneration.isCurrent(generation) else {
                        return
                    }
                    self.historyWindow?.setLoading(false)
                    self.markStorageUnhealthyIfNeeded(error)
                    self.historyWindow?.showMessage(
                        self.storageCapability.health.failureCategory == nil
                            ? Self.friendlyError("History unavailable", error)
                            : self.storageCapability.health.statusMessage
                    )
                    self.updateSurface()
                }
            }
        }
    }

    private func loadMoreHistory() {
        guard storageCapability.health.isReady,
              let store = sessionStore,
              historyHasMore,
              let cursor = historyCursor else {
            return
        }
        let generation = historyLoadGeneration.value
        historyWindow?.setLoading(true)
        Task.detached { [weak self] in
            do {
                let page = try store.listHistoryReport(
                    limit: 50,
                    cursor: cursor,
                    maxDirectoriesToInspect: 256
                )
                await MainActor.run {
                    guard let self, self.historyLoadGeneration.isCurrent(generation) else {
                        return
                    }
                    self.historyCursor = page.cursor
                    self.historyHasMore = page.hasMore
                    self.historyWindow?.append(
                        entries: page.entries,
                        hasMore: page.hasMore,
                        isLoading: false
                    )
                }
            } catch {
                await MainActor.run {
                    guard let self, self.historyLoadGeneration.isCurrent(generation) else {
                        return
                    }
                    self.historyWindow?.setLoading(false)
                    self.historyWindow?.showMessage(
                        Self.friendlyError("History unavailable", error)
                    )
                }
            }
        }
    }

    private func runIdleMaintenance() {
        let canRunMaintenance = commandAvailability.canRunMaintenance
            && !coordinator.hasActiveTranscription
        guard canRunMaintenance else {
            if let reason = commandAvailability.busyReason {
                showBusy(reason)
            } else {
                historyWindow?.showMessage("Idle maintenance is unavailable while dictation is active.")
            }
            updateSurface()
            return
        }
        scheduleIdleMaintenance(.explicit)
        updateSurface()
    }

    private func scheduleIdleMaintenance(_ trigger: SessionMaintenanceTrigger) {
        guard storageCapability.health.isReady, sessionStore != nil else {
            return
        }
        maintenanceStore = sessionStore
        let lifetime = settings.keepSuccessfulAudioIndefinitely
            ? Double.greatestFiniteMagnitude
            : settings.audioRetention.duration
        maintenancePolicy = SessionRetentionPolicy(successfulAudioLifetime: lifetime)
        maintenanceCoordinator.request(trigger)
    }

    private func applyTranscriptionUpdate(_ update: TranscriptionUpdate) {
        if update.liveDegradation != nil {
            livePreview = ""
            updateSurface()
            return
        }
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
        let availability = commandAvailability
        let canToggle = availability.canStartDictation || availability.canStopDictation
        toggleItem?.title = storageReady
            ? (isRecording || availability.canStopDictation ? "Stop Dictation" : "Start Dictation")
            : "Storage unavailable"
        toggleItem?.action = storageReady ? #selector(toggleDictation) : #selector(retryStorageAction)
        toggleItem?.isEnabled = setupComplete && (storageReady ? canToggle : true)
        instantModeItem?.state = settings.defaultMode == .instant ? .on : .off
        cleanModeItem?.state = settings.defaultMode == .clean ? .on : .off
        modeMenuItem?.isEnabled = setupComplete && storageReady && operationGate.isAcceptingCommands
        instantModeItem?.toolTip = availability.settingsApplyToNextDictation
            ? NextDictationSettingsPolicy.nextDictationCopy
            : nil
        cleanModeItem?.toolTip = availability.settingsApplyToNextDictation
            ? NextDictationSettingsPolicy.nextDictationCopy
            : nil
        settingsWindow?.setAppliesToNextDictation(availability.settingsApplyToNextDictation)
        historyWindow?.setCommandAvailability(availability)
        onboardingWindow?.setCommandAvailability(availability)
        storageStatusItem?.title = displayedStorageHealth.statusMessage
        retryStorageItem?.isEnabled = !storageReady && storageCapability.health != .checking
        let launchPresentation = OigoLaunchAtLoginPresentation(status: launchAtLoginController.status)
        launchAtLoginItem?.state = launchPresentation.menuStateOn ? .on : .off
        launchAtLoginItem?.title = launchPresentation.menuTitle
        launchAtLoginItem?.toolTip = launchPresentation.menuToolTip
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
            let previewEnabled = coordinator.activeConfiguration?.previewEnabled
                ?? settings.showVolatilePreview
            let degradedDetail = coordinator.liveRecordingHUDDetail
            statusSurface.showRecording(
                startedAt: recordingStartedAt ?? Date(),
                preview: previewEnabled && degradedDetail == nil ? livePreview : "",
                detail: degradedDetail,
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
        let status = launchAtLoginController.status
        if status == .requiresApproval {
            launchAtLoginController.openLoginItemsSettings()
            updateSurface()
            return
        }
        if status == .notFound || status == .unknown {
            showSettingsPersistenceFailure(
                title: "Launch at Login is unavailable",
                message: OigoLaunchAtLoginPresentation(status: status).detail
            )
            updateSurface()
            return
        }
        let enabled = status != .enabled
        let previousSettings = settings
        let updatedSettings = settings.with(launchAtLogin: enabled)
        do {
            let resolved = try launchAtLoginController.setEnabled(enabled)
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
            settingsWindow?.setLaunchAtLoginStatus(resolved)
            updateSurface()
        } catch {
            showSettingsPersistenceFailure(
                title: "Launch at Login could not be changed",
                message: Self.failureReason(for: error)
            )
            settingsWindow?.setLaunchAtLoginStatus(launchAtLoginController.status)
            updateSurface()
        }
    }

    @objc private func playLastRecording() {
        guard let session = lastSession else {
            return
        }
        if playback.isPlaying(sessionID: session.id) {
            playback.stop()
            return
        }
        do {
            _ = try playback.play(url: session.audioURL, sessionID: session.id)
        } catch {
            NSLog("Oigo could not play the last recording")
        }
    }

    private func handlePlaybackState(_ state: AudioPlaybackState) {
        historyWindow?.setPlaybackState(
            playingSessionID: state.sessionID,
            isPlaying: state.isPlaying
        )
        guard !state.isPlaying else {
            return
        }
        switch state.outcome {
        case .completed:
            historyWindow?.showMessage("Playback finished.")
        case .failed:
            historyWindow?.showMessage("Playback failed.")
        case .stopped, .replaced, .shutdown, nil:
            break
        }
        maintenanceCoordinator.resumeIfNeeded()
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
            if historyWindow != nil {
                refreshHistory()
            }
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
        if storageCapability.health.isReady {
            scheduleIdleMaintenance(.startup)
        }
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
             .normalizedTextChanged,
             .deletionConfirmationRequired:
            return nil
        }
    }

    private func inspectSpeechAssets(for identifier: String) async -> OigoLocaleAssetStatus {
        guard storageCapability.health.isReady else {
            return .unavailable("durable storage is unavailable")
        }
        let service = speechAssetService(for: identifier)
        do {
            return Self.localeAssetStatus(from: try await service.installSpeechAssets())
        } catch {
            return Self.localeAssetStatus(from: service.currentAssetState)
        }
    }

    private static func localeAssetStatus(from state: SpeechAssetState) -> OigoLocaleAssetStatus {
        switch state {
        case .ready:
            .ready
        case .installing:
            .installing
        case .failed(let reason):
            .failed(reason)
        case .unavailable(let reason):
            .unavailable(reason)
        }
    }

    private func speechAssetService(for identifier: String) -> TranscriptionService {
        TranscriptionService(
            locale: Locale(identifier: identifier),
            instrumentation: performanceInstrumentation
        )
    }

    private func loadDictionary() {
        if dictionaryStore == nil, let directory = try? DictionaryStore.defaultDirectory() {
            dictionaryStore = try? DictionaryStore(directoryURL: directory)
        }
        guard let dictionaryStore else {
            dictionaryDocument = .empty
            dictionaryLoadError = nil
            return
        }
        let loaded = dictionaryStore.load()
        dictionaryDocument = loaded.document
        dictionaryLoadError = loaded.error?.userMessage
    }

    private func compiledDictionary(for localeIdentifier: String) -> CompiledDictionarySnapshot {
        (try? DictionaryCompiler.compile(dictionaryDocument.entries, localeIdentifier: localeIdentifier))
            ?? .empty
    }

    private func applyRecognitionContext(to service: TranscriptionService, localeIdentifier: String) {
        service.applyRecognitionContext(compiledDictionary(for: localeIdentifier))
    }

    private func saveDictionaryDocument(_ document: DictionaryDocument) -> String? {
        do {
            try DictionaryCompiler.validate(document.entries)
            if dictionaryStore == nil, let directory = try? DictionaryStore.defaultDirectory() {
                dictionaryStore = try DictionaryStore(directoryURL: directory)
            }
            guard let dictionaryStore else {
                return "The custom dictionary could not be saved."
            }
            try dictionaryStore.save(document)
            dictionaryDocument = document
            return nil
        } catch let error as DictionaryStoreError {
            return error.userMessage
        } catch {
            return "The custom dictionary could not be saved."
        }
    }

    private func previewDictionarySample(_ sample: String) -> String {
        let locale = settings.localeIdentifier.isEmpty ? Locale.current.identifier : settings.localeIdentifier
        let snapshot = compiledDictionary(for: locale)
        return TerminologyNormalizer(snapshot: snapshot).normalize(sample)
    }

    private func addDictionaryStarterTerms() -> (DictionaryDocument, String?) {
        do {
            if dictionaryStore == nil, let directory = try? DictionaryStore.defaultDirectory() {
                dictionaryStore = try DictionaryStore(directoryURL: directory)
            }
            guard let dictionaryStore else {
                return (dictionaryDocument, "The custom dictionary could not be saved.")
            }
            let document = try dictionaryStore.addStarterTerms()
            dictionaryDocument = document
            return (document, nil)
        } catch let error as DictionaryStoreError {
            return (dictionaryDocument, error.userMessage)
        } catch {
            return (dictionaryDocument, "The custom dictionary could not be saved.")
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
        if coordinator.hasActiveTranscription, let transcription {
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
        let currentLaunchStatus = launchAtLoginController.status
        let launchAtLoginChanged = OigoLaunchAtLoginReconciliation.shouldMutate(
            requested: newSettings.launchAtLogin,
            status: currentLaunchStatus
        )

        if launchAtLoginChanged {
            do {
                try launchAtLoginController.setEnabled(newSettings.launchAtLogin)
            } catch {
                registerShortcut()
                settingsWindow?.setLaunchAtLoginStatus(launchAtLoginController.status)
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
                    settingsWindow?.setLaunchAtLoginStatus(launchAtLoginController.status)
                    updateSurface()
                    return shortcutError
                }
                do {
                    try launchAtLoginController.setEnabled(previousSettings.launchAtLogin)
                } catch {
                    settingsWindow?.setLaunchAtLoginStatus(launchAtLoginController.status)
                    updateSurface()
                    return shortcutError + "; Launch at Login could not be restored: " + Self.failureReason(for: error)
                }
                settingsWindow?.setLaunchAtLoginStatus(launchAtLoginController.status)
                updateSurface()
                return shortcutError
            }
        } else {
            do {
                try settingsStore.save(newSettings)
            } catch {
                var message = "Settings could not be saved: \(error)"
                guard launchAtLoginChanged else {
                    settingsWindow?.setLaunchAtLoginStatus(launchAtLoginController.status)
                    updateSurface()
                    return message
                }
                do {
                    try launchAtLoginController.setEnabled(previousSettings.launchAtLogin)
                } catch let restoreError {
                    message += "; Launch at Login could not be restored: \(restoreError)"
                }
                settingsWindow?.setLaunchAtLoginStatus(launchAtLoginController.status)
                updateSurface()
                return message
            }
        }

        settings = newSettings
        settingsWindow?.setLaunchAtLoginStatus(launchAtLoginController.status)
        let operationOwnsCapture = !NextDictationSettingsPolicy.mayReplaceOwnedCapture(
            isOperationActive: coordinator.hasActiveWork
                || (operationGate.currentKind?.isDictationLifecycle ?? false)
        )
        if !operationOwnsCapture {
            recorder.setInputSelection(
                settings.selectedInput,
                channel: settings.selectedInputChannel
            )
        }
        if previousSettings.localeIdentifier != settings.localeIdentifier,
           NextDictationSettingsPolicy.mayReplaceOwnedTranscription(
            isOperationActive: coordinator.hasActiveTranscription
           ) {
            transcription = nil
        }
        if !shortcutRegistrar.status.isActive {
            registerShortcut()
        }
        if previousSettings.audioRetention != settings.audioRetention
            || previousSettings.keepSuccessfulAudioIndefinitely != settings.keepSuccessfulAudioIndefinitely {
            scheduleIdleMaintenance(.settingsChanged)
        }
        updateSurface()
        return nil
    }

    private func currentInputDevices() -> [OigoInputDevice] {
        (try? deviceInventoryMonitor.currentDevices()) ?? []
    }

    private func beginOnboardingProductionTest(generation: UInt64) {
        onboardingTestGeneration = generation
        onboardingTestSessionID = nil
    }

    private func bindOnboardingTestSession(_ sessionID: UUID) {
        guard onboardingTestGeneration != nil else {
            return
        }
        if onboardingTestSessionID == nil {
            onboardingTestSessionID = sessionID
        }
        onboardingWindow?.bindTestSession(sessionID)
    }

    private func clearOnboardingTestBinding() {
        onboardingTestGeneration = nil
        onboardingTestSessionID = nil
    }

    private func sessionForOnboardingTest(_ session: DictationSession?) -> DictationSession? {
        guard let boundID = onboardingTestSessionID else {
            return nil
        }
        if let session, session.id == boundID {
            return session
        }
        if let current = coordinator.currentSession, current.id == boundID {
            return current
        }
        if let lastSession, lastSession.id == boundID {
            return lastSession
        }
        return nil
    }

    private func startOnboardingSourceProbe(
        selection: OigoInputSelection,
        channel: Int,
        generation: UInt64
    ) {
        stopOnboardingSourceProbe()
        let probe = OnboardingSourceProbe()
        onboardingSourceProbe = probe
        probe.start(
            selection: selection,
            channel: channel,
            generation: generation
        ) { [weak self] update in
            Task { @MainActor [weak self] in
                self?.onboardingWindow?.applySourceProbeUpdate(update)
            }
        }
    }

    private func stopOnboardingSourceProbe() {
        onboardingSourceProbe?.stop()
        onboardingSourceProbe = nil
    }

    private func reportOnboardingTest(
        session: DictationSession?,
        store: SessionStore,
        result: InsertionResult,
        insertionSource: TranscriptInsertionSource
    ) {
        guard let onboardingWindow,
              let generation = onboardingTestGeneration else {
            return
        }
        shortcutBridge.reset()
        let bound = recorder.currentSelection()
        let session = sessionForOnboardingTest(session)
        let selectedText: String
        if let session {
            switch insertionSource {
            case .clean:
                selectedText = (try? store.readCleanText(for: session)) ?? ""
            case .normalized:
                selectedText = (try? store.readNormalizedText(for: session)) ?? ""
            case .raw:
                selectedText = (try? store.readRawText(for: session)) ?? ""
            }
        } else {
            selectedText = ""
        }
        let cafExists = session.map { FileManager.default.fileExists(atPath: $0.audioURL.path) } ?? false
        let speechFinalized = session.map { ($0.metadata.rawTextByteCount ?? 0) > 0 } ?? false
        let report = OigoOnboardingProductionReport(
            usedInput: bound.input,
            usedChannel: bound.channel,
            sessionCreated: session != nil,
            cafInitialized: cafExists,
            speechFinalized: speechFinalized,
            transcriptNonempty: !selectedText.isEmpty,
            clipboardWritten: result.outcome.clipboardOutputAvailable,
            targetValidationSucceeded: result.outcome == .pasted || result.outcome == .dispatched,
            insertionOutcome: result.outcome,
            insertionPath: .production,
            insertionInvoked: true,
            recoverableArtifactsRetained: cafExists || speechFinalized,
            sessionID: session?.id ?? onboardingTestSessionID
        )
        onboardingWindow.applyTestCompletion(
            generation: generation,
            sessionID: onboardingTestSessionID,
            report: report,
            selectedInsertionText: selectedText
        )
        clearOnboardingTestBinding()
    }

    private func reportOnboardingTestFailure() {
        guard let onboardingWindow,
              let generation = onboardingTestGeneration else {
            return
        }
        shortcutBridge.reset()
        let bound = recorder.currentSelection()
        let session = sessionForOnboardingTest(lastSession ?? coordinator.currentSession)
        let cafExists = session.map { FileManager.default.fileExists(atPath: $0.audioURL.path) } ?? false
        let speechFinalized = session.map { ($0.metadata.rawTextByteCount ?? 0) > 0 } ?? false
        let report = OigoOnboardingProductionReport(
            usedInput: bound.input,
            usedChannel: bound.channel,
            sessionCreated: session != nil,
            cafInitialized: cafExists,
            speechFinalized: speechFinalized,
            transcriptNonempty: false,
            clipboardWritten: false,
            targetValidationSucceeded: false,
            insertionOutcome: .failed,
            insertionPath: .production,
            insertionInvoked: false,
            recoverableArtifactsRetained: cafExists || speechFinalized,
            sessionID: session?.id ?? onboardingTestSessionID
        )
        onboardingWindow.applyTestCompletion(
            generation: generation,
            sessionID: onboardingTestSessionID,
            report: report,
            selectedInsertionText: ""
        )
        clearOnboardingTestBinding()
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

    private func makeDiagnosticsExport() throws -> Data {
        let sessionCount: Int
        if let sessionStore {
            sessionCount = (try? sessionStore.listSessions().count) ?? 0
        } else {
            sessionCount = 0
        }
        let shortcutRegistration: OigoDiagnosticsShortcutRegistration
        if shortcutRegistrar.status.isActive {
            shortcutRegistration = .present
        } else {
            shortcutRegistration = .inactive
        }
        let snapshot = OigoDiagnosticsSnapshot(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1",
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.oigo.app",
            macOSVersion: OigoDiagnosticsExport.currentMacOSVersion(),
            architecture: OigoDiagnosticsExport.currentArchitecture(),
            storageHealth: displayedStorageHealth,
            dictationState: coordinator.state,
            lastFailureCode: lastFailureCode,
            settings: settings,
            shortcutRegistration: shortcutRegistration,
            shortcutDisplayName: settings.globalShortcut.displayName,
            dictionaryEntryCount: dictionaryDocument.entries.count,
            sessionCount: sessionCount,
            lastMaintenance: maintenanceCoordinator.sanitizedLastSummary
        )
        return try OigoDiagnosticsExport.make(snapshot).jsonData()
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

    private func openSystemSettings(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private func waitForDestinationHandoff() async {
        await DestinationHandoffWaiter().wait()
    }

    private func clearTargetSnapshot() {
        if let targetSnapshot {
            insertion.discardTarget(targetSnapshot)
        }
        targetSnapshot = nil
    }

    private static func pasteAgainMessage(
        source: TranscriptInsertionSource,
        result: InsertionResult
    ) -> String {
        let label = source == .clean ? "Clean transcript" : "Transcript"
        switch result.outcome {
        case .pasted:
            return label + " pasted again."
        case .dispatched:
            return label + " paste attempted. Clipboard retained."
        case .copied, .secureRejected:
            return label + " copied. " + (result.reason ?? "Paste was not sent.")
        case .failed:
            return "Paste Again failed: " + (result.reason ?? "the paste could not be completed")
        }
    }

    private static func cleanFallbackMessage(
        result: InsertionResult,
        reason: String
    ) -> String {
        let outcomeMessage: String = switch result.outcome {
        case .pasted:
            "Raw transcript inserted."
        case .dispatched:
            "Raw transcript paste attempted; clipboard retained."
        case .copied, .secureRejected:
            "Raw transcript copied."
        case .failed:
            "Raw transcript was not inserted."
        }
        return "Clean unavailable. " + outcomeMessage + " " + reason
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
        case .completedPasteFailed:
            "Dictation completed; paste failed. Open History to copy or paste again."
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
            case .rawTextChanged, .normalizedTextChanged:
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

    private func applyTerminalDisplay(error: Error? = nil, cancelled: Bool) {
        if coordinator.state == .complete,
           coordinator.currentSession?.metadata.insertionOutcome == .failed {
            insertionDisplayStatus = .completedPasteFailed
            failureDetail = DictationTerminalContract.statusCopy(
                sessionState: .completed,
                insertionOutcome: .failed
            )
            lastFailureCode = "insertion.failed"
            historyWindow?.showMessage(failureDetail ?? "Dictation completed; paste failed")
            return
        }
        if cancelled {
            if !coordinator.hasActiveWork {
                insertionDisplayStatus = nil
            }
            failureDetail = nil
            lastFailureCode = "cancelled"
            return
        }
        insertionDisplayStatus = .failed
        if let error {
            lastFailureCode = OigoDiagnosticsFailureCode.code(for: error)
            failureDetail = Self.friendlyError("Dictation failed", error)
            historyWindow?.showMessage(failureDetail ?? Self.friendlyError("Dictation failed", error))
        }
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
            .completedPasteFailed
        }
    }
}
