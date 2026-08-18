public enum OigoShortcutPresentation {
    public static func displayName(for shortcut: ToggleShortcut) -> String {
        var components: [String] = []
        if shortcut.modifiers & ToggleShortcutModifiers.shift != 0 {
            components.append("Shift")
        }
        if shortcut.modifiers & ToggleShortcutModifiers.control != 0 {
            components.append("Control")
        }
        if shortcut.modifiers & ToggleShortcutModifiers.option != 0 {
            components.append("Option")
        }
        if shortcut.modifiers & ToggleShortcutModifiers.command != 0 {
            components.append("Command")
        }
        components.append(keyName(for: shortcut.keyCode))
        return components.joined(separator: "-")
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
    var displayName: String {
        OigoShortcutPresentation.displayName(for: self)
    }
}
