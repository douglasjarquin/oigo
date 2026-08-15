import AppKit
import Foundation
import OigoCore

@MainActor
final class OigoAppDelegate: NSObject, NSApplicationDelegate {
    private let coordinator = DictationCoordinator()
    private let shortcutRegistrar = CarbonGlobalShortcutRegistrar()
    private let statusSurface = StatusSurfaceController()
    private var settingsWindow: SettingsWindowController?
    private var statusItem: NSStatusItem?
    private var toggleItem: NSMenuItem?
    private var shortcut = OigoAppDelegate.loadShortcut()

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        registerShortcut()
        updateSurface()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        _ = sender
        shortcutRegistrar.unregister()
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
        do {
            try coordinator.toggle()
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
        statusItem?.button?.title = "Oigo · " + coordinator.state.rawValue.capitalized
        statusSurface.show(state: coordinator.state, anchoredTo: statusItem?.button)
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
