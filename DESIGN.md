# Oigo Web Design System

## 0. Research Log

- Embedded reference: `design/Landing Page.dc.html`, `design/Design System.dc.html`, and `design/docs/design-system.md` were treated as the authoritative Oigo reference packet.
- Skipped generated concept images: the supplied canvases are already precise visual references, so generating a competing visual direction would reduce fidelity.
- Skipped external product research: this is an in-repository translation of existing Oigo design work, not a greenfield brand exercise.

## 1. Atmosphere & Identity

Oigo Web is a quiet, dark, system-native surface for a voice tool that does exactly what it says.
The signature is the outlined ear-O mark, paired with restrained blue action accents and small mono annotations that make the page feel precise without feeling technical for its own sake.

## 2. Color

### Palette

| Role | Token | Value | Usage |
| --- | --- | --- | --- |
| Page background | `--color-page` | `#0a0a0c` | Permanent web background |
| Alternate band | `--color-band` | `#0e0e11` | Privacy and download sections |
| Card | `--color-card` | `#141417` | Content cards and panels |
| Code well | `--color-well` | `#0e0e10` | Transcript and code samples |
| Window shell | `--color-window` | `#1f2024` | Product mockups |
| Document | `--color-document` | `#1e1e20` | Product mockup content |
| Window chrome | `--color-chrome` | `#222226` | Product mockup chrome |
| Primary text | `--color-text-primary` | `#f5f5f7` | Headings and primary controls |
| Body text | `--color-text-body` | `#e8e8ec` | Main copy |
| Secondary text | `--color-text-secondary` | `#98989d` | Supporting copy |
| Muted text | `--color-text-muted` | `#8e8e93` | Metadata and captions |
| Tertiary text | `--color-text-tertiary` | `#6e6e73` | Overlines and quiet annotations |
| Action | `--color-action` | `#3f8cff` | Links, focus, information, caret |
| Action hover | `--color-action-hover` | `#6ba6ff` | Link hover |
| Recording | `--color-recording` | `#ff453a` | Recording state only |
| Attention | `--color-attention` | `#ff9500` | Warnings and preserved recordings |
| Confirmed | `--color-confirmed` | `#28c840` | Readiness and successful state |
| Light control | `--color-control` | `#f5f5f7` | Primary web button |
| Dark control text | `--color-control-text` | `#0a0a0c` | Text on the primary button |
| Default hairline | `--color-hairline` | `rgba(255, 255, 255, 0.07)` | Dividers and card edges |

Accent colors are semantic.
Blue is for action or information, red is for recording, orange is for attention, and green is for confirmed state.

## 3. Typography

### Scale

| Level | Size | Weight | Line height | Tracking | Usage |
| --- | --- | --- | --- | --- | --- |
| Display | `56px` | `700` | `1.08` | `-0.02em` | Landing hero |
| Section heading | `34px` | `700` | `1.2` | `-0.01em` | Landing sections |
| Document title | `30px` | `700` | `1.2` | `-0.01em` | Design-system title |
| Card title | `19px` | `700` | `1.3` | `0` | Mode cards |
| Body large | `19px` | `400` | `1.5` | `0` | Hero introduction |
| Body | `15px` | `400` | `1.6` | `0` | Marketing copy |
| Body small | `14px` | `400` | `1.55` | `0` | Cards and explanations |
| Control | `13px` | `500-600` | `1.4` | `0` | Buttons and labels |
| Caption | `12px` | `400-600` | `1.4` | `0` | Metadata |
| Mono | `11-13px` | `400-600` | `1.5` | `0-.08em` | Shortcuts, timers, overlines |

### Font Stack

- Primary: `-apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif`.
- Mono: `"SF Mono", ui-monospace, SFMono-Regular, Menlo, monospace`.

The product and its marketing surface use system fonts only.

## 4. Spacing & Layout

All intentional spacing derives from a 4px base unit.

| Token | Value | Usage |
| --- | --- | --- |
| `--space-1` | `4px` | Icon and badge relationships |
| `--space-2` | `8px` | Inline groups and compact stacks |
| `--space-3` | `12px` | Controls and list rows |
| `--space-4` | `16px` | Standard content separation |
| `--space-5` | `20px` | Card gaps |
| `--space-6` | `24px` | Card padding |
| `--space-7` | `28px` | Expanded card padding |
| `--space-8` | `32px` | Hero mark rhythm |
| `--space-10` | `40px` | Page gutters and hero copy spacing |
| `--space-12` | `48px` | Heading-to-content separation |
| `--space-16` | `64px` | Design-system section rhythm |
| `--space-20` | `80px` | Landing section rhythm |
| `--space-24` | `96px` | Major landing breaks |

