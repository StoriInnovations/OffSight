# OffSight — Backlog

Status of the work after the M0 working slice, checked against `docs/01-user-requirements.md`.
"Done" means implemented, built in CI and covered by tests where possible; items marked
**verify on device** still need a run of `scripts/test-on-device.sh` (or a manual check) on a Mac.

## Bugs

| # | Bug | Status |
|---|---|---|
| B1 | No prompt when Photo Booth opens with OffSight Camera already selected | **Done**: rule R2 changed (an unanswered session that restarts within grace prompts again). Unit tests; device checks `restart-pending` and `photo-booth`. Verify on device. |
| B2 | macOS Background effect reaches OffSight's preview but not meeting apps | **Waiting on test** of the YUV capture change. If it still fails: build OffSight's own background effect (Vision person segmentation), live video only. |

## Must-haves

| Item | Requirement | Status |
|---|---|---|
| First-run onboarding | UR-36, UR-37 | **Done**: six-step welcome guide; reopen from Settings › General. Verify on device. |
| Launch at login with consent | UR-38; App Store 2.4.5 | **Done**: pre-ticked choice on the last onboarding step; launch agent. |
| Relaunch after a crash | NFR-11 | **Done**: launch agent with KeepAlive (when launch at login is on); SIGTERM and Quit exit cleanly. Device check `fail-closed`. |
| Camera unplugged mid-session | NFR-12 | **Done**: all shutters close, camera reselected, notification. Verify on device with a USB webcam. |
| Extension updated but not running | — | **Done**: one-time "restart to finish" notification after 20 s. |
| Keyboard and VoiceOver | NFR-13 | **Done** (pass 1): prompt announcements, labels, hints; approve via menu or shortcut with VoiceOver. Device check `ui-prompt`. A full VoiceOver walkthrough is still worth doing. |
| Timing requirements | UR-19, NFR-07, NFR-09 | **Measured by** device checks `close-all`, `approve-live`, `prompt-latency`. |
| Video Effects preview hidden from screen sharing | NFR-05 | **Done**. |

## Release and distribution

| Item | Status |
|---|---|
| App Store preparation | **Done**: privacy manifests, export flag, `scripts/appstore-upload.sh`, `docs/05-app-review-notes.md`. |
| TestFlight build through review (spike S1) | **Owner**: run `scripts/appstore-upload.sh`, add the build to an external TestFlight group. |
| Release workflow + Homebrew cask | **Done**: `.github/workflows/release.yml`, `docs/06-releasing.md`. **Owner**: secrets in the `release` environment, create `astatine-/homebrew-offsight`. |
| Project site live | **Owner**: merge to `main`, enable GitHub Pages (Source: GitHub Actions); check `astatine-.github.io` resolves. |
| Account tasks | **Owner**: agreements, EU trader status, copyright holder for the listing. |

## Should and could

| Item | Requirement | Status |
|---|---|---|
| Website for browser meetings | UR-34a (S) | **Done** (Homebrew and Debug builds; App Store shows the browser name). Verify on device. |
| External webcams and Continuity Camera | UR-30 (S) | Camera choice exists; **verify on device**. |
| Initials placeholder | UR-27 (C) | **Done**. |
| Local activity history | UR-24 (C) | Not built (not selected for this round). |

## Testing

- **Unit tests** (CI, every push): policy engine and invariants, frame gate, client tracker and protocol, placeholder layout and rendering, effects-free format, initials renderer, browser site parsing, meeting-app guides, test-hook protocol.
- **Build checks** (CI): Debug, Release and App Store builds; extension embedded and free of AppKit; brand assets; launch agent, privacy manifests and help page bundled; test tool builds.
- **On-device** (`scripts/test-on-device.sh`, see `Tools/OffSightTest/README.md`): 17 automated checks including Photo Booth, QuickTime, UI through Accessibility and fail-closed; guided checks for Zoom, Teams, Meet in five browsers, Webex, Slack and FaceTime; Markdown report.
- Still manual: clean-Mac install and uninstall (NFR-18); a full VoiceOver walkthrough.

## Next

1. On device: `scripts/test-on-device.sh all`, and the B2 background test.
2. TestFlight build (S1).
3. Release secrets, tap repository, site live.
4. Activity history (UR-24) if wanted.
