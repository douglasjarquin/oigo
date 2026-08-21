import AppKit
import Darwin
import Foundation

@MainActor
private final class GalleryApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let configuration: GalleryConfiguration
    private let scenario: GalleryScenario.Type
    private var window: NSWindow?
    private var terminationTimer: Timer?

    init(configuration: GalleryConfiguration, scenario: GalleryScenario.Type) {
        self.configuration = configuration
        self.scenario = scenario
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = scenario.makeWindow(configuration: configuration)
        self.window = window
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        print("HOST_READY scenario=" + configuration.scenario + " windows=1")
        fflush(stdout)
        terminationTimer = Timer.scheduledTimer(
            timeInterval: 20,
            target: self,
            selector: #selector(terminateAfterBound),
            userInfo: nil,
            repeats: false
        )
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminationTimer?.invalidate()
        terminationTimer = nil
        window = nil
    }

    @objc private func terminateAfterBound() {
        NSApp.terminate(nil)
    }
}

let configuration: GalleryConfiguration
do {
    configuration = try GalleryConfiguration.parse(
        Array(CommandLine.arguments.dropFirst()),
        environment: ProcessInfo.processInfo.environment
    )
} catch let error as GalleryInputError {
    FileHandle.standardError.write(Data(("ERROR " + error.description + "\n").utf8))
    exit(64)
} catch {
    FileHandle.standardError.write(Data("ERROR rejected-input:unknown\n".utf8))
    exit(64)
}

let scenarios = GalleryScenarioRegistry.discover()
guard let scenario = scenarios[configuration.scenario] else {
    FileHandle.standardError.write(Data("ERROR rejected-input:unknown-scenario\n".utf8))
    exit(64)
}

let application = NSApplication.shared
application.setActivationPolicy(.regular)
private let delegate = GalleryApplicationDelegate(configuration: configuration, scenario: scenario)
application.delegate = delegate
application.run()
