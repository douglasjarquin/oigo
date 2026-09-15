import OigoCore

public enum ShortcutFormatter {
    public static func displayName(for shortcut: ToggleShortcut) -> String {
        shortcut.copy.compactDisplayName
    }
}
