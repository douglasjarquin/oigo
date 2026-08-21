# Oigo ear-O asset contract

## Task root

`Assets/OigoIdentity` is the Task 8 source, contract, and fixture root.
It is not a production bundle resource.

`Source/ear-o.svg` is editable source artwork for the approved primary mark.
It contains exactly one unbroken eight-segment cubic path that reads as an O, a G, and an ear.
The SVG is generation input only and must never be shipped as a runtime resource.

`Fixtures/` is validation-only input and must never be added to a Release target.

## Production catalog

`Oigo/Assets.xcassets` is the only Task 8 production resource catalog.
`AppIcon.appiconset` contains the required 16, 32, 128, 256, and 512 point macOS representations at both 1x and 2x.
`OigoMenuBar.imageset` contains a 16 point menu-bar representation at 1x and 2x.

Generate the catalog with `zsh Scripts/generate-oigo-assets.sh --output Oigo/Assets.xcassets` only when the destination is absent.
Validate it with `zsh Scripts/validate-oigo-assets.sh Oigo/Assets.xcassets`.
The validator regenerates a disposable comparison catalog and rejects stale, malformed, incomplete, unexpected, or nondeterministic output.

The generator is a fixed local Python standard-library rasterizer embedded in the zsh entry point.
It parses only the source artwork's `M` and cubic `C` commands and encodes PNG without metadata, clocks, random input, a proprietary design tool, or an external renderer.

## Semantic and template rules

App icons use the ear-O in `#f5f5f7` on the flat `#0b0c10` squircle background.
They are original artwork and are not template images.

Menu-bar images are black alpha masks with `template-rendering-intent` set to `template`.
AppKit selects their light or dark appearance through template rendering.
The menu bar must not use an SF Symbol, text, waveform, microphone, gradient, or a state-specific recolor baked into this resource.
Recording and attention badges remain runtime UI treatment owned by the status-surface task.

## Resource membership handoff

Task 10 is the sole custodian of `Oigo.xcodeproj/project.pbxproj` serialization.
Task 10 must add `Oigo/Assets.xcassets` to the Oigo app target's Resources build phase and preserve all non-production roots outside Release membership.
`Oigo/Info.plist` declares `CFBundleIconName` as `AppIcon`.
No gallery, prototype, source SVG, contract, or fixture is eligible for Release membership.
