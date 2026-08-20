# Branch protection (repository-admin handoff)

This worktree cannot apply GitHub branch-protection settings.
A repository administrator must configure `main` before v1 release.

Issue #101's in-repo CI change is complete once these GitHub settings exist.
Until then, treat protection as an open human step rather than a merged guarantee.

## Required `main` settings

- Require a pull request before merging.
- Require the status checks named exactly:
  - `Swift build and contract harness`
  - `Xcode app bundle`
- Require branches to be up to date before merging, or adopt a merge queue.
- Block force pushes.
- Block branch deletion.
- Do not allow administrators to bypass required checks for v1 release changes.

`Swift build and contract harness` is the canonical deterministic SwiftPM suite.
`Xcode app bundle` is the separate unsigned Release `Oigo.app` build and inspection.
A green package job is not app-bundle validation.

Ordinary CI uses no Developer ID or notarization secret.
Signing and notarization remain issue #14.

## Proof

Prove the policy with:

1. One intentionally failing PR that cannot merge.
2. A corrected green PR that can merge.
3. The merged `main` SHA's own recorded `verify` run, which must not be cancelled.

## Downstream reuse

Issue #12 must pin that `main` SHA and the Release `Oigo.app` from the `oigo-app-<checked-out-sha>` artifact uploaded by `Xcode app bundle`.
If a Developer ID signed candidate is required, issue #14 builds it from the same Xcode contract rather than substituting a SwiftPM executable.
Hosted CI does not replace native TCC, Speech, Accessibility, hardware, or clean-account dogfood proof.
