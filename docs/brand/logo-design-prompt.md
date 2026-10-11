# Claude Design prompt: OffSight logo & icon set

Paste everything below the line into Claude Design.

---

Design the visual identity for **OffSight**, a macOS menu bar utility that acts as a **software camera shutter**. Meeting apps (Zoom, Teams, Google Meet, Webex) see a "Camera off" placeholder instead of the user's face until the user explicitly approves live video for that one meeting. When the meeting ends, the shutter closes again on its own. The name is a play on "out of sight" and "sight off".

**Personality:** calm, trustworthy, quietly protective. Think "a well-made physical lens cap", not "security alarm". Friendly and precise, never paranoid or aggressive. No padlocks, shields with checkmarks, eyes, or spy imagery.

**Core idea to explore:** a camera lens or aperture that is closed or covered. For example: an iris diaphragm with its blades shut, a lens with a sliding shutter cover, or a camera lens whose opening is a closed eyelid-like curve. The shape should still read at 16 px.

**Please produce 3 distinct concept directions.** For each direction, deliver:

1. **macOS app icon** (1024×1024). Follow Apple's current macOS icon grid: rounded-square ("squircle") silhouette with a subtle depth/material treatment. Show it at 1024, 128, 32 and 16 px to prove it holds up small.
2. **Menu bar glyph set.** Monochrome "template" glyphs: single colour, transparent background, 18×18 pt at 1× and 2×, consistent stroke weight. Five states that **must be distinguishable by shape alone**, not colour:
   - **Idle**: no app using the camera (base glyph, outline style)
   - **Protected**: apps connected, placeholder showing (base glyph + small shield or closed-shutter cue)
   - **Live**: camera feed is going out (filled/open variant + a dot)
   - **Unprotected**: an app is bypassing OffSight (base glyph + warning triangle badge)
   - **Paused**: protection paused (base glyph + pause badge)
3. **Wordmark**: "OffSight" (capital O and S), plus a horizontal lockup of icon + wordmark.
4. **"Camera off" placeholder frame**: the image meeting participants see. 1920×1080 (16:9), and also a 4:3 crop that still works. Show the mark, the line "Camera off" and the smaller line "Protected by OffSight". It must read correctly when **mirrored** (meeting apps often mirror self-view), so keep the mark symmetric or mirror-safe and avoid relying on text alone. It should look calm and professional on a call: dark, low-contrast background, nothing distracting.

**Colour:**
- Primary background: deep slate around #1C2129.
- Light foreground around #D9DEE5.
- One accent colour of your choice for the app icon only (suggest a muted teal or warm amber), checked for contrast in light and dark mode.
- The menu bar glyphs are monochrome; macOS tints them.
- The "Live" state is shown by shape. Colour may only reinforce it.

**Constraints:**
- Original artwork only. No resemblance to Apple's FaceTime or Photo Booth icons, the Zoom, Teams or Meet logos, or SF Symbols copied directly.
- Must work on light and dark menu bars and wallpapers.
- Vector output (SVG) for everything, with the app icon also as a 1024 px PNG.
- Name the files clearly, e.g. `menubar-live@2x.png`.

**Present** the three directions side by side, with a one-paragraph rationale for each and a recommendation for which one to take forward.
