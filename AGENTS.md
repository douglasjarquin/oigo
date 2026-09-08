# Oigo

Menu-bar dictation app for macOS 26 or later on Apple silicon. Swift / SwiftPM + Xcode (`Package.swift`, `Oigo.xcodeproj`). Product behavior, install, and limitations: see `README.md`.

## Native app

Documented local checks from `README.md`:

```zsh
swift build
swift build --product Oigo
swift run oigo-macos-floor-check
```

`.made.yml` `commands.test` and `.github/workflows/verify.yml` also run `swift build`, the Oigo product build, and the contract harnesses (`swift run oigo-*-contract-tests` and related checks). Verify additionally builds and inspects unsigned Release `Oigo.app` via `Oigo.xcodeproj`. Hosted CI does not prove native TCC, Speech, Accessibility, hardware, signing, or clean-account dogfood.

## Site

The product site lives in `site/` and is published from `main` to GitHub Pages by `.github/workflows/site.yml`.

```zsh
cd site
npm ci
npm run build
npm run check
npm run seo-smoke
```

Web design system: `DESIGN.md`. Native AppKit design system: `design/docs/design-system.md`.
