import AppKit
import Darwin
import OigoCore

@MainActor
private final class UnsupportedSystemAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let support = OigoSystemSupportEvaluator.current()
        let alert = NSAlert()
        alert.messageText = "This Mac cannot run Oigo"
        alert.informativeText = support.reason + ". Oigo cannot start setup on this Mac."
        alert.addButton(withTitle: "Quit Oigo")
        alert.runModal()
        NSApp.terminate(nil)
    }
}

if ProcessInfo.processInfo.environment["OIGO_QA_MODE"] == "1" {
    setenv("CFPREFERENCES_AVOID_DAEMON", "1", 1)
}

if ProcessInfo.processInfo.environment["OIGO_QA_MODE"] == "1",
   CommandLine.arguments.count == 4,
   CommandLine.arguments[1] == "--task-08-shortcut-probe" {
    do {
        try Task8ShortcutConsumerProbe.run(
            fixtureURL: URL(fileURLWithPath: CommandLine.arguments[2]),
            outputURL: URL(fileURLWithPath: CommandLine.arguments[3])
        )
        exit(0)
    } catch {
        FileHandle.standardError.write(Data(("ERROR task-8-consumer-probe " + String(describing: error) + "\n").utf8))
        exit(1)
    }
}

if ProcessInfo.processInfo.environment["OIGO_QA_MODE"] == "1",
   CommandLine.arguments.count == 5,
   CommandLine.arguments[1] == "--task-11-onboarding-shortcut-probe" {
    guard #available(macOS 26.0, *) else {
        FileHandle.standardError.write(Data("ERROR task-11-onboarding-probe unsupported-system\n".utf8))
        exit(1)
    }
    do {
        try Task11OnboardingShortcutProbe.run(
            mode: CommandLine.arguments[2],
            defaultsSuite: CommandLine.arguments[3],
            outputURL: URL(fileURLWithPath: CommandLine.arguments[4])
        )
        exit(0)
    } catch {
        FileHandle.standardError.write(Data(("ERROR task-11-onboarding-probe " + String(describing: error) + "\n").utf8))
        exit(1)
    }
}

if ProcessInfo.processInfo.environment["OIGO_QA_MODE"] == "1",
   CommandLine.arguments.count == 5,
   CommandLine.arguments[1] == "--task-12-settings-shortcut-probe" {
    guard #available(macOS 26.0, *) else {
        FileHandle.standardError.write(Data("ERROR task-12-settings-probe unsupported-system\n".utf8))
        exit(1)
    }
    do {
        try Task12SettingsShortcutProbe.run(
            mode: CommandLine.arguments[2],
            defaultsSuite: CommandLine.arguments[3],
            outputURL: URL(fileURLWithPath: CommandLine.arguments[4])
        )
        exit(0)
    } catch {
        FileHandle.standardError.write(Data(("ERROR task-12-settings-probe " + String(describing: error) + "\n").utf8))
        exit(1)
    }
}

if ProcessInfo.processInfo.environment["OIGO_QA_MODE"] == "1",
   CommandLine.arguments.count == 5,
   CommandLine.arguments[1] == "--task-15-keyboard-startup-probe" {
    guard #available(macOS 26.0, *) else {
        FileHandle.standardError.write(Data("ERROR task-15-keyboard-startup-probe unsupported-system\n".utf8))
        exit(1)
    }
    do {
        try await Task15KeyboardStartupProbe.run(
            mode: CommandLine.arguments[2],
            defaultsSuite: CommandLine.arguments[3],
            outputURL: URL(fileURLWithPath: CommandLine.arguments[4])
        )
        exit(0)
    } catch {
        FileHandle.standardError.write(Data(("ERROR task-15-keyboard-startup-probe " + String(describing: error) + "\n").utf8))
        exit(1)
    }
}

if ProcessInfo.processInfo.environment["OIGO_QA_MODE"] == "1",
   CommandLine.arguments.count == 5,
   CommandLine.arguments[1] == "--task-16-keyboard-release-probe" {
    guard #available(macOS 26.0, *) else {
        FileHandle.standardError.write(Data("ERROR task-16-keyboard-release-probe unsupported-system\n".utf8))
        exit(1)
    }
    do {
        try await Task16KeyboardReleaseProbe.run(
            mode: CommandLine.arguments[2],
            defaultsSuite: CommandLine.arguments[3],
            outputURL: URL(fileURLWithPath: CommandLine.arguments[4])
        )
        exit(0)
    } catch {
        FileHandle.standardError.write(Data(("ERROR task-16-keyboard-release-probe " + String(describing: error) + "\n").utf8))
        exit(1)
    }
}

let application = NSApplication.shared
let delegate: NSApplicationDelegate
if #available(macOS 26.0, *) {
    delegate = OigoAppDelegate()
} else {
    delegate = UnsupportedSystemAppDelegate()
}
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
