# Verification

How to verify a change in this repository. Commands and limits below come from [README.md](README.md), [AGENTS.md](AGENTS.md), `.made.yml`, `site/package.json`, and the GitHub Actions workflows. This file does not introduce other tools.

Match the path you changed. Run both when a change spans the app and the site.

Hosted CI is incomplete on purpose. A green run does not prove native TCC, Speech, Accessibility, hardware, signing, or clean-account dogfood.

## Native app

Menu-bar macOS app. Swift / SwiftPM + Xcode (`Package.swift`, `Oigo.xcodeproj`). macOS 26 or later on Apple silicon.

### Documented local checks

```zsh
swift build
swift build --product Oigo
swift run oigo-macos-floor-check
```

`oigo-macos-floor-check` fails unless SwiftPM, Info.plist, and every Xcode configuration declare exactly `26.0`.

### Contract harnesses

`.github/workflows/verify.yml` is the SwiftPM suite CI runs on pull requests, every push to `main`, and `workflow_dispatch` of an exact git ref. After the three commands above, the `Swift build and contract harness` job `swift run`s the contract products listed in that workflow (the `oigo-*-contract-tests` / performance / packaging executables from `Package.swift`).

`.made.yml` `commands.test` is a shorter local sequence: `swift build`, `swift build --product Oigo`, and a subset of those harnesses. It does not run the floor check or the Xcode app-bundle job. To match CI’s SwiftPM coverage, follow `verify.yml` rather than only `.made.yml`.

### Xcode app bundle

A green package build is not app-bundle validation. The `Xcode app bundle` job in `.github/workflows/verify.yml` builds unsigned Release `Oigo.app` from `Oigo.xcodeproj` on a `macos-26` runner, inspects it with `Scripts/inspect-oigo-app-bundle.sh`, and runs `Scripts/bounded-oigo-launch.sh`. Reproduce that locally on a Mac when you change the app target, Info.plist, or packaging.

Signing and notarization are a separate local procedure in [docs/release.md](docs/release.md). Hosted CI builds unsigned Release `Oigo.app` and does not sign or notarize.

### What this path cannot prove

Microphone, Accessibility, on-device Speech, Foundation Models, global hotkeys, insertion into other apps, and clean-account onboarding need a real Mac and a real user. CI does not stand in for that.

## Site

The product site lives in `site/` (Astro) and publishes from `main` to GitHub Pages.

`.github/workflows/site.yml` runs on pull requests and on pushes to `main` when `site/**`, `DESIGN.md`, or the workflow file itself change. On `ubuntu-latest` with Node 24 it does:

```sh
cd site
npm ci
npm run build
npm run seo-smoke
```

`seo-smoke` reads the built `site/dist` output, so `npm run build` has to succeed first. CI uploads that `dist` as a Pages artifact and deploys only on a push to `main`.

`site/package.json` also defines `dev`, `preview`, and `check` (`astro check`). Those are local helpers. The Site workflow does not run them.

Web design system: [DESIGN.md](DESIGN.md). Native AppKit design system: [design/docs/design-system.md](design/docs/design-system.md).

## Workflow files

- Native CI: `.github/workflows/verify.yml`
- Site CI: `.github/workflows/site.yml`
- Local Made test subset: `.made.yml`
