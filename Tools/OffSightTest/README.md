# offsight-test

On-device tests for OffSight: automated checks of the approval flow, timings and failure
handling against the real camera extension, plus guided checks for meeting apps that can't be
driven automatically. Produces a Markdown report you can attach to an issue or a release.

## Setup (once per Mac)

1. Install a **Debug** build of OffSight: `scripts/dev-install.sh`. Only Debug builds accept test
   commands; Release and App Store builds can't be approved by any other process (NFR-04).
2. Allow OffSight Camera (System Settings) and finish OffSight's welcome guide.
3. For the Photo Booth check: open Photo Booth once and choose **Camera › OffSight Camera**.
4. Close any app that is using OffSight Camera.

## Run

```
scripts/test-on-device.sh               # build, then run every automated check
scripts/test-on-device.sh run close-all photo-booth
scripts/test-on-device.sh manual zoom teams
scripts/test-on-device.sh all           # automated, then guided
scripts/test-on-device.sh list
```

The first run asks for camera access for your terminal, Accessibility access (for the UI check;
System Settings › Privacy & Security › Accessibility) and permission for the terminal to control
QuickTime Player. The run temporarily sets the grace period to 5 s and
restores your settings at the end. Expect about 3 minutes for the automated checks.

## What it checks

| Check | Requirements | How |
|---|---|---|
| environment | — | OffSight running, OffSight Camera at ≥1920×1440, test hook answering |
| placeholder-default | UR-01–03, UR-05 | A new client gets only placeholder frames (camera counters) |
| prompt-latency | UR-06, NFR-09 | Prompt within 500 ms of the client starting |
| approve-live | UR-07, UR-13 | Live frames after approval, no stall in the stream |
| close-all | UR-16, UR-17, UR-19 | Live stops within 250 ms, stream keeps flowing |
| steady-frames | UR-05, UR-28 | ≥25 fps and one frame size, placeholder and live |
| ui-prompt | UR-06–08, UR-14, UR-20, NFR-04, NFR-13 | Through Accessibility: the prompt names the app, has both buttons and a labelled preview; the menu bar icon says protected; an automated press on Go live is ignored |
| restart-pending | R2, bug B1 | An unanswered app that restarts is asked again |
| grace-keeps-live | UR-12 | A quick restart keeps the approval |
| session-end | UR-11, UR-40 | After the grace period the next session asks again |
| keep-then-live | UR-09, UR-13 | Keep placeholder holds; go live later works |
| prompt-expiry | UR-09, UR-09a | An unanswered prompt expires into the placeholder |
| pause | UR-41 | Paused: live without prompts; resume: asks again |
| bypass | UR-35, UR-35a | Using the real camera directly shows "unprotected" |
| fail-closed | UR-04, NFR-11 | Killing OffSight: the extension's placeholder takes over; OffSight restarts (launch at login on) |
| photo-booth | UR-01, UR-06, B1 | Launch → prompt → live → closed → session ends |
| quicktime | UR-01, UR-06 | New movie recording with OffSight Camera → prompt → live |

"Placeholder" and "live" are measured from OffSight Camera's own counters (what meeting apps
actually received), not from the app's opinion.

Guided checks (`manual`): Zoom, Teams, Meet in Chrome, Safari, Edge, Arc and Firefox, Webex, Slack,
FaceTime. The tool notices the app starting a session and checks the prompt itself; you answer what
the meeting app shows.

## How it talks to OffSight

- **Camera counters:** read from OffSight Camera through CoreMediaIO (works with any build).
- **Commands and state:** distributed notifications to the Debug build's test hook
  (`TestHook` in OffSightCore). Commands: approve, keep placeholder, close all, pause, resume,
  prompt expiry, grace period.
