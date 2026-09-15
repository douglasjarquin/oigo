import ApplicationServices
import Foundation

let raw = Array(CommandLine.arguments.dropFirst())
if raw == ["--check-only"] {
    guard CGPreflightPostEventAccess() else {
        print("COREGRAPHICS_POST_EVENT_CHECKPOINT=denied")
        print("INCONCLUSIVE coregraphics-post-event")
        exit(2)
    }
    print("COREGRAPHICS_POST_EVENT_CHECKPOINT=granted")
    exit(0)
}
guard raw.count == 6, raw[0] == "--key-code", raw[2] == "--modifiers", raw[4] == "--edge",
      let keyCode = UInt16(raw[1]), ["down", "up", "both"].contains(raw[5]) else {
    fputs("ERROR malformed-input\n", stderr)
    exit(64)
}

var flags: CGEventFlags = []
var seen = Set<String>()
if !raw[3].isEmpty {
    for modifier in raw[3].split(separator: ",").map(String.init) {
        guard seen.insert(modifier).inserted else { fputs("ERROR invalid-modifiers\n", stderr); exit(64) }
        switch modifier {
        case "command": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        case "option": flags.insert(.maskAlternate)
        case "control": flags.insert(.maskControl)
        case "function": flags.insert(.maskSecondaryFn)
        default: fputs("ERROR invalid-modifiers\n", stderr); exit(64)
        }
    }
}
guard CGPreflightPostEventAccess() else {
    print("COREGRAPHICS_POST_EVENT_CHECKPOINT=denied")
    print("INCONCLUSIVE coregraphics-post-event")
    exit(2)
}

func post(_ isDown: Bool) {
    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: isDown) else {
        fputs("ERROR event-creation-failed\n", stderr)
        exit(1)
    }
    event.flags = flags
    event.post(tap: .cghidEventTap)
}

if raw[5] != "up" {
    post(true)
    print("KEY_CHECKPOINT edge=down key_code=\(keyCode) modifiers=\(raw[3])")
}
if raw[5] != "down" {
    post(false)
    print("KEY_CHECKPOINT edge=up key_code=\(keyCode) modifiers=\(raw[3])")
}