Marketing content is capped at `1060px`.
The design-system document is capped at `1400px` and becomes one readable column below `980px`.
The landing page uses centered content, while its history section deliberately switches to an asymmetric two-column composition.

## 5. Components

### SiteHeader

- **Structure**: sticky navigation with mark, anchor links, and one primary download link.
- **Variants**: landing header; document header link.
- **Spacing**: `--space-2`, `--space-5`, `--space-10`.
- **States**: default, link hover, keyboard focus.
- **Accessibility**: semantic `nav`, descriptive links, visible focus ring.
- **Motion**: no decorative motion; backdrop remains stable.
- **Layout**: horizontal cluster with a flexible spacer; wraps on narrow screens.

### ActionButton

- **Structure**: semantic anchor styled as a button for navigational CTAs.
- **Variants**: primary filled; secondary outlined; text link.
- **Spacing**: `--space-3` vertical and `--space-6` horizontal padding.
- **States**: default, hover, active, keyboard focus.
- **Accessibility**: real links with meaningful destinations and visible focus.
- **Motion**: color and border transitions only.
- **Layout**: inline cluster that stacks at mobile widths.

### SurfaceCard

- **Structure**: one bordered card with title, body, and optional code well.
- **Variants**: standard card, blue-emphasis card, muted privacy card, document panel.
- **Spacing**: `--space-6` or `--space-7` padding; `--space-5` gaps.
- **States**: default; interactive cards expose hover and focus only when actionable.
- **Accessibility**: content remains semantic DOM, with no image standing in for UI.
- **Motion**: none unless the card contains an active control.
- **Layout**: grid item or document section child.

### ProductMockup

- **Structure**: window chrome, document surface, live transcript, and recording HUD.
- **Variants**: Notes hero mockup; History recovery mockup.
- **Spacing**: `--space-6`, `--space-10`.
- **States**: recording, preserved, copied.
- **Accessibility**: mockup is labeled as a visual example and all content is real text.
- **Motion**: CSS caret and recording pulse communicate active state; reduced motion makes them static.
- **Layout**: bounded media surface with intrinsic overflow protection.

### FAQDisclosure

- **Structure**: native `details` and `summary` with answer content.
- **Variants**: closed; open.
- **Spacing**: `--space-5` row padding and `--space-4` answer separation.
- **States**: default, hover, focus, open.
- **Accessibility**: native keyboard and screen-reader disclosure semantics.
- **Motion**: chevron transform only; reduced motion disables transition.
- **Layout**: single vertical stack.

## 6. Motion & Interaction

The reference uses only motion that reports activity or user state.
The recording pulse uses `1.6s ease-in-out` opacity cycling.
The transcript caret blinks at `1.1s step-end`.
FAQ chevrons use a `200ms ease` transform when opened.
The reduced-motion media query removes all non-essential animation and transition.

## 7. Depth & Surface

The site uses a mixed strategy: tonal shifts establish the page bands, hairlines define cards, and shadows reserve depth for the two product mockups.
The hero mockup uses `0 30px 80px rgba(0, 0, 0, 0.5)`.
The history mockup uses `0 20px 60px rgba(0, 0, 0, 0.45)`.
No surface relies on a single blur effect to imply hierarchy.

## 8. Accessibility Constraints & Accepted Debt

### Constraints

- WCAG 2.2 AA target with a 4.5:1 body-text contrast floor and 3:1 large-text floor.
- Every interactive element must be keyboard reachable with a visible focus ring.
- Use semantic landmarks, real links, native disclosure controls, and descriptive labels.
- The primary content must reflow to one readable column at `375px` without horizontal overflow.
- Respect `prefers-reduced-motion`.

### Accepted Debt

| Item | Location | Why accepted | Owner / Exit |
| --- | --- | --- | --- |
| Download artifact is a placeholder anchor until a release exists | `site/src/components/DownloadCta.astro` | The repository has no published binary in issue #146 scope | Release work |
| GitHub and release links point to the repository's public pages | `site/src/components/SiteFooter.astro` | They are valid navigation targets but do not emulate product behavior | Release work |

## Product Boundary

The native AppKit design system remains authoritative in `design/docs/design-system.md`.
This web document and `/design-system/` page quote its principles where useful, but do not restyle or implement AppKit product surfaces.
