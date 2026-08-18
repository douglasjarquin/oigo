# Issue #86 storage-health handoff to #12

This is a bounded handoff for the native validation work owned by #12.

It records storage-health evidence only and does not claim that the #12 release-validation matrix is complete.

Reviewed implementation SHA before this handoff-only update: `5bc67fede27c369f990c1ceb0abab33f5b20331c`.

The final PR receipt must bind these rows to one exact final source SHA and the exact `Oigo.app` bundle path below.

| #12 handoff row | Result | Evidence | Limitation or follow-up |
| --- | --- | --- | --- |
| Durable bootstrap creates the root, constructs the store, recovers unfinished sessions, and enumerates History before the coordinator gate opens | PASS | `swift run oigo-issue86-contract-tests` and `swift build --product Oigo` at the final SHA | This is deterministic contract evidence, not proof of native microphone or Speech behavior. |
| Unavailable root first launch | PASS deterministic | `Tests/OigoIssue86ContractTests/main.swift` root and unavailable-parent fakes | The physical unavailable-root app launch remains `INCONCLUSIVE` for #12 until the designated host can run it safely. |
| Root file and root symlink identity violation | PASS deterministic | Root identity matrix and direct `SessionStore` construction rejection | The exact native bundle row remains `INCONCLUSIVE` without permissioned native evidence. |
| Permission denied, insufficient space/write failure, recovery failure, and unknown I/O classification | PASS deterministic | Stable category matrix, fault-injected bootstrap write probe, and recovery fakes | Physical permission and disk-full rows remain native #12 work. |
| Repair followed by explicit Retry Storage without relaunch | PASS deterministic | Retry-success, coalescing, generation-fencing, and relaunch scenarios | The native menu/Settings/onboarding Retry action remains `INCONCLUSIVE` without AX/UI evidence. |
| Existing valid History plus one malformed child | PASS deterministic | Malformed-child isolation, symlink-child rejection, count-only report, and relaunch scenarios | The native History surface remains `INCONCLUSIVE` without AX/UI evidence. |
| No recorder, Speech, cleanup, or insertion dependency is reached before the persisted session metadata boundary | PASS deterministic | Production `OigoAppDelegate` enters through `DurableSessionCapability.withHealthyStore`; the issue-86 unhealthy dependency counter scenario and persisted-session coordinator seam pass | Native capture/Speech/insertion no-reach evidence remains `INCONCLUSIVE` without a permissioned host. |
| Metadata write failure before capture | PASS deterministic | Fault-injected bootstrap write probe and no-artifact cleanup assertion | The physical disk/permission failure row remains native #12 work. |
| Menu bar, Settings, and onboarding expose persistent storage health and Retry Storage behavior | INCONCLUSIVE | Exact bundle path: `/var/folders/3l/lr4pf_3d1_b0_ck7_783c8540000gp/T/oigo-issue86-native-final/Oigo.app` | Computer Use Accessibility and Screen Recording permissions were unavailable, so no AX tree or screenshot is treated as proof. |
| Native launch and bundle identity for the reviewed candidate | INCONCLUSIVE | The exact bundle is checked with `plutil -lint Oigo.app/Contents/Info.plist` and `file Oigo.app/Contents/MacOS/Oigo` before the native probe. | The host did not return a usable native AX or screenshot receipt. |
| Microphone, Speech assets, TCC, Accessibility, Input Monitoring, and target-application surfaces | INCONCLUSIVE | No permission, shared configuration, daemon, or target-application mutation was attempted. | #12 must run these rows on its designated clean test Mac and record each unavailable boundary explicitly. |

The deterministic rows expose only stable categories and non-content counts.

They do not include transcript text, audio, session paths, credentials, or user identifiers in ordinary diagnostics.

The native rows remain `INCONCLUSIVE` until #12 supplies the required permissioned host evidence.
