# Fn and transcription recovery verification

## Observed native behavior

On September 16, 2026, the owner confirmed that holding Fn, speaking, and releasing Fn inserted text into a blank TextEdit document.
The corresponding durable session was `completed`, contained 18 raw transcript bytes, recorded insertion as `dispatched`, and had no session or insertion failure reason.
The transcript and recording are not included in this report.

The locally ad-hoc-signed executable used for that observation had SHA256 `2a8dc00ae833cff39946d6f2f2ffe4a2f3b4edafe7849217f2db477a38d1dd39`.
Both Microphone and Accessibility were granted, and Settings displayed `Registration active: Fn` after relaunch.
A stale Accessibility grant from an earlier ad-hoc build had to be refreshed for the installed executable.
This was an owner-authorized local test, not clean-account or hosted-CI evidence.
Later onboarding layout and lifecycle changes must not be represented as included in that installed executable.

## Reproducible checks

- `swift run oigo-issue82-contract-tests` exercises shortcut registration, retired events, gesture timing, and Fn edge recovery.
- `swift run oigo-issue90-contract-tests` exercises oversized tap callbacks, bounded overflow, canonical channel extraction, and sample-exact CAF reads through EOF.
- `swift run oigo-spike --scenario production-speech --fixture /path/to/mono-speech.caf` runs the real live and saved-audio Speech paths using a synthetic spoken-audio fixture.
- The native UI contract harness exercises shortcut capture and suspension, dictionary editing, onboarding transitions, and History layout using isolated synthetic providers.
- `Scripts/inspect-oigo-app-bundle.sh` inspects the unsigned Release bundle independently of SwiftPM builds.

The production Speech smoke recognized nonempty text through both live and saved-audio paths after removing the duplicate analyzer input stream and correcting CAF buffer sizing.
Those fixture results do not prove microphone capture or cross-app insertion.

## Evidence boundaries

The app records third-party paste as dispatched, not independently verified.
The owner's observation confirms that one TextEdit test actually received text.
It does not establish every target application, hardware input, keyboard layout, permission transition, or clean-account scenario.
Native UI snapshots and independent scoped reviews cover layout, not live TCC, Speech, hardware, or physical Fn delivery.
Developer ID signing, notarization, release readiness, and the separate full native acceptance matrix remain outside this verification claim.
