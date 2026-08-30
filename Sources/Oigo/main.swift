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
