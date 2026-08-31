import AppKit
import ApplicationServices

struct Arguments {
    let app: URL?
    let fieldIdentifier: String?
    let controlIdentifier: String?
    let pressControl: Bool
    let focus: Bool
    let readValue: Bool
    let requireFocused: Bool
    let activate: Bool
    let frontmostCheckpoint: String?

    static func parse(_ raw: [String]) throws -> Arguments {
        var values: [String: String] = [:]
        var pressControl = false
        var focus = false
        var readValue = false
        var requireFocused = false
        var activate = true
        var index = 0
        while index < raw.count {
            if ["--press-control", "--focus", "--read-value", "--require-focused", "--no-activate"].contains(raw[index]) {
                switch raw[index] {
                case "--press-control" where !pressControl: pressControl = true
                case "--focus" where !focus: focus = true
                case "--read-value" where !readValue: readValue = true
                case "--require-focused" where !requireFocused: requireFocused = true
                case "--no-activate" where activate: activate = false
                default: throw InputError.malformed
                }
                index += 1
                continue
            }
            guard index + 1 < raw.count, raw[index].hasPrefix("--") else { throw InputError.malformed }
            let key = String(raw[index].dropFirst(2))
            guard ["app", "field-id", "control-id", "frontmost-checkpoint"].contains(key),
                  values[key] == nil else {
                throw InputError.malformed
            }
            values[key] = raw[index + 1]
            index += 2
        }
        guard values["frontmost-checkpoint"] != nil || values["app"] != nil,
              values["app"] == nil || values["field-id"] != nil || values["control-id"] != nil else {
            throw InputError.malformed
        }
        return Arguments(
            app: values["app"].map(URL.init(fileURLWithPath:)),
            fieldIdentifier: values["field-id"],
            controlIdentifier: values["control-id"],
            pressControl: pressControl,
            focus: focus,
            readValue: readValue,
            requireFocused: requireFocused,
            activate: activate,
            frontmostCheckpoint: values["frontmost-checkpoint"]
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
    if arguments.app == nil {
        guard let checkpoint = arguments.frontmostCheckpoint,
              let bundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            fputs("ERROR frontmost-application-unavailable\n", stderr)
            exit(1)
        }
        print("FRONTMOST_CHECKPOINT name=" + checkpoint + " bundle=" + bundleIdentifier)
        exit(0)
    }
    guard let app = arguments.app,
          app.pathExtension == "app",
          let bundle = Bundle(url: app),
          let bundleIdentifier = bundle.bundleIdentifier else {
        fputs("ERROR invalid-target-bundle\n", stderr)
        exit(64)
    }
    guard AXIsProcessTrusted() else {
        print("INCONCLUSIVE accessibility")
        exit(2)
    }
    let deadline = Date().addingTimeInterval(8)
    var running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
    if running == nil {
        var launchFinished = false
        NSWorkspace.shared.openApplication(
            at: app,
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
    if arguments.activate {
        _ = running.activate(options: [.activateAllWindows])
    }
    let application = AXUIElementCreateApplication(running.processIdentifier)
    let identifier = arguments.fieldIdentifier ?? arguments.controlIdentifier ?? ""
    var match: AXUIElement?
    repeat {
        match = element(with: identifier, under: application)
        if match == nil { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    } while match == nil && Date() < deadline
    guard let match else {
        if arguments.fieldIdentifier != nil {
            print("INCONCLUSIVE target-field-unavailable")
            exit(2)
        }
        fputs("ERROR target-control-not-found\n", stderr)
        exit(1)
    }
    if arguments.pressControl, AXUIElementPerformAction(match, kAXPressAction as CFString) != .success {
        fputs("ERROR target-control-press-failed\n", stderr)
        exit(1)
    }
    if arguments.focus,
       AXUIElementSetAttributeValue(match, kAXFocusedAttribute as CFString, kCFBooleanTrue) != .success {
        fputs("ERROR target-field-focus-failed\n", stderr)
        exit(1)
    }
    if arguments.readValue {
        guard let value = attribute(kAXValueAttribute as CFString, from: match) as? String else {
            fputs("ERROR target-value-unavailable\n", stderr)
            exit(1)
        }
        print("AX_VALUE_CHECKPOINT identifier=" + identifier + " value=" + value)
    }
    if arguments.requireFocused {
        let focused = attribute(kAXFocusedAttribute as CFString, from: match) as? Bool ?? false
        guard focused,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleIdentifier else {
            fputs("ERROR focus-not-restored\n", stderr)
            exit(1)
        }
        print("AX_FOCUS_CHECKPOINT identifier=" + identifier + " focused=true")
    }
    if let checkpoint = arguments.frontmostCheckpoint {
        guard let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            fputs("ERROR frontmost-application-unavailable\n", stderr)
            exit(1)
        }
        print("FRONTMOST_CHECKPOINT name=" + checkpoint + " bundle=" + frontmost)
    }
    print("AX_CHECKPOINT trusted=true identifier=" + identifier)
} catch {
    fputs("ERROR malformed-input\n", stderr)
    exit(64)
}
