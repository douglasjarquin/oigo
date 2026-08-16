# Issue 11 Performance Matrix

This document is the reproducible release-check procedure for Oigo resource budgets and lifecycle release gates.

The procedure keeps generated traces, sanitized measurements, transcripts, audio, and crash diagnostics outside delivery commits.

## Hard budgets

The hard limits are encoded in `PerformanceBudgetCatalog.hardGates`.

The release check treats a missing or explicitly unavailable measurement as `INCONCLUSIVE`.

It never turns an unavailable host measurement into a pass.

For latency rows, the target is the p50 operator target and the hard-gate value is the p95 release value.

The operator report must record both statistics even though the release JSON records the p95 value used by the hard gate.

| Measurement | Target | Hard gate | Unit |
| --- | ---: | ---: | --- |
| Idle Oigo CPU | 0.2 | 0.5 | percent average |
| Idle Oigo physical footprint | 68,157,440 | 94,371,840 | bytes |
| Shortcut to recording state | 100 | 150 | milliseconds |
| First volatile transcript | 700 | 1,200 | milliseconds |
| Stop to raw final transcript | 750 | 1,500 | milliseconds |
| Stop to Clean insertion | 2,500 | 4,000 | milliseconds |
| Memory after processing | 10,485,760 | 15,728,640 | bytes over idle |
| Memory drift after 100 dictations | 10,485,760 | 20,971,520 | bytes over idle |
| Oigo-initiated network requests | 0 | 0 | requests |
| Lost recoverable recordings | 0 | 0 | recordings |

The byte values are the binary equivalents of 65 MB, 90 MB, 10 MB, 15 MB, and 20 MB.

The release check also requires evidence for Apple-managed model-service CPU, Apple-managed model-service physical footprint, and whole-system memory pressure.

Those three observations do not have a product budget in this issue, but an absent observation keeps the overall release result `INCONCLUSIVE`.

## Instrumentation contract

Production signposts use subsystem `com.oigo.app`, category `performance`, and payload-free names.

The required event names are:

```text
shortcut-received
session-persisted
audio-engine-start-begin
audio-engine-start-end
first-audio-buffer
first-volatile-result
recording-stopped
transcription-finalized
cleanup-start
cleanup-end
insertion-start
insertion-end
resources-released
```

Signposts contain event names only.

They never contain transcript text, audio bytes, file contents, target application contents, or user identifiers.

The lifecycle owner emits `resources-released` after it clears capture, descriptor, transcription, store, and operation references.

The transcription service emits the same event after it releases analyzer, stream, task, converter, session, and model-retention state.

Repeated markers from separate owners are expected and are not a resource count by themselves.

## Deterministic contract command

Run this command from the repository root:

```zsh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run oigo-issue11-performance-check
```

The command verifies the event catalog, exact target and hard budgets, explicit `INCONCLUSIVE` classification, and 100 cancellation cycles.

The command prints `GREEN: all issue #11 performance scenarios` when its deterministic checks pass.

The deterministic command does not claim that a host measured native Speech, Foundation Models, system-managed model services, or physical microphone behavior.

## Measurement input and release check

Create a sanitized JSON file outside the repository with one record for every measurement below.

The `note` field is optional and may contain only a short host limitation or measurement method.

It must not contain transcript text, audio paths, audio data, logs, credentials, or user identifiers.

```json
{
  "measurements": [
    {"measurement": "idle_cpu_percent", "status": "available", "value": 0.1},
    {"measurement": "idle_physical_footprint_bytes", "status": "available", "value": 65000000},
    {"measurement": "shortcut_to_recording_p95_ms", "status": "available", "value": 90},
    {"measurement": "first_volatile_transcript_p95_ms", "status": "available", "value": 600},
    {"measurement": "stop_to_raw_final_transcript_p95_ms", "status": "available", "value": 700},
    {"measurement": "stop_to_clean_insertion_p95_ms", "status": "available", "value": 2200},
    {"measurement": "memory_after_processing_delta_bytes", "status": "available", "value": 8000000},
    {"measurement": "memory_drift_after_100_dictations_bytes", "status": "available", "value": 9000000},
    {"measurement": "oigo_initiated_network_requests", "status": "available", "value": 0},
    {"measurement": "lost_recoverable_recordings", "status": "available", "value": 0},
    {"measurement": "apple_model_service_cpu_percent", "status": "inconclusive", "value": null, "note": "service process was not observable"},
    {"measurement": "apple_model_service_physical_footprint_bytes", "status": "inconclusive", "value": null, "note": "service process was not observable"},
    {"measurement": "whole_system_memory_pressure", "status": "available", "value": 0}
  ]
}
```

