# Issue 10 Reliability Matrix

This matrix records the issue #10 reliability scenarios against the v1 implementation.

## Scenario results

| Scenario | Result | Evidence | v1 limitation |
| --- | --- | --- | --- |
| Normal capture stop preserves the session and releases capture resources | PASS | `oigo-issue4-contract-tests`, `oigo-issue10-contract-tests` | Uses deterministic capture fixtures in contract tests. |
| Built-in microphone capture | INCONCLUSIVE | `AudioRecorder` default-input discovery and native AppKit launch | A permissioned live microphone capture was not performed on this host. |
| AirPods or Bluetooth microphone connect, disconnect, or format change | INCONCLUSIVE | Device/configuration notification handling and deterministic interruption contracts | AirPods or another Bluetooth input was not connected or disconnected during QA. |
| USB microphone unplug and reconnect | INCONCLUSIVE | Device/configuration notification handling and deterministic interruption contracts | A USB microphone was not available for physical unplug/reconnect QA. |
| Audio input device changes during capture | INCONCLUSIVE | `oigo-issue10-contract-tests` device interruption scenario and `oigo-issue4-contract-tests` interruption recovery | Physical device switching was not performed during this run; the deterministic interruption path passes. |
| Audio input format or engine configuration changes | INCONCLUSIVE | `oigo-issue4-contract-tests` interruption recovery | A live device format change was not performed; the notification-shaped fixture path passes. |
| Microphone disconnect during an active session | INCONCLUSIVE | `AudioRecorder` device listener and interruption terminalization | Physical microphone disconnect was not performed during QA. |
| System sleep interrupts capture | INCONCLUSIVE | `AudioRecorder` registers `NSWorkspace.willSleepNotification` | The host was not put to sleep during QA. |
| Sleep and wake across every active state | INCONCLUSIVE | Coordinator transitions cover preparing, recording, finalizing, cleaning, and inserting | Sleep/wake was not exercised in each active state on the host. |
| Screen lock or workspace resign-active interrupts capture | INCONCLUSIVE | `AudioRecorder` registers `NSWorkspace.sessionDidResignActiveNotification` | The host was not locked during QA. |
| Lock and unlock across every active state | INCONCLUSIVE | Workspace-resign-active handling and coordinator terminalization | Lock/unlock was not exercised in each active state on the host. |
| Microphone permission is revoked while capture is active | INCONCLUSIVE | `AudioRecorder` checks `AVAudioApplication.shared.recordPermission` before forwarding each buffer | Permission was not changed during QA. |
| Audio engine startup failure | INCONCLUSIVE | `oigo-issue4-contract-tests` actionable host failure and the recorder startup cleanup path | The deterministic host-failure path passes, but a physical engine fault was not induced. |
| Audio file write or metadata disk failure | PASS | `oigo-issue10-contract-tests` durable failure-code scenario and disk fault-injection matrix | A permanently unavailable disk can only retain the terminal state in memory until storage returns. |
| Transcription startup or analysis failure | INCONCLUSIVE | `oigo-issue10-contract-tests` speech fault-injection scenario and `oigo-issue5-contract-tests` analysis failure | Apple speech assets were not available for a real on-device transcription run; deterministic fault paths pass. |
| Cleanup timeout or unavailable cleanup model | INCONCLUSIVE | `oigo-issue10-contract-tests` cleanup-timeout fault injection and existing cleanup contract coverage | Foundation Models generation was not forced to time out on the host; the deterministic timeout seam and fallback path pass. |
| Target loss before paste | INCONCLUSIVE | `oigo-issue10-contract-tests` target-loss fault injection and issue #7 copy-only recovery coverage | An external target process was not terminated during QA; the deterministic copy-only recovery path passes. |
| Target application closes or crashes before insertion | INCONCLUSIVE | Target validation and copy-only insertion contracts | An external target application was not terminated during QA. |
| Cancellation during cleanup or insertion preparation | INCONCLUSIVE | `oigo-issue10-contract-tests` coordinator-owned cancellation terminalization scenario | The deterministic cancellation path passes, but live shortcut cancellation was not exercised during a native dictation. |
| Explicit cancellation during preparing, recording, finalizing, cleaning, and inserting | INCONCLUSIVE | Coordinator-owned task cancellation, active transcription shutdown, and insertion terminalization contracts | Every state is covered by deterministic contracts, but live shortcut cancellation was not generated in each native state. |
| Late callback from an earlier operation | PASS | `oigo-issue10-contract-tests` stale callback fencing scenario | Callback ordering is deterministic in the fixture. |
| Repeated cancellation does not leave parallel pipelines or capture resources | PASS | `oigo-issue10-contract-tests` 100 rapid cancellation cycles | Shortcut key repetition was not physically generated during QA. |
| Saved partial audio remains available after a capture failure | PASS | `oigo-issue10-contract-tests` verifies audio bytes and the retained audio file | Audio playback was not attempted from the injected failure in the native app. |
| Quit while tracked work exists waits for child cleanup | PASS | `oigo-issue10-contract-tests` awaited shutdown and issue #5 shutdown coverage | Active native capture was not left running while quitting. |
| Quit from preparing, recording, finalizing, cleaning, and inserting | INCONCLUSIVE | Coordinator-owned task shutdown and active-transcription shutdown contracts | Native quit was exercised only from the idle onboarding surface. |
| Quit after target-app termination or crash | INCONCLUSIVE | Target-loss copy-only recovery contracts | Native target-app termination during Oigo processing was not performed. |
| Native AppKit launch, onboarding surface, status menu, and idle quit | PASS | `.ulw/evidence/issue10-native-qa.log` and `.ulw/evidence/issue10-native-qa-activated.png` | The temporary QA bundle used an ad hoc local signature and did not complete permission setup. |

## Implementation notes

Terminal failures carry a stable `DictationFailureCode` in `session.json`.

Terminal metadata persistence retries once, then returns an in-memory terminal session if storage remains unavailable.

Operation UUIDs fence capture and transcription callbacks from older sessions.

Coordinator-owned AppKit tasks cancel and await cleanup work before terminal shutdown.

Cancellation during cleanup or insertion persists a failed insertion outcome with one metadata retry and an in-memory terminal fallback when storage remains unavailable.

Audio recorder teardown removes the engine tap, observers, device listener, and descriptor at most once.

Fault injection is exposed through Swift SPI and is used only by deterministic developer contract tests.

The v1 implementation does not auto-retry failed capture or transcription.

The v1 implementation maps an unfinished session recovered on the next launch to `application_quit`, even when the original interruption was caused by a host sleep or lock event.
