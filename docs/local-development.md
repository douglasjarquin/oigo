# Local app installation

Local builds use a persistent code-signing identity so macOS permissions survive rebuilds.
Use this workflow instead of ad-hoc signing or copying an unsigned build into Applications.

## One-time signing setup

With OpenSSL 3 available on PATH, run:

```zsh
Scripts/setup-oigo-local-signing.sh
```

This creates `Oigo Local` in the login keychain and trusts that certificate for code signing only.
The imported private key is non-extractable and access is limited to `codesign`.
Temporary certificate exports go to Trash after import.
Running setup again reuses the existing identity.
An existing but unusable identity causes an error rather than silently creating a replacement.

Alternatively, set `OIGO_CODESIGN_IDENTITY` to an existing code-signing identity's name or SHA-1 fingerprint.
Keep using the same identity for subsequent builds.

## Build and install

Quit Oigo, then run:

```zsh
Scripts/install-oigo-dev.sh
```

The installer builds an arm64 Release app, signs and verifies it, checks bundle contents, and installs it at `/Applications/Oigo.app`.
It refuses ad-hoc signing, refuses to replace a running app, and checks that a new signed build satisfies the installed signed app's identity requirement.
Previous app bundles are retained under the derived-data directory's `install-backups/` folder.

Open Oigo after installation.
When replacing an older ad-hoc build, approve Microphone and Accessibility once for the new stable identity.
Subsequent installations signed by the same identity should retain those approvals; verify that by rebuilding and repeating dictation before considering the local setup complete.
Do not reset permissions on every install.

This is local signing, not Developer ID distribution or notarization.
Use [the release procedure](release.md) for distributed builds.