Run the complete release check with:

```zsh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./Scripts/issue11-release-check.sh /absolute/path/to/sanitized-measurements.json
```

The checker exits 0 for `PASS`, 1 for a hard-budget `FAIL`, 2 for `INCONCLUSIVE`, and 64 for invalid command usage.

The command prints only measurement identifiers, status values, and numeric values.

## Native benchmark procedure

Use a clean test account on the lowest supported test Mac with the supported microphone, Accessibility permission, and Speech assets already installed.

Do not use a production account or a corpus containing personal or confidential speech.

Create a temporary evidence directory before building:

```zsh
EVIDENCE_DIR="$(mktemp -d -t oigo-issue11-evidence.XXXXXX)"
DERIVED_DATA="$EVIDENCE_DIR/derived-data"
```

Build the exact app bundle from the reviewed commit:

```zsh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Oigo.xcodeproj \
  -scheme Oigo \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  build
APP="$DERIVED_DATA/Build/Products/Release/Oigo.app"
```

Capture the 30-minute idle run with the Time Profiler template:

```zsh
xcrun xctrace record \
  --template "Time Profiler" \
  --output "$EVIDENCE_DIR/idle-30m.trace" \
  --launch "$APP" \
  --time-limit 30m
```

Record Oigo CPU and physical footprint from the trace for the final 20 minutes after startup settles.

Record the Apple-managed model-service processes visible in the same trace.

Record whole-system memory pressure from the trace and the host memory-pressure surface.

For every dictation scenario, keep the spoken fixture synthetic and discard the recording after the measurement is extracted.

Use the default shortcut `Command-Option-Space` for a fresh profile by sending:

```zsh
osascript -e 'tell application "System Events" to key code 49 using {command down, option down}'
```

If the profile has a different shortcut, record the configured key action in the operator log without recording transcript content.

Measure shortcut-to-recording-state across at least 100 starts and report p50 and p95.

Measure first-volatile-result latency across at least 100 ten-second dictations and report p50 and p95.

Measure stop-to-raw-final-transcript across at least 10 five-minute dictations and report p50 and p95.

Measure stop-to-Clean insertion across at least 10 synthetic recordings of roughly 300 words and report p50 and p95.

Repeat the required measurements in Instant and Clean modes.

Repeat the lifecycle matrix with Foundation Models available and unavailable.

Repeat the lifecycle matrix after a microphone/device change, AirPods connect/disconnect, sleep/wake, screen lock/unlock, low-memory pressure, and force quit from every active state.

Run one 30-minute recording under profiling load and verify that the recoverable audio file remains present after a forced failure or quit.

Run 100 consecutive ten-second dictations and ten consecutive five-minute dictations.

Extract process memory after processing and after ten seconds of idle recovery.

Compare the final memory sample with the initial idle sample and the 100-dictation sample with the initial idle sample.

Run the network-disabled scenario only on a reversible air-gapped or firewall-isolated test boundary.

Do not change the workstation-wide proxy, firewall, or network route without a separately approved operator procedure.

If the app bundle, microphone permission, Apple-managed model service, physical device, sleep/lock interaction, or network-disabled boundary is unavailable, add an `INCONCLUSIVE` record and state the exact missing boundary in the operator report.

## Lifecycle release gates

After every session, inspect the exact-head trace and the deterministic contract result for all of the following:

- The audio input tap is removed.
- The audio engine is stopped and released.
- The analyzer input finishes or cancels.
- Result-consumer and analysis tasks end.
- The transcriber, analyzer, converter, and audio buffer references are released.
- Language-model sessions and model retention are released.
- HUD timers stop.
- No session-specific task survives into idle.
- Retention work is not polling.

The deterministic contract covers 100 cancellation cycles and checks the coordinator's active resource and task counts after each cycle.

The native trace and operator checklist cover the system-managed Speech and Foundation Models objects that deterministic fixtures cannot instantiate.

## Current evidence status for this checkout

The issue #11 deterministic event, budget, privacy-shape, and 100-cycle lifecycle checks are `PASS`.

The actual native CPU, physical footprint, latency, Apple-managed model-service, whole-system memory-pressure, 30-minute recording, physical-device, sleep/wake, lock/unlock, and network-disabled measurements are `INCONCLUSIVE` until the native benchmark procedure is run on the lowest supported test Mac with the required permissions and hardware.

No budget exception is recorded.

Any future exception must include measured values, the reason the lowest supported test Mac cannot meet the gate, and a link from issue #1 before the hard limit is changed.
