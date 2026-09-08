# Oigo

Menu-bar dictation app for macOS 26 or later on Apple silicon. Swift / SwiftPM + Xcode (`Package.swift`, `Oigo.xcodeproj`). Product behavior, install, and limitations: see `README.md`.

## Native app

From `README.md`:

```zsh
swift build
swift build --product Oigo
swift run oigo-macos-floor-check
```

`.made.yml` `commands.test` and `.github/workflows/verify.yml` run `swift build`, the Oigo product build, and the contract harnesses. Verify also builds and inspects unsigned Release `Oigo.app` via `Oigo.xcodeproj`. Hosted CI does not prove native TCC, Speech, Accessibility, hardware, signing, or clean-account dogfood.

## Site

The product site lives in `site/` and is published from `main` to GitHub Pages by `.github/workflows/site.yml`. That workflow runs `npm ci`, `npm run build`, and `npm run seo-smoke` in `site/`. Scripts are defined in `site/package.json`.

Web design system: `DESIGN.md`. Native AppKit design system: `design/docs/design-system.md`.
