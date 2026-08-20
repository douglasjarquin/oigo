# Oigo design system (MacUtilityUI)

Generic AppKit layer for native Mac menu-bar utilities. No Oigo strings, models, logos, or persistence. Reference renders: `Popover + HUD Prototype.dc.html`, `State Boards.dc.html`, `Oigo Icon.dc.html`.

## Principles
1. Look and behave unmistakably like a Mac app — native controls, system colors, system type.
2. Communicate the true operational state; never infer success from timing.
3. Sparse, aligned, calm. Hierarchy from spacing, type, separators — not decoration.
4. Nearly inert while idle: no polling, no idle animation, event-driven state only.
5. Status never depends on color alone — always icon + concise label.

## Tokens

### Spacing (pt)
| token | use |
|---|---|
| 4 | tight icon/text relationship |
| 8 | related controls |
| 12 | standard row interior |
| 16 | section spacing |
| 24 | major section separation |
| 32 | window margin |

### Corner radius (pt)
| token | use |
|---|---|
| 6 | compact inline elements (buttons, shortcut chip, segmented) |
| 8–10 | inline notices, contained utility regions |
| 12 | floating HUD |

Do not round every row or section.

### Typography (system font only)
| role | spec |
|---|---|
| Window/pane heading | ~20 pt semibold |
| Section heading | 13 pt semibold |
| Standard label | 13 pt |
| Secondary/helper | 11–12 pt, secondaryLabelColor |
| HUD timer | 13 pt SF Mono / monospacedDigitSystemFont |
| Transcript | system body, user-selectable |

Prefer NSFont.preferredFont / semantic APIs over literals.

### Color (semantic system colors only)
labelColor, secondaryLabelColor, tertiaryLabelColor, windowBackgroundColor, controlBackgroundColor, textBackgroundColor, separatorColor, selectedContentBackgroundColor, systemRed, systemOrange, systemGreen, controlAccentColor.

```swift
enum MacUIStatusTone { case neutral, informational, success, warning, critical, recording }
```
Tone → color: neutral=secondaryLabel, informational=accent, success=systemGreen, warning=systemOrange, critical=systemRed, recording=systemRed. Always paired with an icon + label.

### Icons
SF Symbols / template images. Product mark: the "ear-O" (one continuous stroke, O·G·ear — see Oigo Icon.dc.html). Menu-bar states: idle = template outline; processing = outline + system activity treatment; recording = red stroke + red dot badge; attention = orange dot badge. Legible in light/dark/increased-contrast/inactive.

### Motion
System defaults or 80–140 ms. No springs, bounce, confetti, or continuous animation. Reduce Motion removes nonessential transitions. HUD appear/disappear subtle fade. Indeterminate progress only while visible work occurs.

## Components (generic layer)
Each documents: intended use, state variants, accessibility, appearance, lifecycle, owned tasks/timers/observers.

| component | intended use | owns |
|---|---|---|
| MacUISectionHeader | 13 pt semibold section title | nothing |
| MacUIFormRow | right-aligned label column + control (Settings) | nothing |
| MacUIStatusRow | icon + title + trailing value; tone-driven | nothing |
| MacUIInlineNotice | icon + title + one-sentence body + one action button | nothing |
| MacUIStatusBadge | small tone dot/badge for status items | nothing |
| MacUIEmptyStateView | centered secondary-label message | nothing |
| MacUILoadingView | small indeterminate spinner + label | spinner visible-only |
| MacUIPermissionRow | permission name + state + "Open System Settings" | nothing |
| MacUIStorageHealthRow | storage state + Retry action | nothing |
| MacUITranscriptView | selectable read-only NSTextView, size-bounded | nothing |
| MacUIFloatingPanel | nonactivating borderless NSPanel shell (HUD) | released at terminal lifecycle |
| MacUIDestructiveConfirmation | standard NSAlert/sheet wrapper | nothing |
| MacUIShortcutPresentation | key-glyph rendering of a shortcut | nothing |
| MacUIFieldHelpText | 11 pt helper under a control | nothing |

Extract a primitive only when used more than once or clearly cross-product. Prefer plain AppKit views over a mini-framework.

## Performance rules
- No idle polling, idle animation, filesystem watchers for UI, or accessibility-frame polling.
- Recording timer: 1 Hz, exists only while recording.
- Volatile preview: event-driven, ≤~5 visible updates/s.
- Expensive views/controllers lazy; transient panels, tokens, tasks released at documented boundary.
- Popover never loads full History or transcript bodies (bounded recent-session summary only).

## Reuse guidance
Copy Sources/MacUtilityUI into a new utility unchanged; supply product copy, presentation adapter, and composition in the product layer. The product layer maps authoritative state → generic presentation models and must not become a second state machine.
