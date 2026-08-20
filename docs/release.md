# Release procedure

This is the local v1.0.0 packaging path.
Hosted CI stays unsigned.
This repository must not contain certificates, notary API keys, keychain profiles, or other credentials.

The current display version is `1.0.0` (`CFBundleShortVersionString`).
The current build number is `1` (`CFBundleVersion`).
The bundle identifier is `com.oigo.app`.

## What this host cannot do

Signing, notarization, stapling, and Gatekeeper checks require a Mac with a Developer ID Application certificate and notary credentials.
This procedure documents those operator steps.
It does not close them.

Do not create git tag `v1.0.0` or a GitHub Release until those native steps pass.

## Required environment

The release script reads credentials only from the environment.
It never prints secret values.

Required:

- `OIGO_CODESIGN_IDENTITY` - Developer ID Application identity, for example `Developer ID Application: Example Inc (TEAMID)`

Notarization requires one of:

- `OIGO_NOTARY_PROFILE` - a `notarytool` keychain profile name
- or all three of `OIGO_NOTARY_KEY`, `OIGO_NOTARY_KEY_ID`, and `OIGO_NOTARY_ISSUER`

Optional:

- `OIGO_RELEASE_DIR` - output directory, default `dist`
- `OIGO_DERIVED_DATA` - xcodebuild derived data path

If those credential variables are unset, `Scripts/package-oigo-release.sh` exits non-zero, lists the missing variable names, and does not contact the network.

## Package

```zsh
zsh Scripts/package-oigo-release.sh
```

The script:

1. Fails immediately when credentials are missing.
2. Builds arm64 Release `Oigo.app` with `CODE_SIGNING_ALLOWED=NO`.
3. Signs every Mach-O and the app bundle with Developer ID, hardened runtime, and `Oigo/Oigo.entitlements`.
4. Submits a ZIP to Apple notarization and waits.
5. Staples the ticket to `Oigo.app`.
6. Rejects the artifact if it contains development-only paths such as `Tests/`, `.build/`, or sample transcripts.
7. Writes `Oigo-1.0.0-arm64.zip` containing `Oigo.app` and `INSTALL.txt`.
8. Writes a SHA-256 checksum next to the ZIP.

`Oigo/Oigo.entitlements` is for this local sign step.
Do not enable `CODE_SIGNING_ALLOWED` in the Xcode project.
Unsigned CI must keep passing `CODE_SIGNING_ALLOWED=NO`.

## After the ZIP exists

Remaining operator steps, in order:

1. Confirm the stapled ticket with `stapler validate`.
2. Copy the ZIP to a clean Mac user account that has never run Oigo.
3. Open the app through Gatekeeper without bypassing it.
4. Complete onboarding, dictate, paste, recover a failed recording, and add a custom dictionary term.
5. Re-run issue #11 performance and issue #12 quality checks against this signed artifact.
6. Keep a backup of the ZIP and `.sha256` file.
7. Only then tag `v1.0.0` and create the GitHub Release.

## Entitlements

Production signing uses:

- `com.apple.security.device.audio-input`
- `com.apple.security.automation.apple-events`

Microphone and Accessibility remain TCC permissions, not Xcode code-sign flags.
