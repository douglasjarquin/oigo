# Issue 82 Global Hotkey Matrix

This matrix records the deterministic press-and-hold and configuration contract for issue #82.

The canonical shortcut is Shift-Command-Space with hardware key code `49` and Carbon modifiers `0x300`.

The readable word form is `Shift-Command-Space`.

The native recorder displays modifier glyphs and accepts every valid hardware key code, including key code `0`.

The former shipped `49/0x900` value is retained only as an exact migration fixture.

## Deterministic contract rows

| Scenario | Result | Evidence | Boundary |
| --- | --- | --- | --- |
| Carbon press and release edges | PASS | `.omo/evidence/issue-82/task-2-registrar.log` | Strict registration fake delivers both typed edges. |
| Atomic replacement ordering | PASS | `.omo/evidence/issue-82/task-2-registrar.log` | Candidate registration precedes prior-registration teardown. |
| Failed replacement and stale generation | PASS | `.omo/evidence/issue-82/task-2-registrar-failure-and-generation.log` | Prior registration remains active and retired callbacks are ignored. |
| Rapid tap and startup release latch | PASS | `.omo/evidence/issue-82/task-3-intent-rapid-tap.log` | One start, one latched release, one safe-boundary stop, and zero cancellation commands. |
| Duplicate and repeat edges | PASS | `.omo/evidence/issue-82/task-3-intent-duplicates-and-processing.log` | Duplicate presses, duplicate releases, and repeat presses do not create a second operation. |
| Processing-state input | PASS | `.omo/evidence/issue-82/task-3-intent-duplicates-and-processing.log` | Finalizing, cleaning, and inserting return explicit ignored results. |
| Keyboard-owned startup bridge | PASS | `.omo/evidence/issue-82/task-6-app-bridge-release-green.log` | Release during startup finishes normally after recording begins. |
| Processing feedback bridge | PASS | `.omo/evidence/issue-82/task-6-app-bridge-processing-green.log` | Feedback names the exact processing state and counters remain unchanged. |
| Mouse-owned recording isolation | PASS | `.omo/evidence/issue-82/task-6-bridge-aggregate-final.log` | Keyboard input cannot stop a recording started by the menu command. |
| Canonical default and readable presentation | PASS | `.omo/evidence/issue-82/task-4-shortcut-contract-final.log` | Default is `49/0x300` and displays as `Shift-Command-Space`. |
| Exact legacy default migration | PASS | `.omo/evidence/issue-82/task-4-shortcut-contract-final.log` | Only `49/0x900` migrates, including the legacy `globalToggleShortcut` key. |
| Custom key-code-zero preservation | PASS | `.omo/evidence/issue-82/task-4-shortcut-keycode-zero-final.log` | `0/0x100` remains unchanged and validates successfully. |
| Native recorder key-code-zero capture | PASS | `.omo/evidence/issue-82/task-5-recorder-keycode-zero-green.log` | Non-repeat Command-A emits one candidate and displays `⌘A`. |
| Recorder repeat, unsupported modifier, modified Escape, and unmodified Escape behavior | PASS | `.omo/evidence/issue-82/task-13-recorder-escape-final.log` | Repeats and invalid modifiers are rejected, modified Escape is saved as a valid candidate, and unmodified Escape restores the candidate. |
| Validation-only registration | PASS | `.omo/evidence/issue-82/task-7-configuration-atomic-save-green.log` | Probe leaves the active shortcut and generation unchanged. |
| Atomic save and persistence | PASS | `.omo/evidence/issue-82/task-7-configuration-atomic-save-green.log` | Registration commits before persistence and both values converge. |
| Failed save restoration | PASS | `.omo/evidence/issue-82/task-7-configuration-failure-restoration-green.log` | Registration and persistence remain on the prior working shortcut. |
| Cancel and close candidate discard | PASS | `.omo/evidence/issue-82/task-7-configuration-failure-restoration-green.log` | Candidate changes are discarded without changing the committed registration. |
| Existing issue-3 mouse toggle contract | PASS | `.omo/evidence/issue-82/task-6-issue3-regression.log` | Menu-owned start and stop remain separate from keyboard ownership. |

## Native acceptance rows

| Scenario | Result | Evidence | Exact limitation |
| --- | --- | --- | --- |
| Exact Release `Oigo.app` bundle build | PASS | `.omo/evidence/issue-82/task-13-xcode-release-build-final.log` | Xcode 26.6 on macOS 26.6.1 produced the exact unsigned Release bundle. |
| macOS 26+ exact-bundle launch | PASS | `.omo/evidence/issue-82/task-13-native-launch-final.log` | The exact bundle launched with isolated defaults and was closed by the harness. |
| Separate global key-down and key-up with another app frontmost | INCONCLUSIVE | `.omo/evidence/issue-82/task-13-native-prerequisites-final.log` | Computer Use Accessibility and Screen Recording permissions remained unavailable, so OS-level edge automation was not run. |
| Microphone, Speech, and Input Monitoring acceptance | INCONCLUSIVE | `.omo/evidence/issue-82/task-13-native-prerequisites-final.log` | Permission-backed live capture was not attempted and no TCC or Accessibility state was changed. |
| Focus preservation through recording and insertion | INCONCLUSIVE | `.omo/evidence/issue-82/task-13-native-prerequisites-final.log` | TextEdit was launched as a disposable frontmost target, but the exact bundle could not be driven through global edges without native permissions. |

Unavailable native rows are not substituted with SwiftPM, direct callback, unsigned-binary, or frontmost-Oigo evidence.

Native acceptance must be rerun against the exact Release `Oigo.app` on macOS 26+ with another application frontmost.

The issue #12 compatibility and dogfood handoff is tracked in `docs/issue-12-global-shortcut-handoff-matrix.md`.

The native run must record frontmost bundle identity before press, during recording, after release, and after terminal insertion or copy-only completion.

The native run must not grant, revoke, reset, or otherwise mutate Microphone, Accessibility, Automation, Input Monitoring, shared defaults, or system shortcut state.
