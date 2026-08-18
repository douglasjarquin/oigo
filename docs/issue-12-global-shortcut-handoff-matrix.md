# Issue #12 Global Shortcut Handoff Matrix

This matrix hands the issue #82 global shortcut scenarios to issue #12's exact-release compatibility and dogfood run.

It is a handoff artifact, not a claim that issue #12 native acceptance is complete.

The issue #12 operator must pin one reviewed source SHA and one exact Release `Oigo.app` bundle before running the native rows.

The operator must record only non-content results and must classify unavailable app-bundle, permission, Speech, input-monitoring, focus, or separate key-edge surfaces as `INCONCLUSIVE`.

| Handoff row | Deterministic contract | Native issue #12 run | Evidence to carry forward | Required native observation |
| --- | --- | --- | --- | --- |
| H82-01 Press and hold | PASS: one keyboard-owned start | INCONCLUSIVE until exact bundle receives separate key-down and key-up edges | `.omo/evidence/issue-82/task-14-final-verification.log`, `.omo/evidence/issue-82/task-14-native-prerequisites-final.log` | Another application remains frontmost before, during, and after the operation. |
| H82-02 Release after startup | PASS: permission/Speech/audio startup release latches and stops at recording | INCONCLUSIVE until permission-backed native startup is available | `.omo/evidence/issue-82/task-6-app-bridge-release-green.log` | No cancellation or discarded recoverable audio occurs. |
| H82-03 Repeat, duplicate, and rapid tap | PASS: no second start, duplicate stop, or stuck preparing state | INCONCLUSIVE until physical repeat and rapid tap can be sent to the exact bundle | `.omo/evidence/issue-82/task-3-intent-rapid-tap.log`, `.omo/evidence/issue-82/task-3-intent-duplicates-and-processing.log` | Exactly one session reaches a terminal result. |
| H82-04 Processing input | PASS: finalizing, cleaning, and inserting produce explicit ignored feedback | INCONCLUSIVE until the processing HUD is observed on the native surface | `.omo/evidence/issue-82/task-6-app-bridge-processing-green.log` | Shortcut input does not cancel or alter finalization, cleanup, or insertion. |
| H82-05 Mouse menu toggle | PASS: issue #3 mouse start and stop remain a separate toggle | INCONCLUSIVE until the exact status menu is exercised | `.omo/evidence/issue-82/task-9-final-verification.log` | Menu Start Dictation and Stop Dictation remain mouse-driven and do not claim keyboard ownership. |
| H82-06 Registration conflict and restoration | PASS: conflict is actionable and prior registration/persistence remain working | INCONCLUSIVE until a real occupied Carbon shortcut is observed in onboarding, Settings, and the menu | `.omo/evidence/issue-82/task-7-configuration-aggregate-final.log` | Validation-only, close, cancellation, failed save, and replacement failure never leave the configured shortcut inactive. |
| H82-07 Recorder key code zero and modified Escape | PASS: key code `0` and modified key code `53` are valid candidates; unmodified Escape cancels | INCONCLUSIVE until the recorder is driven in the exact onboarding and Settings windows | `.omo/evidence/issue-82/task-14-recorder-escape-final.log` | Readable native recorder output matches the stored candidate. |
| H82-08 Canonical default | PASS: Shift-Command-Space is `49/0x300` everywhere; exact `49/0x900` migration is isolated | INCONCLUSIVE for a host-level standard-shortcut conflict check | `.omo/evidence/issue-82/task-4-shortcut-contract-final.log`, `docs/issue-82-global-hotkey-matrix.md` | Registration, stored settings, onboarding, Settings, tests, and docs agree. |
| H82-09 Focus and nonactivation | PASS by static and deterministic path constraints; no keyboard callback activates Oigo | INCONCLUSIVE until frontmost bundle identity is recorded through a native press/release run | `.omo/evidence/issue-82/task-14-native-launch-final.log` | Oigo never becomes frontmost and the selected target remains the other application. |

## Issue #12 execution boundary

The exact Release bundle build passed at the issue #82 final SHA, and an isolated launch observed TextEdit frontmost.

Computer Use Accessibility and Screen Recording permissions were unavailable during this handoff, so global key edges, microphone, Speech, input-monitoring, native focus, recording, and insertion rows remain `INCONCLUSIVE`.

The issue #12 run must not convert those rows to `PASS` using SwiftPM callbacks, unsigned-binary launch, deterministic fakes, or static source inspection.

The issue #12 operator must not mutate TCC, Accessibility, Automation, Input Monitoring, shared defaults, system shortcut state, or private dogfood content to make a row pass.
