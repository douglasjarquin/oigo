# Native menu-bar shell

Oigo is a single arm64 macOS 26 application process built from AppKit.
The application uses `NSApplication` with accessory activation policy and `LSUIElement` so it does not appear in the Dock during normal operation.
The status item menu contains Start Dictation or Stop Dictation, the current global shortcut status, Settings…, and Quit Oigo.
The global shortcut is registered with the public Carbon `RegisterEventHotKey` API for both pressed and released edges.
The keyboard path starts one operation on the first press and finishes that same operation on release.
Repeats and duplicate edges are ignored by the intent controller.
Release during microphone, Speech, or audio startup is latched until the coordinator reaches recording.
Keyboard release never cancels or discards the operation.
The Start Dictation and Stop Dictation menu item remains a mouse-driven toggle and does not claim keyboard ownership.
The keyboard callback updates a nonactivating status surface and does not make Oigo frontmost.
Oigo does not install a global or local event monitor, use private APIs, or launch a helper process for shortcut input.

## Coordinator

`DictationCoordinator` owns the only mutable state-machine instance.
The explicit states are idle, preparing, recording, finalizing, cleaning, inserting, complete, failed, cancelled, and interrupted.
The reducer publishes a finite legal-transition table and rejects every event outside that table.
The coordinator accepts at most one active task and cancels it during application termination.
Audio capture, speech recognition, and cleanup services are attached on demand without changing the shell contract.
Issue #6 attaches raw transcript insertion through a separate target-safe service.

## Status surface

The status panel uses an `NSPanel` with the nonactivating-panel style.
It reports the current coordinator state or insertion outcome with `orderFront` and never calls `NSApp.activate`.
The shortcut callback therefore updates the status surface without making Oigo the frontmost application.

## Idle baseline

The issue #3 budget is a maximum of 0.5% average CPU and 90 MB physical footprint before audio and model work is connected.
The implementation has no recurring idle timer, no idle network client, no daemon, no XPC or login helper, and no third-party runtime dependency.
Processing services are represented as on-demand boundaries and are not instantiated during application launch.

The local host is arm64 macOS 26.6.1 with Swift 6.3.3.
The baseline Swift build and the existing feasibility contract harness passed before this implementation.
The issue #3 contract harness passed all legal transitions, illegal-transition rejection, shortcut toggling, single-task cleanup, all-state shutdown, and idle-policy scenarios.
A real seven-sample idle run at five-second intervals measured 0.0% CPU and 11M to 12M reported process memory for the Oigo process.
A native 30-minute GUI CPU and footprint measurement is not verified on this host because only Command Line Tools are installed and `xcodebuild` is unavailable.
The 30-minute GUI measurement remains a human or Xcode-host acceptance check before release.
