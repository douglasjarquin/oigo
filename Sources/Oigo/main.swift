import AppKit
import Darwin
import OigoTranscription

if #available(macOS 26.0, *), CommandLine.arguments.contains("--oigo-transcript-cleanup-worker") {
    Task {
        Darwin.exit(await FoundationModelsTranscriptWorker.run())
    }
    dispatchMain()
}

let application = NSApplication.shared
let delegate = OigoAppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
