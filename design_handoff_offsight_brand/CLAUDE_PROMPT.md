# Prompt for Claude Code

Copy everything below the line into Claude Code, run from the root of the OffSight Xcode project. First copy this folder into the repo at `Design/design_handoff_offsight_brand/`.

---

You are integrating the final OffSight brand assets into this macOS app. The assets are in `Design/design_handoff_offsight_brand/`. Read its `README.md` first. It is the spec. Use the provided artwork as-is: do not redraw, recolour, or substitute SF Symbols.

Tasks:

1. **Asset catalog.** Merge `Design/design_handoff_offsight_brand/Assets.xcassets/*` into the app target's main asset catalog. Replace the existing `AppIcon`. Keep the `Contents.json` files exactly as given. The menu bar imagesets are vector SVGs with `template-rendering-intent: template`, and the `…Color` variants use `original` with a dark-appearance variant. Make sure the catalog builds without warnings.

2. **Status model.** Add (or adapt the existing) `enum ProtectionState { case idle, protected, live, unprotected, paused }`. Map it to assets `MenuBarIdle`, `MenuBarProtected`, `MenuBarLive`, `MenuBarUnprotected` and `MenuBarPaused`. When several conditions hold, pick by priority: unprotected > live > paused > protected > idle. Derive the state from the app's existing camera and session logic. If that logic doesn't exist yet, add a clearly marked stub publisher that I can wire up later.

3. **Menu bar item.** In the `NSStatusItem` setup, load the image with `NSImage(named:)`, set `size = NSSize(width: 18, height: 18)` and `isTemplate = true`, and set `accessibilityDescription` and the button tooltip using the strings in the README. Update the image whenever the state changes, on the main thread, with no animation beyond an optional 150 ms crossfade.

4. **Optional coloured status.** Add a Bool user default `useColouredStatusIcon` (default `false`) and a toggle for it in Settings, labelled "Coloured status icon". When it is on, use the `…Color` imageset for the current state and set `isTemplate = false`. Idle and Paused look the same in both modes. Observe the setting and refresh the icon live.

5. **Placeholder frame.** Wherever the virtual camera / Camera Extension produces the "camera off" frame, replace the current drawing with the `PlaceholderCameraOff` image (1920×1080). Use `PlaceholderCameraOff4x3` when the negotiated format is 4:3. For other sizes, aspect-fill and centre (never stretch). Convert to a `CVPixelBuffer` once per format and cache it. Do not mirror the frame. If the extension is a separate target, add the two placeholder imagesets to that target's asset catalog too.

6. **Brand colours.** Expose the colorsets as `Color`/`NSColor` extensions (`.brandSlate`, `.brandForeground`, `.brandTeal`, `.statusLive`, `.statusWarning`) and use them for any existing UI that hard-codes those values.

7. **Wordmark.** If the app has an About window or onboarding with a text logo, use `brand/lockup-horizontal-on-dark.svg` / `-on-light.svg`, chosen by effective appearance. Add them to the catalog as vector imagesets.

When done: build, then list the files you changed and show a screenshot or describe how to check each of the five states, e.g. via a debug menu that forces each `ProtectionState`. Add that debug menu behind `#if DEBUG` if one doesn't exist.
