# Oigo screen map

No permanent dashboard window. Five primary surfaces; sheets/alerts/menus for everything else.
Dictionary lives in Settings. Playback lives in History. Storage repair: inline notices + Settings. Permission recovery: onboarding, inline notices, Settings. Diagnostics export: Data & Privacy.

## 1. Menu-bar item + popover — `Popover + HUD Prototype.dc.html`
- Open: primary click on status item. Secondary click: small NSMenu (Settings, History, Quit).
- NSPopover, transient, 340 pt wide, content-driven height, no scrolling when healthy.
- Composition: header (Oigo + state label) → primary action + shortcut hint → Mode segmented / Microphone row → inline health notice (unhealthy only, one at a time) → Last dictation (metadata only: relative time, duration, status, source; Copy / Paste Again) → footer (History, Settings…, Quit).
- Variants: Ready · Recording (Stop) · processing phases (disabled primary) · each health notice (storage, shortcut, mic, assets, accessibility copy-only, retry) · mode-changed-while-active ("Applies to the next dictation").

## 2. Recording HUD — same prototype + `State Boards.dc.html`
- Nonactivating borderless NSPanel; never key/main; joins all Spaces; no interactive controls; no waveform.
- 210–280 × 42–64 pt, radius 12. Positioned 8–12 pt below the target field (above if no room; clamped to visible frame; app-window edge → bottom-center of target screen as fallbacks). Repositions only on explicit target/display events.
- States: Preparing… · Recording (red dot, 1 Hz mono timer, "Release ⌥Space to finish", optional one-line preview) · Finalizing… · Cleaning… · Pasting… · Paste attempted · Copied to Clipboard · Recording Saved — Retry Needed · Failed — Recording Preserved · Cancelled · Interrupted.
- Dismissal: active states persist; ordinary terminal ~1.5–2 s; retry/preserved ~3 s. Stale generation never replaces a newer HUD.

## 3. Onboarding — `Onboarding.dc.html`
- Titled window, 640 pt wide. 4 stages + completion; Back/Continue footer; Escape safe-cancels.
- 1 Mac & Storage (status rows; storage failure blocks with Retry / Open Data Location) · 2 Microphone & Language (permission, device/channel picker, stage-scoped level meter, locale-gated Continue) · 3 Shortcut & Insertion (transactional recorder, accessibility optionality) · 4 Try It (real Oigo-owned field, 9-step checklist, outcomes: Automatic paste verified / Copy-only accepted / Test skipped / Failed at named stage) · Done (summary rows).

## 4. Settings — `Settings.dc.html`
- ⌘, · noncustomizable toolbar panes: General, Dictation, Dictionary, Data & Privacy. 720 pt wide, restores last pane, no global Save; transactional/immediate commits with inline failure.
- General: shortcut, Launch at Login (truthful: Enabled/Disabled/Requires Approval/Not Found/Unknown), HUD preview toggle, re-run onboarding.
- Dictation: mode, microphone (pinned-unavailable shown, never substituted), channel, language + asset state, retention.
- Dictionary (#13, when authorized): split editor — terms list / canonical, locale, enabled, aliases, test normalization. Hidden until functional.
- Data & Privacy: permission rows, storage health, Open History / Data Folder, retention summary, diagnostics export, Delete All History (sheet confirm, separate from dictionary).

## 5. History — `History.dc.html`
- Split view 1000×640 pt (min ~880). Toolbar: Copy, Paste Again, Play/Stop, More menu (Copy Raw, Clean Again, Reapply Dictionary, Retry Transcription, Reveal in Finder, Delete Session).
- List rows: time, one-line bounded summary, duration, one status icon+label. Bounded off-main-actor pages, Load More, stale-generation fencing. No transcript bodies for unselected rows.
- Detail: metadata, truthful outcome + explanation, Raw/Normalized/Clean segmented (existing versions only), selectable read-only transcript loaded independently.
- Paste Again: copy → deactivate History → HUD "Choose a destination" → bounded handoff → validate → single dispatch → truthful result → restore History after terminalization.

## Keyboard
⌘, Settings · ⌘Q quit · Escape dismisses transient workflows where safe · Full Keyboard Access everywhere · windows restore size/placement.
