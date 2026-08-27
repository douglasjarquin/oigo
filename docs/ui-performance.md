# Oigo integrated UI performance and lifecycle evidence

Reviewed implementation SHA: `7989042ad6a046078abb193fcf9170b794543a42`.
The native Debug artifact was built with Xcode 17F113 on macOS 26.6.2 build 25G83.
The host model is Mac15,11 with 14 logical CPUs and 36 GB of memory.
The tested application is the unsigned local Debug `Oigo.app` built from `Oigo.xcodeproj` and scheme `Oigo`.

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
| Window restoration | Settings and History have stable identifiers and autosave names; restored frames clamp to the current visible screen. | PASS by source and contract |
| Keyboard and Escape | The app menu supplies `⌘,`, `⌘Q`, Copy, and Select All; utility windows route Escape to safe editor/probe/test cancellation before close. | PASS by source and contract |
| Release artifact | Developer ID signing, notarization, Gatekeeper, TCC, VoiceOver, multi-application, multi-display, full-screen Space, and 100-cycle host matrices require release credentials or operator access. | INCONCLUSIVE |

The fresh native capture is `.omo/evidence/issue139/native/history-integrated.jpg`.
The final source-equivalent Debug application binary is `sha256:473ca3120a086053800048271e14e60824577dbb7e130a37c6208abbb6f26fee`.

## Privacy boundary

This report contains no transcript text, audio data, dictionary terms, clipboard content, focused-element text, target coordinates, credentials, or user-content paths.
The release-only signing and notarization gates remain explicitly unclaimed until the operator runs `Scripts/package-oigo-release.sh` with credentials.
