# Native raw transcript insertion

Oigo captures a lightweight target snapshot when dictation starts.
The snapshot contains the frontmost process identifier, bundle identifier, a stable identifier for the focused Accessibility element when available, its role, and whether it is a secure text field.
The Accessibility object itself is not retained after the snapshot, so insertion does not keep application resources alive.

After transcription finishes, the existing session store must have atomically persisted `raw.txt` before insertion reads it.
The insertion service writes that canonical raw text to the general pasteboard and leaves it there for the user.
It never restores the previous pasteboard contents.

The service validates Accessibility permission, the frontmost process and bundle, focused-element identity, role, and secure-field state immediately before synthesizing Command-V.
It synthesizes one Command-V only when all checks pass.
Every other validation result produces copy-only behavior after the raw text has been placed on the clipboard.

Secure text fields never receive an automatic paste.
The secure-field outcome is persisted as `secureRejected` while the operator-facing status is `Copied`.
An unexpected application or focus change also produces copy-only behavior.

Insertion is one-shot per session.
Duplicate shortcut callbacks and repeated completion callbacks cannot write or paste the same session twice.
The coordinator persists `pasted`, `copied`, `secureRejected`, or `failed` with an optional reason and exposes `Finalizing`, `Pasted`, `Copied`, or `Failed` without blocking the status surface.

## Supported application matrix

The MVP uses the public Accessibility editable-role contract rather than application-specific adapters.
The following applications are in scope when their focused control reports `AXTextField`, `AXTextArea`, `AXComboBox`, or `AXSearchField` and the user has granted Accessibility permission.

| Application | Automatic-paste boundary | Copy-only limitation |
| --- | --- | --- |
| ChatGPT | Focused editable composer | Custom or role-less composers require manual paste. |
| Codex | Focused editable composer | Custom or role-less composers require manual paste. |
| Safari | Focused web text control | Web controls that do not expose a supported role require manual paste. |
| Chrome | Focused web text control | Web controls that do not expose a supported role require manual paste. |
| Xcode | Focused editor or text field | Controls without a supported role require manual paste. |
| VS Code | Focused editor or text field | Controls without a supported role require manual paste. |
| Terminal | Focused input control | Alternate terminal widgets that do not expose a supported role require manual paste. |
| WezTerm | Focused input control | Alternate terminal widgets that do not expose a supported role require manual paste. |
| Slack | Focused message composer | Custom composers that do not expose a supported role require manual paste. |
| Mail | Focused message editor | Rich editor controls that do not expose a supported role require manual paste. |
| Notes | Focused note editor | Rich editor controls that do not expose a supported role require manual paste. |

This boundary deliberately does not poll, inspect whole documents, or add brittle per-application adapters.
Applications that expose only custom or role-less editing surfaces remain usable through the clipboard fallback.
