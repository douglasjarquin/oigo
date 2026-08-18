# Issue 82 Supported Shortcut Conflict Evidence

The canonical default is `Shift-Command-Space`, represented by hardware key code `49` and Carbon modifiers `0x300`.

The deterministic public matrix compares that exact value with the standard shortcuts listed by Apple Support for macOS 26.

Apple documents `Command-Space` for Spotlight, `Option-Command-Space` for a Finder search field, `Control-Command-Space` for Character Viewer, `Control-Space` and `Control-Option-Space` for input-source selection, and `Shift-Command-3`, `Shift-Command-4`, and `Shift-Command-5` for screenshots and recording.

The matrix contains those documented combinations and does not contain `Shift-Command-Space`.

This is a public-documentation PASS for the cited standard list, not a claim that every application-specific or user-customized shortcut is unused.

No supported-host System Settings conflict probe was run because the required native accessibility surface was unavailable.

The native host-level conflict row therefore remains `INCONCLUSIVE`, and the test does not read, write, reset, or otherwise mutate TCC, Accessibility, shared defaults, or system shortcut state.

Sources:

- [Apple Support: Mac keyboard shortcuts](https://support.apple.com/en-ie/102650)
- [Apple Support: Spotlight keyboard shortcuts on Mac](https://support.apple.com/en-ca/guide/mac-help/mh26783/mac)
- [Apple Support: Change a conflicting keyboard shortcut on Mac](https://support.apple.com/en-ie/guide/mac-help/mchlp2864/26/mac/26)
