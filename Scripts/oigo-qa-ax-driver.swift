import AppKit
import ApplicationServices

struct Arguments {
    let app: URL
    let fieldIdentifier: String?
    let controlIdentifier: String?
    let pressControl: Bool

    static func parse(_ raw: [String]) throws -> Arguments {
        var values: [String: String] = [:]
        var pressControl = false
        var index = 0
        while index < raw.count {
            if raw[index] == "--press-control" {
                guard !pressControl else { throw InputError.malformed }
                pressControl = true
                index += 1
                continue
            }
            guard index + 1 < raw.count, raw[index].hasPrefix("--") else { throw InputError.malformed }
            let key = String(raw[index].dropFirst(2))
            guard ["app", "field-id", "control-id"].contains(key), values[key] == nil else {
                throw InputError.malformed
            }
            values[key] = raw[index + 1]
            index += 2
        }
        guard let app = values["app"], values["field-id"] != nil || values["control-id"] != nil else {
            throw InputError.malformed
        }
        return Arguments(
            app: URL(fileURLWithPath: app),
            fieldIdentifier: values["field-id"],
            controlIdentifier: values["control-id"],
            pressControl: pressControl
        )
    }
}

enum InputError: Error { case malformed }

func attribute(_ name: CFString, from element: AXUIElement) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name, &value) == .success ? value : nil
}

func element(with identifier: String, under root: AXUIElement) -> AXUIElement? {
    if let value = attribute(kAXIdentifierAttribute as CFString, from: root) as? String, value == identifier {
        return root
    }
    guard let children = attribute(kAXChildrenAttribute as CFString, from: root) as? [AXUIElement] else {
        return nil
    }
    for child in children {
        if let match = element(with: identifier, under: child) { return match }
    }
    return nil
}

do {
    let arguments = try Arguments.parse(Array(CommandLine.arguments.dropFirst()))
    guard arguments.app.pathExtension == "app",
          let bundle = Bundle(url: arguments.app),
          let bundleIdentifier = bundle.bundleIdentifier else {
        fputs("ERROR invalid-target-bundle\n", stderr)
        exit(64)
    }
    let deadline = Date().addingTimeInterval(8)
    var running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
    if running == nil {
        var launchFinished = false
        NSWorkspace.shared.openApplication(
            at: arguments.app,
            configuration: NSWorkspace.OpenConfiguration()
        ) { application, error in
            running = application
            launchFinished = true
            if error != nil { running = nil }
        }
        while !launchFinished && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }
    repeat {
        running = running ?? NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
        if running == nil { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    } while running == nil && Date() < deadline
    guard let running else {
        fputs("ERROR target-launch-timeout\n", stderr)
        exit(1)
    }
    _ = running.activate(options: [.activateAllWindows])
    print("FRONTMOST_CHECKPOINT bundle=" + bundleIdentifier)
    guard AXIsProcessTrusted() else {
        print("INCONCLUSIVE accessibility")
        exit(2)
    }
    let application = AXUIElementCreateApplication(running.processIdentifier)
    let identifier = arguments.fieldIdentifier ?? arguments.controlIdentifier ?? ""
    var match: AXUIElement?
    repeat {
        match = element(with: identifier, under: application)
        if match == nil { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    } while match == nil && Date() < deadline
    guard let match else {
        fputs(arguments.fieldIdentifier == nil ? "ERROR target-control-not-found\n" : "ERROR target-field-not-found\n", stderr)
        exit(1)
    }
    if arguments.pressControl, AXUIElementPerformAction(match, kAXPressAction as CFString) != .success {
        fputs("ERROR target-control-press-failed\n", stderr)
        exit(1)
    }
    print("AX_CHECKPOINT trusted=true identifier=" + identifier)
} catch {
    fputs("ERROR malformed-input\n", stderr)
    exit(64)
}
