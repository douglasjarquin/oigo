import OigoCore

public enum ShortcutFormatter {
    public static func displayName(for shortcut: ToggleShortcut) -> String {
        modifierGlyphs(for: shortcut.modifiers) + OigoShortcutPresentation.keyName(for: shortcut.keyCode)
    }

    public static func modifierGlyphs(for modifiers: UInt32) -> String {
        var result = ""
        if modifiers & ToggleShortcutModifiers.control != 0 {
            result += "⌃"
        }
        if modifiers & ToggleShortcutModifiers.option != 0 {
            result += "⌥"
        }
        if modifiers & ToggleShortcutModifiers.shift != 0 {
            result += "⇧"
        }
        if modifiers & ToggleShortcutModifiers.command != 0 {
            result += "⌘"
        }
        return result
    }
}
