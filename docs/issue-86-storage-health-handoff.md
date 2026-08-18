# Issue #86 storage-health handoff to #12

This is a bounded handoff for the native validation work owned by #12.

It records storage-health evidence only and does not claim that the #12 release-validation matrix is complete.

The final PR receipt must bind these rows to one exact source SHA and the exact `Oigo.app` bundle path below.

| #12 handoff row | Result | Evidence | Limitation or follow-up |
| --- | --- | --- | --- |
| Durable bootstrap creates the root, constructs the store, recovers unfinished sessions, and enumerates History before the coordinator gate opens | PASS | `swift run oigo-issue86-contract-tests` and `swift build --product Oigo` at the final SHA | This is deterministic contract evidence, not proof of native microphone or Speech behavior. |
| Root file, root symlink, permission, unavailable-parent, write, recovery, unknown-I/O, malformed-child, retry, stale-completion, and relaunch rows | PASS | `Tests/OigoIssue86ContractTests/main.swift` failure matrix and recovery scenarios | Permission and disk-full rows use deterministic fakes; physical permission and disk conditions remain native #12 work. |
| Menu bar, Settings, and onboarding expose persistent storage health and Retry Storage behavior | INCONCLUSIVE | Exact bundle path: `/var/folders/3l/lr4pf_3d1_b0_ck7_783c8540000gp/T/oigo-issue86-native-final/Oigo.app` | Computer Use Accessibility and Screen Recording permissions were unavailable, so no AX tree or screenshot is treated as proof. |
| Native launch and bundle identity for the reviewed candidate | INCONCLUSIVE | The exact bundle is checked with `plutil -lint Oigo.app/Contents/Info.plist` and `file Oigo.app/Contents/MacOS/Oigo` before the native probe. | The host did not return a usable native AX or screenshot receipt. |
| Microphone, Speech assets, TCC, Accessibility, Input Monitoring, and target-application surfaces | INCONCLUSIVE | No permission, shared configuration, daemon, or target-application mutation was attempted. | #12 must run these rows on its designated clean test Mac and record each unavailable boundary explicitly. |

The deterministic rows expose only stable categories and non-content counts.

They do not include transcript text, audio, session paths, credentials, or user identifiers in ordinary diagnostics.

The native rows remain `INCONCLUSIVE` until #12 supplies the required permissioned host evidence.
