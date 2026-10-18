# Handoff: OffSight brand + menu bar assets (Iris direction)

## Overview
Final visual assets for **OffSight**, a macOS menu bar utility that acts as a software camera shutter. Meeting apps see a "Camera off" placeholder until the user approves live video for one meeting. The chosen direction is **Iris**: a six-blade iris diaphragm, closed.

This bundle contains **production assets** (an Xcode asset catalog, SVG and PNG) plus the HTML design board as reference. Fidelity: **high**. Use the assets as-is. Do not redraw or restyle them.

## What to tell Claude Code
Paste the contents of `CLAUDE_PROMPT.md` into Claude Code from the root of the OffSight Xcode project, with this folder copied into the repo (e.g. `Design/design_handoff_offsight_brand/`).

## Folder map
```
Assets.xcassets/                  ← merge into the app target's asset catalog
  AppIcon.appiconset/             16–512 @1x/@2x (16 & 32 px use the simplified master)
  MenuBar{Idle,Protected,Live,Unprotected,Paused}.imageset/        template SVG (monochrome, macOS tints)
  MenuBar{…}Color.imageset/       optional coloured-badge SVGs, light + dark appearance
  PlaceholderCameraOff.imageset/  1920×1080 frame sent to meeting apps
  PlaceholderCameraOff4x3.imageset/ 1440×1080 crop
  BrandSlate / BrandForeground / BrandTeal / StatusLive / StatusWarning .colorset
source/          master SVGs (app icon, menubar, menubar-color)
png/             1x/2x PNG exports of every glyph (for docs, website, non-Xcode use)
brand/           wordmark + horizontal lockup, light & dark (SVG, font subset embedded — outline before print)
placeholder/     "Camera off" frames, SVG + PNG
reference/       OffSight Identity.dc.html: the full design board (sections 3a, 2a, 1a are the final ones)
```
File naming: `-2x` replaces `@2x` (`@` couldn't be used in these file names). The asset catalog references them explicitly, so no renaming is needed for Xcode.

## Menu bar states
All glyphs are 18×18 pt, drawn on an 18-unit grid with a 1.5 pt ring and 1.25 pt blades. Each state is distinguishable by **shape alone**.

| State | Asset | Shape | When |
|---|---|---|---|
| Idle | `MenuBarIdle` | Outline ring + 6 curved closed blades | No app is using the camera |
| Protected | `MenuBarProtected` | Idle iris + solid closed-iris badge, bottom-right | ≥1 app is connected and receiving the placeholder |
| Live | `MenuBarLive` | Solid disc with open hexagonal aperture + solid dot, bottom-right | User approved; real feed is going out |
| Unprotected | `MenuBarUnprotected` | Open iris + warning triangle, bottom-right (breaks the circle) | An app is reading the physical camera directly, bypassing OffSight |
| Paused | `MenuBarPaused` | Iris blades + two bold full-height pause bars in the centre | User paused protection |

State priority when several apply: **Unprotected > Live > Paused > Protected > Idle**.

### Colour (optional, off by default)
- Default: template images (`isTemplate = true`). macOS tints them for the light or dark menu bar, highlight, and Reduce Transparency.
- Optional "Coloured status" setting: use the `…Color` imagesets (`isTemplate = false`). Only the badge is coloured:
  - Live dot: red `#E5352B` (light) / `#FF5A4F` (dark)
  - Unprotected triangle: amber `#D97A00` / `#FFB23F`
  - Protected badge: teal `#2F8580` / `#6FC7C2`. Not green: macOS's own green indicator means "camera on".
  - Idle and Paused: no colour. Base ink is `#1C2129` on light, `#ECEEF1` on dark.
- Colour must never be the only cue. The shapes above already carry each state.

## App icon
- macOS squircle body on the 1024 grid (≈824 pt body, transparent margin and shadow included in the artwork).
- Slate body `#2D3440 → #181C23`, brushed metal ring, teal blades `#6FB7B4 → #4C918E`.
- 16 and 32 px come from `appicon-small-16-32.svg`, which has heavier seams and no fine highlights. Don't downscale the 1024 for those sizes.

## "Camera off" placeholder
- The frame the virtual camera sends while protected. 1920×1080 by default. Use the 4:3 file (1440×1080) when the requested format is 4:3, or centre-crop the 16:9 frame (the content is centred and survives the crop).
- Background: radial `#212731 → #191D24`. Mark: Idle iris in `#9AA3AF`. "Camera off" in `#D9DEE5`. "Protected by OffSight" in `#8A939F`.
- The mark is rotationally symmetric, so it stays correct in mirrored self-view. The text will appear reversed in self-view only; participants see it correctly. Do **not** pre-flip the frame.
- Other resolutions: render the SVG at the requested size, or scale the PNG with aspect-fill. Never stretch it.

## Design tokens
| Token | Light | Dark |
|---|---|---|
| BrandSlate | `#1C2129` | `#1C2129` |
| BrandForeground | `#D9DEE5` | `#D9DEE5` |
| BrandTeal (accent: icon, Protected badge) | `#2F8580` | `#6FC7C2` |
| StatusLive | `#E5352B` | `#FF5A4F` |
| StatusWarning | `#D97A00` | `#FFB23F` |

Wordmark typeface: Sora SemiBold (600), letter-spacing −1 at 120 px. Capital O and S: "OffSight".

## Accessibility
- Set `accessibilityDescription` on each status image: "OffSight: idle", "OffSight: camera protected", "OffSight: camera live", "OffSight: camera unprotected", "OffSight: protection paused".
- When the state changes, update the status item's tooltip to match.
- Don't animate the menu bar icon, except possibly a single 150 ms crossfade between states.
