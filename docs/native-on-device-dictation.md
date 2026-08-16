# Native on-device dictation feasibility

Status: conditional follow-up only.

## Tested environment

The live host is an Apple M4 Pro MacBook Pro with 14 cores and 24 GB of memory.

The host runs macOS 26.6.1 build 25G76 on arm64.

The available compiler is Apple Swift 6.3.3 targeting `arm64-apple-macosx26.0`.

The active developer directory is Command Line Tools at `/Library/Developer/CommandLineTools`.

Full Xcode is not selected, so `xcodebuild` is unavailable on this host.

The SDK contains the macOS 26 Speech and Foundation Models interfaces required by the spike.

## APIs evaluated and selected

The selected Speech path is `SpeechAnalyzer` with `DictationTranscriber.progressiveLongDictation`.

`DictationTranscriber` was selected over `SpeechTranscriber` because its public macOS 26 API provides long-dictation presets, progressive results, frequent finalization, punctuation, and audio-time-range attributes.

`AVAudioEngine` input taps feed the same `AnalyzerInput` buffers to `SpeechAnalyzer` and an `AVAudioFile` CAF writer.

Saved audio is opened through `SpeechAnalyzer` file input for retry.

`FoundationModels.LanguageModelSession` is an optional strict cleanup pass.

`AnalysisContext.contextualStrings` is populated with the benchmark terms `Consigliere`, `n8n`, `Claude Code`, and `ChatGPT` without changing recognition terminology.

The spike emits signposts for recording start, first audio buffer, first volatile result, final result, cleanup, and resource release.

## Permission and asset-installation behavior

The explicit asset-installation scenario completed with `asset_installation_status=installed`.

The post-install capability probe reported `speech_assets=installed` and `speech_installed_locales=en_US`.

The same probe reported `microphone_permission=granted`, but lldb observed the same command-line executable as `AVAudioApplicationRecordPermission(rawValue: 1970168948)` (`undt`).

The command-line executable reports `host_bundle_identifier=none`.

The live path now fails closed before opening audio when no application bundle identifier is present.

This prevents the intermittent post-install signal 133 observed from the bare command-line host, which produced a 4096-byte CAF on failing runs.

The spike does not silently download Apple-managed assets and does not request microphone permission during capability inspection.

The live path requires an app host with `NSMicrophoneUsageDescription` and a user-granted microphone permission.

Evidence: `/Users/douglasjarquin/.codex/evidence/oigo-issue-2/capabilities-final-v2.txt`, `/Users/douglasjarquin/.codex/evidence/oigo-issue-2/lldb-live-repro.txt`, and `/Users/douglasjarquin/.codex/evidence/oigo-issue-2/live-host-guard-final-v2.txt`.

## CI verification boundary

Pull requests run SwiftPM compilation, the Oigo product build, and the spike plus issue #3 through issue #8 contract harnesses on a macOS 26 GitHub Actions runner through `.github/workflows/verify.yml`.

This check intentionally uses SwiftPM and does not invoke `xcodebuild`.

The CI check proves SwiftPM compilation, the Oigo product build, and the deterministic contract harnesses only.

It does not remove the local Command Line Tools-only limitation described above, and it does not claim to validate live microphone/TCC behavior from an application bundle, Apple Intelligence availability, network-disabled Speech execution, or native Speech/Foundation Models resource measurements.

## Accuracy observations

The direct native path captured playable CAF files on successful runs, but emitted no transcript text during the controlled three-second captures.

The guarded final live run reports the exact limitation, `native live capture requires an application bundle identifier`, and writes no CAF.

The required short prompts, long architecture explanations, identifiers, pauses, corrections, benchmark terms, and 30-minute recording remain unmeasured.

No terminology corrections were added.

## Latency and resource measurements

The deterministic transcript and resource harness completed 20 repetitions with a maximum resident-memory delta of 933888 bytes and reported `deterministic_state_bounded=true`.

That result covers the journal, transcript, fallback, and measurement state only.

Native Speech and Foundation Models object release, meaningful idle CPU, Apple model-service activity, whole-system memory pressure, first-result latency, finalization latency, and long-form accuracy remain unmeasured.

The exact resource evidence is `/Users/douglasjarquin/.codex/evidence/oigo-issue-2/resource-measurement-final-v2.txt`.

## Failure and retry results

The failure scenario wrote a playable 1600-frame CAF before a forced live recognition failure.

The saved-file retry reopened the CAF and returned `retry-ready frames=1600`.

The contract harness independently passed the same recovery assertion.

Evidence: `/Users/douglasjarquin/.codex/evidence/oigo-issue-2/failure-retry-final-v2.txt`, `/Users/douglasjarquin/.codex/evidence/oigo-issue-2/final-contract-tests-v2.txt`, and `/Users/douglasjarquin/.codex/evidence/oigo-issue-2/cleanup-timeout-contract-final.txt`.

The real Foundation Models cleaner returned `unavailable(...appleIntelligenceNotEnabled)` and retained the raw transcript for display.

The cleaner now has a bounded timeout path, but timeout execution is unverified because the model is unavailable on this host.

Actual Speech retranscription after a live recognition failure remains unverified because this CLI host has no application bundle identifier and the guarded path refuses to start SpeechAnalyzer.

Evidence: `/Users/douglasjarquin/.codex/evidence/oigo-issue-2/transcript-cleanup-final-v2.txt`.

## Offline result

The Oigo source path contains no network client and the offline scenario reported `network_requests=0` and `oigo_network_client=none`.

The offline command itself did not disable the host network, so it cannot prove the required network-disabled runtime boundary.

Therefore the strict acceptance criterion requiring the complete path with networking disabled after asset installation is unverified.

Evidence: `/Users/douglasjarquin/.codex/evidence/oigo-issue-2/offline-final-v2.txt` and `/Users/douglasjarquin/.codex/evidence/oigo-issue-2/capabilities-final-v2.txt`.

## Recommendation

NO-GO for production UI investment from this run.

The code spike is a viable follow-up harness and the selected production candidate is `DictationTranscriber.progressiveLongDictation` behind `SpeechAnalyzer`.

Before a production decision, run the live path from an app bundle with microphone usage text, install and verify Apple-managed Speech assets, capture the full benchmark corpus including one 30-minute recording, disable networking at the host boundary, and measure native object release and latency.

The roadmap should keep terminology baseline comparison in #13 and should not add a custom dictionary or terminology fixes in this spike.
