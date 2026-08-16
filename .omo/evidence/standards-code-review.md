# Standards code review

Scope: `git diff c8efe1e61ec2c019fbe5f71cdd0e252c48634600...4e51fbd86be984f1da6b74b7291f5eb1caee4538` and the 11 commits in `c8efe1e..4e51fbd`.

No tests were run, per review instructions.

## CRITICAL

None.

## HIGH

- **Hard documented-standard violation:** [Sources/Oigo/OigoAppDelegate.swift:305](/Users/douglasjarquin/.no-mistakes/worktrees/56226d202d19/01M04R4MP7VNKDGQZTPP6AHE05/Sources/Oigo/OigoAppDelegate.swift:305) passes the cleanup decision's `.clean` source to `InsertionService`; [Sources/Oigo/OigoAppDelegate.swift:539](/Users/douglasjarquin/.no-mistakes/worktrees/56226d202d19/01M04R4MP7VNKDGQZTPP6AHE05/Sources/Oigo/OigoAppDelegate.swift:539) exposes the same capability for re-paste. This conflicts with [docs/native-raw-insertion.md:7-13](/Users/douglasjarquin/.no-mistakes/worktrees/56226d202d19/01M04R4MP7VNKDGQZTPP6AHE05/docs/native-raw-insertion.md:7), which requires insertion to read the atomically persisted `raw.txt`, write that canonical raw text to the pasteboard, and synthesize Command-V only from it. The broadened `insertText(source:)` implementation at [Sources/OigoInsertion/InsertionService.swift:40](/Users/douglasjarquin/.no-mistakes/worktrees/56226d202d19/01M04R4MP7VNKDGQZTPP6AHE05/Sources/OigoInsertion/InsertionService.swift:40) makes the conflict systemic.

## MEDIUM

- **Judgement call - needless complexity / divergent responsibilities:** [Sources/OigoTranscription/TranscriptCleanup.swift:1](/Users/douglasjarquin/.no-mistakes/worktrees/56226d202d19/01M04R4MP7VNKDGQZTPP6AHE05/Sources/OigoTranscription/TranscriptCleanup.swift:1) is 832 pure LOC and owns chunking, deadline coordination, metrics, child-process lifecycle, worker protocol, Foundation Models access, and instruction text. This is material maintenance risk, not a documented-repository breach.
- **Slop-test judgement call:** [Tests/OigoIssue8ContractTests/main.swift:403](/Users/douglasjarquin/.no-mistakes/worktrees/56226d202d19/01M04R4MP7VNKDGQZTPP6AHE05/Tests/OigoIssue8ContractTests/main.swift:403) only validates static fixture fields and duplicate protected-token strings; it never exercises the production cleaner or establishes model-output correctness. It is implementation/data-mirroring coverage and provides false confidence.

## LOW

None.

Skill-perspective check: ran `programming` and `remove-ai-slops`. The diff violates the programming perspective on oversized single-responsibility modules and the slop perspective on needless production complexity and the fixture-only test above. No deletion-only, removal-only, or prompt-prose tests found. README.md contains no coding standard; the three requested native documents were reviewed.

Recommendation: REQUEST_CHANGES. Code-quality status: BLOCK.
