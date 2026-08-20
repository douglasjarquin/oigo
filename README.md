# oigo

Oigo is a menu-bar dictation app for macOS 26 or later on Apple silicon.

macOS 13 through 25 are not supported.

## Verify

```zsh
swift build
swift build --product Oigo
swift run oigo-macos-floor-check
```

`oigo-macos-floor-check` reads `Package.swift`, `Oigo/Info.plist`, and `Oigo.xcodeproj/project.pbxproj` and fails if the floor drifts below macOS 26.0.

`.github/workflows/verify.yml` runs on pull requests, every push to `main`, and `workflow_dispatch` of an exact git ref.

The `Swift build and contract harness` job is the deterministic SwiftPM suite.
The `Xcode app bundle` job builds and inspects unsigned Release `Oigo.app`.
A green package build is not app-bundle validation.
Hosted CI does not prove native TCC, Speech, Accessibility, hardware, signing, or clean-account dogfood.

See `docs/branch-protection.md` for the repository-admin protection handoff that this worktree cannot apply.
