# OffSight — Backlog

What is still to do after the M0 working slice, checked against the requirements (`docs/01-user-requirements.md`) and the code. Order of work at the end.

## Bugs

### B1. No prompt when Photo Booth opens with OffSight Camera already selected
**Status:** fixed (rule R2 changed, see `docs/02`); confirm on device.
**Seen:** Photo Booth set to OffSight Camera, then launched: no approval prompt. Switching Photo Booth to another camera and back to OffSight Camera brings the prompt.

**Likely causes (to confirm):**
1. **A quick stop and start at launch.** Photo Booth starts and stops the camera as its window appears, is covered or becomes visible. If it starts, stops and restarts within the grace period (15 s), the policy treats it as a restart of the same session. When the session ended while still *pending* (unanswered), rule R2 brings it back as *placeholder* (see the state machine in `docs/02`, “Ending → Placeholder: was Placeholder or Pending”; test `testPendingPromptDisappearsWhenAppStopsAndReturnsAsPlaceholder`). The prompt is gone and the app silently keeps the placeholder. Safe, but the user never gets asked.
2. **The start isn't seen as a session at launch** (for example, the client never reported as streaming).
3. **The prompt is shown but hidden** while Photo Booth is still activating.

**To tell them apart:** when it happens, open the OffSight menu. *Photo Booth — Placeholder* points to cause 1; Photo Booth not listed points to cause 2; *Waiting for approval* points to cause 3. Copy Diagnostics at the same moment.

**Proposed fix for cause 1:** a restart within the grace period of a session that ended *undecided* resumes as *pending* with a fresh prompt (still the placeholder until approved, so still fail-closed). Approved and declined sessions keep their decision as today (UR-12). Changes rule R2 and one unit test; needs your agreement because R2 is part of the approved architecture.

### B2. Background effect not reaching meeting apps
macOS applies the Background effect to OffSight's preview but not (so far) to the frames OffSight passes on. Latest attempt: capture in the camera's YUV format. **Waiting on test.** If it still fails: build OffSight's own background effect (Off / Blur / Image / Colour) with Vision person segmentation, applied to live frames only.

## Must-haves for v1.0

| Item | Requirement | Notes |
|---|---|---|
| First-run onboarding | UR-36, UR-37 | Explain, request permissions with reasons, guide choosing OffSight Camera in each installed meeting app, confirm protection is active. |
| Launch at login with consent | UR-38; App Store guideline 2.4.5 | Today it is turned on silently on first run. Make it a pre-ticked option in onboarding. |
| Relaunch after a crash | NFR-11 | Fails closed already (placeholder continues); does not relaunch itself. |
| Camera unplugged mid-session | NFR-12 | Sleep ends sessions. Unplugging the live camera must fall back to the placeholder and reselect a camera. |
| Smoother extension updates | — | Guide the user when an updated camera extension needs a restart, instead of leaving “Installed but not running”. |
| Keyboard and VoiceOver pass | NFR-13 | Menu, prompt, Settings, Video Effects, Help. |
| Measure the timing requirements | UR-19, NFR-07, NFR-09 | Shutter close ≤ 250 ms, ≤ 1 frame added latency, prompt ≤ 500 ms. |
| Hide the Video Effects preview from screen sharing | NFR-05 | The prompt's preview already is; the new window's preview is not. |

## Release and distribution

| Item | Requirement | Notes |
|---|---|---|
| App Store preparation | NFR-17 | Privacy manifests (app and extension), `ITSAppUsesNonExemptEncryption`, an upload script (automatic signing), notes for App Review. |
| TestFlight build through review | Spike S1 | Confirms App Review accepts the camera extension design. |
| Release workflow + Homebrew cask | NFR-17 | `release.yml`: Developer ID signing, notarization, DMG/ZIP, cask PR; App Store upload. |
| Project site live | — | Merge to `main`, enable GitHub Pages; check whether `astatine-.github.io` resolves (trailing hyphen) or use a custom domain. |
| Account tasks (owner) | — | Agreements, EU trader status, copyright holder for the listing. |

## Should and could

| Item | Requirement | Status |
|---|---|---|
| Tab or site name for browser meetings | UR-34a (S) | Not built; Homebrew build only (needs Apple Events). |
| External webcams and Continuity Camera | UR-30 (S) | Camera choice exists; untested with either. |
| Initials or name placeholder | UR-27 (C) | Not built. |
| Local activity history | UR-24 (C) | Not built. |

## Testing still to do

- Webex, Slack huddles, FaceTime; Teams and Meet in Edge, Arc and Firefox (UR-33). Done: Zoom, Teams, Meet, Photo Booth, QuickTime.
- Fail-closed: quit OffSight mid-call; the meeting app keeps the placeholder.
- Clean-Mac install and uninstall (NFR-18).
- On-device checks of: launch at login, notifications, shortcuts, prompt expiry and grace settings, camera choice, Help menu, Settings window.

## Suggested order

1. B1 and B2.
2. Onboarding, including launch-at-login consent.
3. App Store preparation and a TestFlight build.
4. Robustness: crash relaunch, camera unplug, extension updates, screen-sharing fix.
5. Accessibility pass and timing measurements, then the remaining app tests.
6. Release workflow and Homebrew; then the should and could items.
