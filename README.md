# Oigo

Oigo 1.0.0 is a menu-bar dictation app for macOS 26 or later on Apple silicon.

It records durable local audio, transcribes on-device with Apple Speech, optionally applies Clean, can normalize a custom dictionary, and copies or pastes the result.

macOS 13 through 25 are not supported.
Intel Macs are not supported.

## Website

The product site lives in `site/` and is published from `main` to <https://douglasjarquin.github.io/oigo/> by `.github/workflows/site.yml`.
Its web design system is documented in `DESIGN.md`; the native AppKit design system remains `design/docs/design-system.md`.

## Install

Install a notarized `Oigo.app` from the v1 download, not from this source tree.

1. Open the ZIP and drag `Oigo.app` to `/Applications`.
2. Open Oigo.
3. Complete onboarding.
4. Grant Microphone access when asked.
5. Grant Accessibility access if you want automatic paste.
6. Confirm that Apple-managed speech assets for your dictation language are installed.

See `INSTALL.txt` in the download for the short version of this list.

## What Oigo does

Oigo lives in the menu bar.
Press and hold the global shortcut, or use Start Dictation in the menu, to record.
Oigo writes audio to a local session, runs on-device Speech, then copies the transcript and pastes it when Accessibility checks pass.

Instant mode inserts the recognized transcript after local dictionary normalization.
Clean mode can rewrite that transcript on this Mac with Apple Foundation Models when they are available.

History keeps durable recordings and transcripts so you can copy, paste again, or retry a failed transcription from saved audio.

## On-device and offline

Oigo initiates no network requests.
It has no account and no Oigo-operated service.

Apple-managed Speech and Foundation Models assets are separate macOS system services.
They are not Oigo network clients.
macOS may install or refresh those assets on its own.

After the required speech assets for the selected locale are present, Oigo is intended to work with networking disabled.

## Speech assets

The selected dictation language needs Apple-managed on-device speech assets.
If those assets are missing, installing, or failed, Oigo tells you during onboarding and in Settings.
Install them from the language picker or System Settings, then retry.

Instant mode does not require Foundation Models.
Clean mode does.

## Permissions

Microphone permission is required to record.

Accessibility permission is required to paste into the app you were using.
Without Accessibility, Oigo still copies the transcript and keeps History.

Oigo asks for these permissions during onboarding and can reopen System Settings from Settings.

## Instant vs Clean

Instant is the default.
It transcribes on-device and inserts the normalized transcript without Apple Intelligence.

Clean is optional.
It still transcribes on-device, then asks Foundation Models to rewrite the transcript on this Mac.
If Clean is unavailable, Oigo falls back to the Instant transcript instead of blocking dictation.

## Recordings, History, retry, and retention

Every dictation is a durable local session under Application Support/Oigo.
History lists those sessions.

You can copy a transcript, paste again, or retry transcription from saved audio when the recording is still present.

Settings control how long audio is kept: 1 day, 1 week, 1 month, or 3 months.
You can also keep successful audio indefinitely.
Delete All History removes saved sessions, recordings, and transcripts.
It does not delete the custom dictionary.

## Custom Dictionary

The dictionary is local terminology, not a downloaded language pack.
You add canonical spellings and aliases.
Oigo supplies those terms to Speech as context and applies deterministic normalization after recognition.

The dictionary is empty until you add terms.
Starter technology terms are optional and are not preloaded.

Example: add `Consigliere` as the canonical spelling, with aliases such as `consiliary` or `con silly air`.
Oigo then prefers `Consigliere` in new transcripts.
Historical transcripts are not rewritten until you choose Reapply Dictionary.

The file is `~/Library/Application Support/Oigo/custom-dictionary.json`.

## Insertion limitations

Automatic paste is one Command-V after Accessibility checks pass.

Secure fields never receive automatic paste.
If the focused app or field changes, or the field cannot accept a paste, Oigo copies the transcript and leaves it on the clipboard.
Copy and History remain available.

Paste is one-shot per session.
Oigo does not restore the previous clipboard contents.

## Language and model limitations

Recognition quality is Apple's on-device Speech model for the selected locale.
Oigo cannot add a custom acoustic model.

The dictionary can correct known terms after recognition.
It cannot invent support for an unsupported language.

Clean depends on Apple Intelligence / Foundation Models on this Mac.
When those models are unavailable, Instant still works.

## Deferred

These are explicitly out of v1:

- pausing or resuming other media during dictation
- Mac App Store distribution
- automatic updates
- Intel or universal binaries

## Data locations

- Recordings and transcripts: `~/Library/Application Support/Oigo/Sessions/`
- Custom dictionary: `~/Library/Application Support/Oigo/custom-dictionary.json`
- Settings: UserDefaults key `oigo.settings.v1`

## Export, delete, and uninstall

Settings includes Export Diagnostics.
That JSON is versions, settings categories, state codes, and counts.
It does not include transcripts, dictionary contents, audio, clipboard data, focused-element text, or user file paths.

Delete All History removes saved sessions only.

To uninstall:

1. Quit Oigo from the menu bar.
2. Delete `Oigo.app`.
3. Optionally delete `~/Library/Application Support/Oigo`.
4. Optionally remove the `oigo.settings.v1` defaults key.
5. Turn off Launch at Login in System Settings > General > Login Items if it remains.

## Privacy

See [docs/privacy.md](docs/privacy.md).

The short version: no account, no Oigo-operated service, no transcript upload, and no Oigo-initiated network traffic.

## Release packaging

See [docs/release.md](docs/release.md) for the local Developer ID, notarization, and artifact procedure.
Hosted CI builds unsigned Release `Oigo.app` and does not sign or notarize.

## Verify

```zsh
swift build
swift build --product Oigo
swift run oigo-macos-floor-check
```

`oigo-macos-floor-check` fails unless SwiftPM, Info.plist, and every Xcode configuration declare exactly `26.0`.

`.github/workflows/verify.yml` runs on pull requests, every push to `main`, and `workflow_dispatch` of an exact git ref.

The `Swift build and contract harness` job is the deterministic SwiftPM suite.
The `Xcode app bundle` job builds and inspects unsigned Release `Oigo.app`.
A green package build is not app-bundle validation.
Hosted CI does not prove native TCC, Speech, Accessibility, hardware, signing, or clean-account dogfood.

See `docs/branch-protection.md` for the repository-admin protection handoff that this worktree cannot apply.
