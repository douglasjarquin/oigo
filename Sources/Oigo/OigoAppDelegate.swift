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
    private var historyWindow: HistoryWindowController?
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
        statusSurface.hide()
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

    @objc private func openHistory() {
        if historyWindow == nil {
            historyWindow = HistoryWindowController(
                loadTranscript: { [weak self] entry in
                    self?.loadTranscript(for: entry)
                        ?? .failure(SessionStoreError.missingSession(entry.id))
                },
                copyRawTranscript: { [weak self] entry in
                    self?.copyRawTranscript(for: entry)
                },
                pasteAgain: { [weak self] entry in
                    self?.pasteAgain(for: entry)
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

        let history = NSMenuItem(
            title: "History…",
            action: #selector(openHistory),
            keyEquivalent: ""
        )
        history.target = self
        menu.addItem(history)

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
            if historyWindow != nil {
                refreshHistory()
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
            historyWindow?.showMessage(Self.friendlyError("Dictation failed", error))
            NSLog("Oigo rejected the toggle command: %@", String(describing: error))
            updateSurface()
        }
    }

    @objc private func retryLastTranscription() {
        Task { @MainActor [weak self] in
            guard let self, let session = self.lastSession else {
                return
            }
            await self.performRetry(for: session)
        }
    }

    private func retryTranscription(for entry: SessionHistoryEntry) {
        Task { @MainActor [weak self] in
            await self?.performRetry(for: entry.session)
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
                using: transcription,
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

    private func loadTranscript(for entry: SessionHistoryEntry) -> Result<String, Error> {
        guard let store = sessionStore else {
            return .failure(SessionStoreError.missingSession(entry.id))
        }
        do {
            return .success(try store.readRawText(for: entry.session))
        } catch {
            return .failure(error)
        }
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
                    insertionFailureReason: result.reason
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
            let result = try store.performIdleMaintenance()
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
            lastSession = try store.listHistory(limit: 1).first?.session
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

    private static func friendlyError(_ prefix: String, _ error: Error) -> String {
        if let transcriptionError = error as? TranscriptionError {
            return prefix + ": " + transcriptionError.description
        }
        return prefix + ": " + String(describing: error)
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
