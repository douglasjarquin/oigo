import AppKit
import AVFAudio
import Foundation
import OigoCore
import OigoCapture
import OigoTranscription
import OigoInsertion

@MainActor
final class OigoAppDelegate: NSObject, NSApplicationDelegate {
    private enum InsertionDisplayStatus: String {
        case finalizing = "Finalizing"
        case pasted = "Pasted"
        case copied = "Copied"
        case failed = "Failed"
    }

    private let coordinator = DictationCoordinator()
    private let recorder = AudioRecorder()
    private let transcription = TranscriptionService()
    private let insertion = InsertionService()
    private let playback = AudioPlayback()
    private let shortcutRegistrar = CarbonGlobalShortcutRegistrar()
    private let statusSurface = StatusSurfaceController()
    private var sessionStore: SessionStore?
    private var lastSession: DictationSession?
    private var livePreview = ""
    private var settingsWindow: SettingsWindowController?
    private var statusItem: NSStatusItem?
    private var toggleItem: NSMenuItem?
    private var playItem: NSMenuItem?
    private var revealItem: NSMenuItem?
    private var retryItem: NSMenuItem?
    private var shortcut = OigoAppDelegate.loadShortcut()
    private var targetSnapshot: InsertionTargetSnapshot?
    private var insertionDisplayStatus: InsertionDisplayStatus?
    private var toggleTaskInFlight = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
        NSApp.setActivationPolicy(.accessory)
        prepareSessionStore()
        configureStatusItem()
        registerShortcut()
        updateSurface()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        _ = sender
        shortcutRegistrar.unregister()
        playback.stop()
        if coordinator.hasActiveTranscription {
            Task { @MainActor [weak self] in
                await self?.coordinator.shutdownWithTranscription()
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
        let window = SettingsWindowController(shortcut: shortcut) { [weak self] shortcut in
            guard let self else {
                return
            }
            self.shortcut = shortcut
            Self.saveShortcut(shortcut)
            self.registerShortcut()
        }
        settingsWindow = window
        window.showWindow(nil)
        window.window?.center()
        window.window?.makeKeyAndOrderFront(nil)
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

        let play = NSMenuItem(
            title: "Play Last Recording",
            action: #selector(playLastRecording),
            keyEquivalent: ""
        )
        play.target = self
        menu.addItem(play)

        let reveal = NSMenuItem(
            title: "Reveal Last Recording",
            action: #selector(revealLastRecording),
            keyEquivalent: ""
        )
        reveal.target = self
        menu.addItem(reveal)

        let retry = NSMenuItem(
            title: "Retry Saved Transcription",
            action: #selector(retryLastTranscription),
            keyEquivalent: ""
        )
        retry.target = self
        menu.addItem(retry)

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

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
        playItem = play
        revealItem = reveal
        retryItem = retry
    }

    private func registerShortcut() {
        shortcutRegistrar.unregister()
        do {
            try shortcutRegistrar.register(shortcut: shortcut) { [weak self] in
                self?.handleToggle()
            }
        } catch {
            NSLog("Oigo could not register the global toggle shortcut: %@", String(describing: error))
        }
    }

    private func handleToggle() {
        guard !toggleTaskInFlight else {
            return
        }
        toggleTaskInFlight = true
        Task { @MainActor [weak self] in
            defer { self?.toggleTaskInFlight = false }
            await self?.performToggle()
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
                targetSnapshot = insertion.captureTarget()
                if AVAudioApplication.shared.recordPermission == .undetermined {
                    _ = await AudioRecorder.requestMicrophonePermission()
                }
                let format = try recorder.captureFormat()
                lastSession = try await coordinator.startRecordingWithTranscription(
                    using: recorder,
                    store: sessionStore,
                    transcription: transcription,
                    format: format,
                    onUpdate: { [weak self] update in
                        Task { @MainActor [weak self] in
                            self?.applyTranscriptionUpdate(update)
                        }
                    }
                )
            case .recording:
                insertionDisplayStatus = .finalizing
                updateSurface()
                _ = try await coordinator.stopRecordingWithTranscription()
                guard let snapshot = targetSnapshot,
                      let store = sessionStore else {
                    throw DictationCoordinatorError.recordingNotActive
                }
                let insertionSession = try coordinator.beginInsertion(using: store)
                updateSurface()
                let result = insertion.insertRawText(
                    for: insertionSession,
                    store: store,
                    target: snapshot
                )
                lastSession = try coordinator.finishInsertion(
                    outcome: result.outcome,
                    reason: result.reason
                )
                insertionDisplayStatus = Self.displayStatus(for: result.outcome)
                targetSnapshot = nil
                livePreview = ""
            case .preparing, .finalizing, .cleaning, .inserting:
                throw DictationTransitionError.illegal(
                    from: coordinator.state,
                    event: .start
                )
            }
            updateSurface()
        } catch {
            if coordinator.state == .inserting {
                lastSession = coordinator.failInsertion(reason: String(describing: error))
            }
            targetSnapshot = nil
            insertionDisplayStatus = .failed
            if let session = coordinator.currentSession,
               [.failed, .interrupted].contains(session.metadata.state) {
                lastSession = session
            }
            NSLog("Oigo rejected the toggle command: %@", String(describing: error))
            updateSurface()
        }
    }

