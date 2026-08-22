# Task 12 final non-visual validation

## Focused exhaustive contract

Scenario: exhaustive 23-row presentation matrix.

Invocation: `swift run oigo-native-ui-contract-tests --scenario popover-state-matrix --fixture exhaustive`, run twice.

Binary observable: both runs exited 0 and emitted `MATRIX rows=23 unique=23 sections=7 width=340 scroll=false`, `PASS popover-state-matrix resources=0 reads=metadata-only`, typed System Settings recovery, shortcut-only start enabled, copy-only Accessibility readiness, unavailable pinned input preservation, and typed busy/shutdown reasons.

Artifacts: `exhaustive-run-1.sanitized.log`, `exhaustive-run-2.sanitized.log`, and `exhaustive-determinism.status`.

## Adversarial contract

Scenario: malformed state, unmapped row, stale generation, dirty worktree, flaky intrinsic sizing, bounded hung command, misleading success output, and repeated interruption.

Invocation: the focused command above with fixtures `malformed-state`, `missing-row`, `stale-generation`, `dirty-worktree`, `flaky-intrinsic`, `hung-command`, `misleading-success`, and `repeated-interruption`.

Binary observable: every fixture exited 64 with its typed rejection category; the misleading-success decoy did not produce a successful process status.

Artifacts: `adversarial-*.log`, `adversarial-*.status`, and `adversarial-summary.status`.

Prompt injection is not applicable because fixtures are typed and synthetic.

## Routing, ownership, and bounded open

Scenario: primary, secondary, and control-click routing with teardown.

Invocation: `swift run oigo-native-ui-contract-tests --scenario popover-routing --defaults-suite com.oigo.qa.task11 --fixture-root "$TASK_TMP/fixtures"`.

Binary observable: exit 0 with three exclusive routes, the exact utility menu, stale publication fencing, and `resources=0`.

Artifact: `task11-routing.log`.

Scenario: authoritative mapper, bounded open dependencies, typed System Settings routing, and close teardown.

Invocation: repository-scoped `rg` assertions over the production presentation, controller, gallery, and app delegate sources.

Binary observable: one `OigoPresentationState.project` mapper, no gallery mapper, no transcript/audio/dictionary/network/global-monitor/operation-gate dependency in popover open paths, typed System Settings URL dispatch, and explicit popover/menu close paths.

Artifact: `structural-contracts.log`.

## Build and linkage

Scenario: SwiftPM Oigo and OigoUIGallery products.

Invocation: `swift build --product Oigo` and `swift build --product OigoUIGallery`.

Binary observable: both exited 0 with complete product builds.

Artifacts: `swift-build-oigo.log`, `swift-build-gallery.log`, and `swift-builds.status`.

Scenario: isolated Debug Oigo and OigoUIGallery Xcode builds.

Invocation: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Oigo.xcodeproj -scheme <SCHEME> -configuration Debug -derivedDataPath "$TASK_TMP/<DERIVED_DATA>" CODE_SIGNING_ALLOWED=NO build` for schemes `Oigo` and `OigoUIGallery`.

Binary observable: both exited 0, emitted `** BUILD SUCCEEDED **`, built their app artifact, declared the OigoPresentation dependency, and linked OigoPresentation plus MacUtilityUI.

Artifacts: `xcode-build-summary.log`, `xcode-oigo.status`, `xcode-gallery.status`, and `xcode-cleanup.status`.

Scenario: project syntax and source membership.

Invocation: `plutil -lint Oigo.xcodeproj/project.pbxproj` and `python3 Scripts/check-xcode-source-membership.py .`.

Binary observable: project file `OK` and `GREEN: declared sources and production resources match Xcode targets`.

Artifact: `source-membership.log`.

## Visual gate

Status: WAIVED BY USER.

Manual follow-up: inspect the native popover before merging.

Artifact: `visual-native-evidence.md`.
