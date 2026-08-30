public struct OigoShortcutCopy: Equatable, Sendable {
    public let displayName: String
    public let compactDisplayName: String
    public let glyphs: [String]
    public let accessibilityLabel: String
    public let holdHint: String
    public let inactiveHint: String
    public let releaseHint: String

    public var settingsHint: String {
        "Click the recorder and press a shortcut. Current shortcut: " + displayName
            + ". Validation never displaces the current working registration."
    }

    public var activeStatus: String {
        "Registration active: " + displayName
    }

    public var registeredStatus: String {
        "Registered: " + displayName
    }

    public var globalTitle: String {
        "Global Shortcut: " + displayName
    }

    public var activeToolTip: String {
        "Global shortcut active: " + displayName
    }

    public var retryHint: String {
        "Press " + displayName + " again to start dictation."
    }

    public func ignoredMessage(while state: String) -> String {
        displayName + " ignored while " + state + " is running"
    }

    public var menuRecordingIgnoredMessage: String {
        displayName + " ignored: recording was started from the menu"
    }

    public func unavailableMessage(_ reason: String) -> String {
        displayName + " unavailable: " + reason
    }
}

public enum OigoShortcutPresentation {
    public static func copy(for shortcut: ToggleShortcut) -> OigoShortcutCopy {
        var components: [String] = []
        var glyphs: [String] = []
        if shortcut.modifiers & ToggleShortcutModifiers.shift != 0 {
            components.append("Shift")
            glyphs.append("⇧")
        }
        if shortcut.modifiers & ToggleShortcutModifiers.control != 0 {
            components.append("Control")
            glyphs.append("⌃")
        }
        if shortcut.modifiers & ToggleShortcutModifiers.option != 0 {
            components.append("Option")
            glyphs.append("⌥")
        }
        if shortcut.modifiers & ToggleShortcutModifiers.command != 0 {
            components.append("Command")
            glyphs.append("⌘")
        }
        let key = keyName(for: shortcut.keyCode)
        components.append(key)
        glyphs.append(key)
        let displayName = components.joined(separator: "-")
        return OigoShortcutCopy(
            displayName: displayName,
            compactDisplayName: glyphs.joined(),
            glyphs: glyphs,
            accessibilityLabel: components.joined(separator: " "),
            holdHint: "Hold " + glyphs.joined(separator: " ") + " to dictate",
            inactiveHint: displayName + " inactive. Open Settings to choose another shortcut.",
            releaseHint: "Release " + displayName + " to finish."
        )
    }

    public static func displayName(for shortcut: ToggleShortcut) -> String {
        copy(for: shortcut).displayName
    }

    public static func keyName(for keyCode: UInt32) -> String {
        switch keyCode {
        case 0:
            "A"
        case 1:
            "S"
        case 2:
            "D"
        case 3:
            "F"
        case 4:
            "H"
        case 5:
            "G"
        case 6:
            "Z"
        case 7:
            "X"
        case 8:
            "C"
        case 9:
            "V"
        case 11:
            "B"
        case 12:
            "Q"
        case 13:
            "W"
        case 14:
            "E"
        case 15:
            "R"
        case 16:
            "Y"
        case 17:
            "T"
        case 18:
            "1"
        case 19:
            "2"
        case 20:
            "3"
        case 21:
            "4"
        case 22:
            "6"
        case 23:
            "5"
        case 24:
            "="
        case 25:
            "9"
        case 26:
            "7"
        case 27:
            "-"
        case 28:
            "8"
        case 29:
            "0"
        case 36:
            "Return"
        case 48:
            "Tab"
        case 49:
            "Space"
        case 51:
            "Delete"
        case 53:
            "Escape"
        default:
            "Key \(keyCode)"
        }
    }
}

public extension ToggleShortcut {
    var copy: OigoShortcutCopy {
        OigoShortcutPresentation.copy(for: self)
    }

    var displayName: String {
        copy.displayName
    }
}
