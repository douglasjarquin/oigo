import AppKit
import AVFAudio
import Foundation
import OigoCore
import OigoCapture
import OigoTranscription

@MainActor
final class OigoAppDelegate: NSObject, NSApplicationDelegate {
    private let coordinator = DictationCoordinator()
    private let recorder = AudioRecorder()
    private let transcription = TranscriptionService()
    private let playback = AudioPlayback()
    private let shortcutRegistrar = CarbonGlobalShortcutRegistrar()
    private let statusSurface = StatusSurfaceController()
    private var sessionStore: SessionStore?
    private var lastSession: DictationSession?
    private var settingsWindow: SettingsWindowController?
    private var statusItem: NSStatusItem?
    private var toggleItem: NSMenuItem?
    private var playItem: NSMenuItem?
    private var revealItem: NSMenuItem?
    private var shortcut = OigoAppDelegate.loadShortcut()

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
        Task { @MainActor [weak self] in
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
                if AVAudioApplication.shared.recordPermission == .undetermined {
                    _ = await AudioRecorder.requestMicrophonePermission()
                }
                let format = try recorder.captureFormat()
                lastSession = try await coordinator.startRecordingWithTranscription(
                    using: recorder,
                    store: sessionStore,
                    transcription: transcription,
                    format: format
                )
            case .recording:
                lastSession = try await coordinator.stopRecordingWithTranscription()
            case .preparing, .finalizing, .cleaning, .inserting:
                throw DictationTransitionError.illegal(
                    from: coordinator.state,
                    event: .start
                )
            }
            updateSurface()
        } catch {
            NSLog("Oigo rejected the toggle command: %@", String(describing: error))
            updateSurface()
        }
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
        playItem?.isEnabled = hasPlayableRecording && !isRecording
        revealItem?.isEnabled = hasSession
        statusItem?.button?.title = "Oigo · " + coordinator.state.rawValue.capitalized
        statusSurface.show(state: coordinator.state, anchoredTo: statusItem?.button)
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
}
