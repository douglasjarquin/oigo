# Oigo UI redesign — handoff for implementation

Design deliverables in this project (open in a browser; all clickable, Light/Dark):
- `Oigo Icon.dc.html` — ear-O mark (primary = one continuous stroke reading O·G·ear), app-icon squircles, menu-bar template states.
- `Popover + HUD Prototype.dc.html` — daily experience: popover composition, full dictation phase progression, 7 health scenarios, HUD states, field-relative placement.
- `State Boards.dc.html` — every HUD state with dismissal notes, all inline notices, status-item states.
- `Onboarding.dc.html` — 4 stages + completion, locale gating, transactional shortcut, truthful end-to-end test checklist.
- `Settings.dc.html` — 4 panes, truthful Launch at Login, pinned-unavailable mic, Dictionary split editor (#13), delete sheet.
- `History.dc.html` — split view, 8 status archetypes, version availability, More menu, truthful Play/Stop.
- `docs/design-system.md`, `docs/screen-map.md`, `docs/ui-state-matrix.md`.

## Issue → surface mapping
| issue | surface |
|---|---|
| #13 Dictionary | Settings › Dictionary pane (design complete; implement only when Ready; never ship dead UI) |
| #79 truthful onboarding test | Onboarding stage 4 checklist + distinct outcomes |
| #83 bounded maintenance | no prominent manual maintenance in Data & Privacy |
| #84 truthful terminal outcomes | HUD terminal states + History status vocabulary + state matrix |
| #90 multichannel input | channel row in popover mic path, onboarding stage 2, Dictation pane |
| #92 truthful playback | History single Play/Stop, natural completion without polling |
| #97 degraded live transcription | Retry-required states across HUD/popover/History |
| #102 unified operation gate | OigoPresentationState adapter; all availability derives from it |
| #103 Launch at Login truth | General pane 5-state presentation + approval route |
| #105 language asset readiness | onboarding locale gating, Dictation pane asset row, popover notice |
| #106 immutable per-dictation config | "Applies to the next dictation" captions (popover + Settings) |
| #108 bounded History loading | list pagination, Load More, generation fencing, detail loaded independently |

## Implementation notes
- Architecture split per brief: Sources/MacUtilityUI (generic, AppKit+Foundation only) / Sources/Oigo/UI (copy, composition, presentation adapter). Adapter consumes authoritative models; it is not a second state machine.
- Verify against the repo's open issue statuses before implementing issue-owned behavior; design here covers unauthorized surfaces without shipping them.
- Phases per brief: 0 audit (`docs/ui-audit.md` from real sources) → 1 generic layer → 2 popover+HUD → 3 onboarding+settings → 4 history → 5 accessibility/lifecycle/perf.
- Copy style: short, operational, truthful ("Paste attempted", "Recording saved", "Applies to the next dictation"). Never "Success!"/"Oops!".

## Boundaries / INCONCLUSIVE
- These are HTML design prototypes, not AppKit measurements: idle CPU, footprint, launch-to-menu, HUD latency, History first-page latency, main-thread stalls are INCONCLUSIVE until measured on a native host.
- `docs/ui-audit.md` and `docs/ui-performance.md` require the actual repository/build host and are left to implementation.
- HUD positioning fallback order and Paste Again handoff are specified in screen-map.md but need Accessibility-API validation on device.
