# Issue #12 Global Shortcut Handoff Matrix

This matrix hands the issue #82 global shortcut scenarios to issue #12's exact-release compatibility and dogfood run.

It is a handoff artifact, not a claim that issue #12 native acceptance is complete.

The issue #12 operator must pin one reviewed source SHA and the exact Release `Oigo.app` from the `oigo-app-<checked-out-sha>` artifact uploaded by the `Xcode app bundle` job.

If a Developer ID signed candidate is required, issue #14 must build it from that same Xcode contract rather than substituting a SwiftPM executable.

The operator must record only non-content results and must classify unavailable app-bundle, permission, Speech, input-monitoring, focus, or separate key-edge surfaces as `INCONCLUSIVE`.

| Handoff row | Deterministic contract | Native issue #12 run | Evidence to carry forward | Required native observation |
| --- | --- | --- | --- | --- |
| H82-01 Press and hold | PASS: one keyboard-owned start | INCONCLUSIVE until exact bundle receives separate key-down and key-up edges | `.omo/evidence/issue-82/task-18-final-verification.log`, `.omo/evidence/issue-82/task-18-native-launch.log` | Another application remains frontmost before, during, and after the operation. |
| H82-02 Release after startup | PASS: permission/Speech/audio startup release latches and stops at recording | INCONCLUSIVE until permission-backed native startup is available | `.omo/evidence/issue-82/task-18-final-verification.log` | No cancellation or discarded recoverable audio occurs. |
| H82-03 Repeat, duplicate, and rapid tap | PASS: no second start, duplicate stop, or stuck preparing state | INCONCLUSIVE until physical repeat and rapid tap can be sent to the exact bundle | `.omo/evidence/issue-82/task-18-final-verification.log` | Exactly one session reaches a terminal result. |
| H82-04 Processing input | PASS: finalizing, cleaning, and inserting produce explicit ignored feedback | INCONCLUSIVE until the processing HUD is observed on the native surface | `.omo/evidence/issue-82/task-18-final-verification.log` | Shortcut input does not cancel or alter finalization, cleanup, or insertion. |
| H82-05 Mouse menu toggle | PASS: issue #3 mouse start and stop remain a separate toggle | INCONCLUSIVE until the exact status menu is exercised | `.omo/evidence/issue-82/task-18-final-verification.log` | Menu Start Dictation and Stop Dictation remain mouse-driven and do not claim keyboard ownership. |
| H82-06 Registration conflict and restoration | PASS: conflict is actionable and prior registration/persistence remain working | INCONCLUSIVE until a real occupied Carbon shortcut is observed in onboarding, Settings, and the menu | `.omo/evidence/issue-82/task-18-final-verification.log` | Validation-only, close, cancellation, failed save, and replacement failure never leave the configured shortcut inactive. |
| H82-07 Recorder key code zero and modified Escape | PASS: key code `0` and modified key code `53` are valid candidates; unmodified Escape cancels | INCONCLUSIVE until the recorder is driven in the exact onboarding and Settings windows | `.omo/evidence/issue-82/task-18-final-verification.log` | Readable native recorder output matches the stored candidate. |
| H82-08 Canonical default | PASS: Shift-Command-Space is `49/0x300` everywhere; exact `49/0x900` migration is isolated | INCONCLUSIVE for a host-level standard-shortcut conflict check | `.omo/evidence/issue-82/task-18-final-verification.log`, `docs/issue-82-global-hotkey-matrix.md` | Registration, stored settings, onboarding, Settings, tests, and docs agree. |
| H82-09 Focus and nonactivation | PASS by static and deterministic path constraints; no keyboard callback activates Oigo | INCONCLUSIVE until frontmost bundle identity is recorded through a native press/release run | `.omo/evidence/issue-82/task-18-native-launch.log` | Oigo never becomes frontmost and the selected target remains the other application. |

## Issue #12 execution boundary

