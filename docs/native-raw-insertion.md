# Native raw transcript insertion

Oigo captures the frontmost process, bundle, focused Accessibility element, public identity corroborators, capability state, and secure-field state before microphone permission or recording begins.
The captured Accessibility object is retained only as a main-actor-owned ephemeral reference for the active insertion and is discarded on every insertion terminal path.
Identity uses public `CFEqual` semantics plus optional Accessibility identifier, owning-window identifier, role/subrole, and ancestry evidence.
No hash is used as the sole identity contract.

After transcription finishes, the existing session store must have atomically persisted `raw.txt` before insertion reads it.
The insertion service writes that canonical raw text to the general pasteboard and leaves it there for the user.
It never restores the previous pasteboard contents.

The service validates Accessibility permission, the frontmost process and bundle, focused-element identity, capability support, settable value or selected-text attributes, enabled state, and secure-field state immediately before synthesizing Command-V.
It synthesizes one Command-V only when all checks pass.
Every other validation result produces copy-only behavior after the raw text has been placed on the clipboard.

Secure text fields never receive an automatic paste.
The secure-field outcome is persisted as `secureRejected` while the operator-facing status is `Copied`.
An unexpected application or focus change also produces copy-only behavior.

Insertion is one-shot per session.
Duplicate shortcut callbacks and repeated completion callbacks cannot dispatch the same session twice.
The service persists `dispatched` for an event that was sent without destination acknowledgement and reserves `pasted` for an explicit verified acknowledgement.
Core Graphics `postToPid` returns `dispatched`, never `pasted`, for third-party fields.
Every failure exposes a stable content-free reason code.
The HUD and History surfaces call an unverified event `Paste attempted` and retain the transcript on the clipboard.
Terminal Paste attempted, Pasted, Copied, and Failed HUD messages dismiss after a short cancellation-safe interval.
A newer status cancels the older dismissal.

History Paste Again hides Oigo, waits for a bounded frontmost-application handoff, requires two stable target captures, dispatches at most once, records the truthful outcome, and restores History focus afterward.
Timeout or cancellation copies the durable transcript to the clipboard without recording a paste attempt.

## Supported application matrix

The MVP uses public Accessibility capabilities and settable attributes rather than a fixed role allowlist or application-specific adapters.
The following applications are in scope when their focused control exposes a supported and settable value or selected-text attribute and the user has granted Accessibility permission.

| Application | Automatic-paste boundary | Copy-only limitation |
| --- | --- | --- |
| ChatGPT | Focused editable composer | Unsupported, read-only, ambiguous, changed, or secure targets remain copy-only. |
| Codex | Focused editable composer | Unsupported, read-only, ambiguous, changed, or secure targets remain copy-only. |
| Safari | Focused web text control | Unsupported, read-only, ambiguous, changed, or secure targets remain copy-only. |
| Chrome | Focused web text control | Unsupported, read-only, ambiguous, changed, or secure targets remain copy-only. |
| Xcode | Focused editor or text field | Unsupported, read-only, ambiguous, changed, or secure targets remain copy-only. |
| VS Code | Focused editor or text field | Unsupported, read-only, ambiguous, changed, or secure targets remain copy-only. |
| Terminal | Focused input control | Unsupported, read-only, ambiguous, changed, or secure targets remain copy-only. |
| WezTerm | Focused input control | Unsupported, read-only, ambiguous, changed, or secure targets remain copy-only. |
| Slack | Focused message composer | Unsupported, read-only, ambiguous, changed, or secure targets remain copy-only. |
| Mail | Focused message editor | Unsupported, read-only, ambiguous, changed, or secure targets remain copy-only. |
| Notes | Focused note editor | Unsupported, read-only, ambiguous, changed, or secure targets remain copy-only. |

This boundary deliberately does not inspect whole documents, read third-party field values, or add brittle per-application adapters.
Applications that expose capable custom editing surfaces remain eligible even when their role is not in a fixed list.
Applications that expose no safe capability remain usable through the clipboard fallback.

Native Accessibility and permissioned app-bundle insertion evidence is host- and permission-dependent.
When those boundaries are unavailable, the native matrix is `INCONCLUSIVE` and no deterministic CLI or fake result is promoted to native PASS.