    @objc private func retryLastTranscription() {
        Task { @MainActor [weak self] in
            await self?.performRetry()
        }
    }

    private func performRetry() async {
        guard let store = sessionStore,
              let session = lastSession,
              [.failed, .interrupted].contains(session.metadata.state),
              FileManager.default.fileExists(atPath: session.audioURL.path) else {
            updateSurface()
            return
        }

        do {
            livePreview = ""
            lastSession = try await coordinator.retryRecordingWithTranscription(
                for: session,
                using: transcription,
                store: store
            )
        } catch {
            NSLog("Oigo could not retry the saved transcription: %@", String(describing: error))
        }
        updateSurface()
    }

    private func applyTranscriptionUpdate(_ update: TranscriptionUpdate) {
        let text = update.isFinal
            ? (update.finalizedSegment ?? update.volatilePreview)
            : update.volatilePreview
        livePreview = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        updateSurface()
    }

    private func updateSurface() {
        let isRecording = coordinator.state == .recording
        let canToggle = [
            .idle,
            .recording,
            .complete,
            .failed,
            .cancelled,
            .interrupted
        ].contains(coordinator.state)
        toggleItem?.title = isRecording ? "Stop Dictation" : "Start Dictation"
        toggleItem?.isEnabled = canToggle
        let hasSession = lastSession != nil
        let hasPlayableRecording = lastSession.map {
            $0.metadata.state == .completed
                && FileManager.default.fileExists(atPath: $0.audioURL.path)
        } ?? false
        let canRetry = lastSession.map {
            [.failed, .interrupted].contains($0.metadata.state)
                && FileManager.default.fileExists(atPath: $0.audioURL.path)
        } ?? false
        playItem?.isEnabled = hasPlayableRecording && !isRecording
        revealItem?.isEnabled = hasSession
        retryItem?.isEnabled = canRetry && !isRecording && !coordinator.hasActiveTranscription
        let previewSuffix = livePreview.isEmpty ? "" : " · " + livePreview
        let surfaceStatus = insertionDisplayStatus?.rawValue ?? coordinator.state.rawValue.capitalized
        statusItem?.button?.title = "Oigo · " + surfaceStatus + previewSuffix
        statusSurface.show(message: surfaceStatus, anchoredTo: statusItem?.button)
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
            lastSession = try store.listSessions().first
        } catch {
            NSLog("Oigo could not prepare durable sessions: %@", String(describing: error))
        }
    }

    private static func loadShortcut() -> ToggleShortcut {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: "globalToggleShortcut"),
              let shortcut = try? JSONDecoder().decode(ToggleShortcut.self, from: data) else {
            return .default
        }
        return shortcut
    }

    private static func saveShortcut(_ shortcut: ToggleShortcut) {
        guard let data = try? JSONEncoder().encode(shortcut) else {
            return
        }
        UserDefaults.standard.set(data, forKey: "globalToggleShortcut")
    }

    private static func displayStatus(for outcome: InsertionOutcome) -> InsertionDisplayStatus {
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