The exact Release bundle build passed at the issue #82 final SHA, and an isolated launch observed TextEdit frontmost.

Computer Use Accessibility and Screen Recording permissions were unavailable during this handoff, so global key edges, microphone, Speech, input-monitoring, native focus, recording, and insertion rows remain `INCONCLUSIVE`.

The issue #12 run must not convert those rows to `PASS` using SwiftPM callbacks, unsigned-binary launch, deterministic fakes, static source inspection, or a green hosted CI job.

Hosted CI does not replace native TCC, Speech, Accessibility, hardware, or dogfood proof.

The issue #12 operator must not mutate TCC, Accessibility, Automation, Input Monitoring, shared defaults, system shortcut state, or private dogfood content to make a row pass.

## Issue #105 locale-fenced speech assets

Deterministic issue #9 `locale` contract rows cover locale-switch races, late asset results, unavailable stored locales, Settings unrelated saves, onboarding close/rerun, and Continue enablement.

Native issue #12 must still exercise the exact Release `Oigo.app` bundle. Do not convert these rows to `PASS` from SwiftPM callbacks or static source inspection.

| Handoff row | Deterministic contract | Native issue #12 run | Evidence to carry forward | Required native observation |
| --- | --- | --- | --- | --- |
| H105-01 Locale switch during check | PASS: late ready result for locale A cannot enable Continue after locale B is selected | INCONCLUSIVE until onboarding language popup is driven on the exact bundle | `swift run oigo-issue9-contract-tests --suite locale` | Continue stays disabled until the newly selected locale has a matching ready result. |
| H105-02 Locale switch during install | PASS: late install success cannot persist the abandoned locale | INCONCLUSIVE until Speech asset installation can be observed on the exact bundle | `swift run oigo-issue9-contract-tests --suite locale` | Changing language while assets install leaves the previous committed locale unchanged. |
| H105-03 Late success or failure | PASS: old generation success and failure are ignored | INCONCLUSIVE until overlapping Speech asset results can be observed | `swift run oigo-issue9-contract-tests --suite locale` | Status, Continue, and persistence stay tied to the current locale generation. |
| H105-04 Back/forward language step | PASS: returning to the language step requires a new matching ready result | INCONCLUSIVE until onboarding back/forward is driven on the exact bundle | `swift run oigo-issue9-contract-tests --suite locale` | Continue is disabled after returning to Dictation language until assets are rechecked. |
| H105-05 Close, reopen, and rerun | PASS: abandoning onboarding before Continue preserves the committed language | INCONCLUSIVE until close/reopen and Settings rerun are driven on the exact bundle | `swift run oigo-issue9-contract-tests --suite locale` | Closing or rerunning onboarding does not replace the saved dictation language. |
| H105-06 Unavailable stored locale | PASS: missing supported locale stays selected as an unavailable row | INCONCLUSIVE until Settings is opened with a stored locale absent from Speech's supported list | `swift run oigo-issue9-contract-tests --suite locale` | Settings shows the current language as unavailable and does not jump to the first supported locale. |
| H105-07 Settings unrelated save | PASS: retention/mode/preview saves keep the committed locale | INCONCLUSIVE until Settings save is observed on the exact bundle | `swift run oigo-issue9-contract-tests --suite locale` | Saving unrelated settings does not change dictation language. |
| H105-08 Settings language change | PASS: install failure leaves the previous locale; success commits only the verified locale | INCONCLUSIVE until Settings can install and fail Speech assets on the exact bundle | `swift run oigo-issue9-contract-tests --suite locale` | A failed language change is left unapplied; unrelated settings can still save. |
| H105-09 First real dictation | PASS: committed locale is the locale whose assets were verified ready | INCONCLUSIVE until the first valuable dictation is run on the exact bundle after onboarding/Settings language confirmation | `swift run oigo-issue9-contract-tests --suite locale` | The first dictation uses the verified-ready locale and does not fail for a stale unverified selection. |
