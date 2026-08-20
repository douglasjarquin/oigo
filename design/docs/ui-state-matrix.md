# Oigo UI state matrix

Every surface derives availability from one presentation adapter (`OigoPresentationState`) consuming: operation gate, coordinator state, storage health, permission state, shortcut status, durable session metadata, current outcome. No per-controller busy Booleans. No enabled control whose command can only be silently rejected.

| state | menu-bar icon | popover status | primary action | HUD | recovery | dismissal |
|---|---|---|---|---|---|---|
| Storage checking | outline | Checking… | disabled | — | — | — |
| Storage ready / Idle | outline | Ready | Start Dictation | — | — | — |
| Storage unavailable | attention badge | Attention Needed | Retry Storage | — | notice: Retry / Open Data Location | until resolved |
| Shortcut inactive/conflict | attention badge | Attention Needed | Start Dictation (mouse) enabled; notice | — | Open Settings | until resolved |
| Mic permission unavailable | attention badge | Attention Needed | disabled | — | Open System Settings | until resolved |
| Selected input unavailable | attention badge | Attention Needed | disabled | — | Choose Input (never auto-substitute) | until resolved |
| Language assets checking/installing | outline | Checking/Installing… | disabled | — | progress in Settings/onboarding | on ready |
| Language assets unavailable | attention badge | Attention Needed | disabled | — | Install / Open Settings | until resolved |
| Accessibility unavailable | outline | Ready · Copy-only | Start Dictation | terminal shows Copied | info notice: Open System Settings | persistent info |
| Preparing | activity | Preparing… | disabled | Preparing… | — | on ready |
| Recording | red + badge | Recording | Stop Dictation | red dot + timer + hint (+preview) | — | on release |
| Finalizing / Cleaning / Inserting | activity | phase label | disabled | phase label… | — | on terminal |
| Paste event attempted | outline | Ready | Start Dictation | ✓ Paste attempted | — | ~1.8 s |
| Paste verified (Oigo-owned test field only) | — | — | — | onboarding checklist ✓ | — | — |
| Copied only / secure-field / changed-target | outline | Ready | Start Dictation | ✓ Copied to Clipboard (calm) | Paste Again from popover/History | ~1.8 s |
| Cleanup fallback to raw/normalized | outline | Ready | Start Dictation | ✓ Paste attempted | History note: fallback used, raw kept | ~1.8 s |
| Completed with insertion failure | outline | Ready (History flags it) | Start Dictation | ⚠ Paste failed — text preserved | Copy / Paste Again | ~3 s |
| Live transcription degraded → retry required | attention badge | Attention Needed | Retry Transcription | ⚠ Recording Saved — Retry Needed | Retry Transcription (popover, History) | ~3 s; persists in popover/History |
| Cancelled before durable raw text | outline | Ready | Start Dictation | Cancelled | none (nothing recoverable) | ~1.5 s |
| Cancelled after durable raw text | outline | Ready | Start Dictation | Cancelled | session remains in History | ~1.5 s |
| Interrupted | attention badge | Attention Needed | Start Dictation | ⚠ Interrupted | History: audio preserved to interruption | ~3 s |
| Busy (typed reason) | activity | busy label | disabled with reason | active phase | — | on gate release |
| Shutting down | outline | Quitting… | disabled | released | — | — |

## Explicit distinctions
- **Paste attempted ≠ verified**: Command-V into third-party fields is "Paste attempted". "Verified" exists only in the Oigo-owned onboarding field.
- **Completed with paste failure ≠ dictation failure**: durable text exists; offer Copy/Paste Again, never a catastrophic alert.
- **Copy-only fallback is calm**: secure/changed field → "Copied to Clipboard", informational tone.
- **Cleanup fallback ≠ lost dictation**: raw transcript inserted/kept; History explains.
- **Retry-required keeps the audio**: HUD says "Recording Saved"; persistent recovery lives in popover + History, not the HUD.
- **Cancel before vs after durable raw text**: only the latter leaves a History session.
- **Busy rejection is visible**: commands disable with the typed reason; nothing fails silently.
- **A stale operation generation never dismisses or replaces a newer HUD, list, or selection.**
