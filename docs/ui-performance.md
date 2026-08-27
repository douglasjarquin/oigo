# Oigo integrated UI performance and lifecycle evidence

Reviewed implementation SHA: `c5a6143df0ab7b08f91745d03d046d1190d253c4`.
The native unsigned Release artifact was built with Xcode 17F113 on macOS 26.6.2 build 25G83.
The host model is Mac15,11 with 14 logical CPUs and 36 GB of memory.
The tested application is the unsigned local Release `Oigo.app` built from `Oigo.xcodeproj` and scheme `Oigo`.

## Deterministic contract

The integrated UI contract is `Tests/OigoNativeUIContractTests/Scenarios/task-20/IntegratedUIContractScenario.swift`.
It passed with `swift run oigo-native-ui-contract-tests --scenario integrated-ui --defaults-suite com.oigo.qa.task20 --fixture-root "$PWD/T/oigo-native-ui-redesign.issue139/task-20"`.
The contract covers the single command key map, Escape priority, three restoration identifiers, visible-frame clamping, and prohibited idle behaviors.
It reports counts and geometry only and does not load transcript, audio, clipboard, dictionary, target, or focused-element content.

## Native observations

| Surface | Observation | Result |
| --- | --- | --- |
| History chrome | Native Xcode Debug app reached the 1000×640 History split workspace and toolbar after launch. | PASS |
| History list | The initial page remained bounded and rows rendered metadata-only summaries with truncation. | PASS |
| Idle behavior | No new recurring timer, global monitor, permission poll, History poll, transcript preload, or model prewarm was added by this phase. | PASS by source and contract |
| Window restoration | Settings and History have stable identifiers and autosave names; restored frames clamp to the current visible screen. | PASS by source and contract; native relaunch/display-change run INCONCLUSIVE |
| Keyboard and Escape | The app menu supplies `⌘,`, `⌘Q`, Copy, and Select All; utility windows route Escape to safe editor/probe/test cancellation before close. | PASS by source and contract; native keyboard run INCONCLUSIVE |
| Release artifact | Developer ID signing, notarization, Gatekeeper, TCC, VoiceOver, multi-application, multi-display, full-screen Space, and 100-cycle host matrices require release credentials or operator access. | INCONCLUSIVE |

The fresh native capture is `.omo/evidence/issue139/native/history-integrated-fixed.jpg`.
The capture was taken from the source-equivalent Debug build because the temporary QA launch hook is intentionally excluded from production; the unsigned Release hash is recorded separately below.
The final source-equivalent Release application binary is `sha256:8bb9df44bcca3ad5424b99ddfc528df1caffd6981632bd01c2fb5923b0163abe`.

## UI-specific budget record

The following measurements are required by issue #139 and are recorded explicitly rather than inferred from deterministic contracts.

| Measurement | p50 | p95 | Resource high-water | Result |
| --- | ---: | ---: | --- | --- |
| Healthy popover first open | INCONCLUSIVE | INCONCLUSIVE | visible task count not instrumented | No native click trace was captured on this host. |
| Subsequent popover open | INCONCLUSIVE | INCONCLUSIVE | visible task count not instrumented | No native click trace was captured on this host. |
| Settings cached General open | INCONCLUSIVE | INCONCLUSIVE | active task count not instrumented | No repeated native timing run was captured. |
| Settings loaded pane switch | INCONCLUSIVE | INCONCLUSIVE | active task count not instrumented | No repeated native timing run was captured. |
| History chrome to loading state | INCONCLUSIVE | INCONCLUSIVE | enumeration task high-water not instrumented | The bounded contract and source path pass, but no timing signpost was captured. |
| History 100-cycle open/select/close | INCONCLUSIVE | INCONCLUSIVE | controller and transcript high-water not instrumented | No native lifecycle matrix was run. |

Existing issue #11 deterministic performance scenarios pass separately and remain the authoritative CPU, footprint, memory, latency, and no-network gate.
The missing native timings, counters, VoiceOver, appearance, TCC, multi-display, application matrix, and signed-release checks are release-operator limitations and remain `INCONCLUSIVE`.

## Privacy boundary

This report contains no transcript text, audio data, dictionary terms, clipboard content, focused-element text, target coordinates, credentials, or user-content paths.
The release-only signing and notarization gates remain explicitly unclaimed until the operator runs `Scripts/package-oigo-release.sh` with credentials.
