# Contributing

Thanks for contributing to Oigo.

Oigo is a menu-bar dictation app for macOS 26 or later on Apple silicon, plus the product site in `site/`. Product behavior, install, and limitations are in [README.md](README.md).

## Workflow

Changes land through ordinary GitHub pull requests against `main`. A person reviews the diff and merges it.

1. Fork this repository, or create a branch from current `main`.
2. Make your change on that branch.
3. Commit.
4. Push the branch.
5. Open a pull request targeting `main`.

## Verification

Run the checks in [VERIFY.md](VERIFY.md) for the path you touched (native app, site, or both). That file is the verification guide for this repo.

## Repo conventions

Native code is Swift / SwiftPM + Xcode (`Package.swift`, `Oigo.xcodeproj`). The documented local native commands are:

```zsh
swift build
swift build --product Oigo
swift run oigo-macos-floor-check
```

`.made.yml` `commands.test` and `.github/workflows/verify.yml` also run contract harnesses. The verify workflow’s Xcode job builds and inspects unsigned Release `Oigo.app`. Hosted CI does not prove native TCC, Speech, Accessibility, hardware, signing, or clean-account dogfood.

The site is an Astro app in `site/`, published from `main` to GitHub Pages by `.github/workflows/site.yml`. That workflow runs `npm ci`, `npm run build`, and `npm run seo-smoke` in `site/`.

Further reading as needed:

- [README.md](README.md) — product, install, limitations, and the documented native commands
- [AGENTS.md](AGENTS.md) — stack notes for the native app and site
- [DESIGN.md](DESIGN.md) — web design system
- [design/docs/design-system.md](design/docs/design-system.md) — native AppKit design system

## Questions

Open a GitHub issue.
