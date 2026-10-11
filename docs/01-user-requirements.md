# OffSight — User Requirements Document

| Field        | Value                                   |
|--------------|-----------------------------------------|
| Document     | User Requirements (URD)                 |
| Product      | OffSight for macOS                      |
| Version      | 0.3 (Revised after review)              |
| Status       | **Approved** (2026-10-11)               |
| Date         | 2026-10-11                              |
| Next document| Architecture & Implementation Approach (`02-architecture-and-implementation.md`) |

---

## 1. Purpose

This document sets out **what** OffSight must do for its users. It does not say **how** it will be built. The Architecture & Implementation Approach document will cover that once this one is approved.

## 2. Problem statement

Video-meeting apps (Zoom, Microsoft Teams, Google Meet, Webex, Slack and others) often remember the user's last camera setting, or turn the camera on by default when a meeting starts. Once macOS has granted an app camera permission, nothing stops that app from showing your live video the moment you join. People get caught on camera when they don't expect it: in a home setting, before they're ready, or in a meeting they thought was audio-only.

Older laptops had a physical shutter or tape over the lens. Recent Macs have no shutter, and tape can damage the display when the lid closes. Users need a **software shutter**: the camera stays private by default and opens only when they deliberately approve it, one session at a time.

## 3. Product vision

> **OffSight works like a physical camera shutter, in software.** Every meeting app sees a placeholder image instead of your face until you explicitly say "go live" for that app, for that session. When the session ends, the shutter closes again on its own.

## 4. Glossary

| Term | Meaning |
|------|---------|
| **Meeting app** | Any app that uses the camera for video calls. Examples: Zoom, Teams, Webex, Slack, FaceTime, or a web browser running Google Meet or Teams on the web. |
| **Live feed** | Real video from a physical camera: the built-in FaceTime camera, an external USB webcam, or Continuity Camera. |
| **Placeholder** | The default graphic OffSight sends to a meeting app in place of the live feed. |
| **Camera session** | The span during which one meeting app is continuously using the camera. It starts when the app begins receiving video and ends when the app stops, subject to a grace period (see UR-12). |
| **Approval** | The user's explicit decision to let **one** meeting app receive the live feed for **one** camera session. |
| **Shutter closed / open** | Closed means the placeholder is being sent. Open means the live feed is being sent. |

## 5. Users and personas

| Persona | Description | Main need |
|---------|-------------|-----------|
| **Remote worker** | Works from home and is in back-to-back calls on Zoom, Teams and Meet. | Never appear on camera by accident while joining calls quickly. |
| **Privacy-conscious user** | Distrusts apps that switch the camera on by themselves. | A guarantee that no app sees live video without their say-so. |
| **Executive / public-facing professional** | Joins external calls with clients, press or customers. | Stay off camera until they're ready to be seen. |
| **Parent / shared-space user** | Takes calls where family members or the background may be visible. | Check the shot before going live. |

## 6. Scope

### 6.1 In scope (v1)
- macOS desktop utility running from the menu bar.
- Camera (video) protection for all meeting apps on the Mac.
- Approval per app and per session, with a live preview.
- A default placeholder graphic, which the user can replace with their own.
- Status indicator, quick toggles and keyboard shortcuts.

### 6.2 Out of scope (v1)
- Windows, Linux, iOS and iPadOS.
- Microphone protection (candidate for a later version).
- Screen-sharing protection.
- Video effects: background blur, filters, avatars.
- Enterprise fleet management (MDM-managed policy). Candidate for a later version.

## 7. User stories

1. *As a user, I want every meeting app to show a placeholder instead of my face by default, so I'm never on camera by accident.*
2. *As a user, I want a clear prompt when an app starts using my camera, so I can decide whether to go live.*
3. *As a user, I want to see a private preview of my live camera before approving, so I can check how I look and what's behind me.*
4. *As a user, I want my approval to last only for the current session, so I don't stay unprotected in the next meeting.*
5. *As a user, I want to switch back to the placeholder instantly at any time, so I can drop off camera in an emergency.*
6. *As a user, I want to see at a glance whether any app is getting my live feed, so I always know my camera status.*
7. *As a user, I want to pick my own placeholder image, so what others see looks professional or personal.*

## 8. Functional requirements

Priority uses MoSCoW: **M** = Must, **S** = Should, **C** = Could, **W** = Won't (this release).

### 8.1 Default protection (shutter closed by default)

| ID | Requirement | Priority |
|----|-------------|----------|
| UR-01 | When a meeting app starts using the camera through OffSight, it **must receive the placeholder** and never the live feed until the user approves. | M |
| UR-02 | Default protection **must apply whatever the meeting app's own settings say**: "Turn on my video when joining", the camera-on default, and so on. | M |
| UR-03 | Default protection **must apply even if macOS has already granted the app camera permission**. The macOS permission and OffSight's approval are separate. | M |
| UR-04 | OffSight **must fail closed**. If it hits an error, loses the camera, can't tell what state it's in, or restarts, it must send the placeholder (or no video) rather than the live feed. | M |
| UR-05 | The placeholder **must be sent at a steady frame rate and resolution** so meeting apps treat it as a working camera and don't show an error or fall back to another camera on their own. | M |

### 8.2 Per-session approval

| ID | Requirement | Priority |
|----|-------------|----------|
| UR-06 | When a meeting app starts a camera session, OffSight **must show an approval prompt** naming the app (name and icon). | M |
| UR-07 | The prompt **must give at least two choices**: **"Go live for this session"** and **"Keep placeholder"**. | M |
| UR-08 | The prompt **must show a live preview** of the camera. Only the user sees it locally, and it is not sent to the meeting app. | M |
| UR-09 | If the user ignores or dismisses the prompt, the **shutter must stay closed**. The safe choice is always the default. | M |
| UR-09a | An unanswered prompt **must expire** after a user-set period and close itself, leaving the app on the placeholder. The user can set the period from **5 to 120 seconds**; the default is **30 seconds**. A prompt must never expire into approval. | M |
| UR-10 | Approval **must apply only to the app named in the prompt**. Approving Zoom must not give Teams or a browser the live feed. | M |
| UR-11 | Approval **must end automatically when the camera session ends**. The next session for the same app must ask again. There must be **no "always allow" option**. | M |
| UR-12 | A camera stop and restart by the same app within the **grace period** (for example, switching cameras in the app or a short reconnect) **must not trigger a new prompt**, and keeps the approval state it had. The default grace period is **15 seconds**; the user can set it from **5 to 300 seconds**. Once the grace period passes with the camera stopped, the session ends and its approval is discarded. | M |
| UR-13 | If the user picks "Keep placeholder" or the prompt expires, they **must be able to go live later in the same session** from the menu bar without restarting video in the meeting app. | M |
| UR-14 | The approval prompt **must not be easy to approve by accident**. For example, it must not grab keyboard focus in a way that a stray Return or Space keypress approves it. | M |
| UR-15 | If several apps start sessions at the same time, each **must get its own prompt or prompt entry**, and each is approved separately. | S |

### 8.3 Revoking access and quick control

| ID | Requirement | Priority |
|----|-------------|----------|
| UR-16 | The user **must be able to close the shutter instantly** (go back to the placeholder) for any app or all apps during a session, from the menu bar. | M |
| UR-17 | OffSight **should offer a global keyboard shortcut** that closes the shutter for all apps (a "panic button"). The user can change it. | S |
| UR-18 | OffSight **could offer a global keyboard shortcut** to go live for the app currently being prompted. | C |
| UR-19 | Closing the shutter **must take effect within 250 ms**. The meeting must not drop and the app must not show a camera error. | M |

### 8.4 Status and awareness

| ID | Requirement | Priority |
|----|-------------|----------|
| UR-20 | A **menu bar icon must always show the current state**: idle (no app using the camera), protected (apps getting the placeholder), **live** (at least one app getting the live feed), **unprotected** (bypass detected, see UR-35a), or **paused** (see UR-41). | M |
| UR-21 | The live state **must stand out visually** from the other states (different color and shape), so color-blind users can tell them apart too. | M |
| UR-22 | The menu **must list each app currently using the camera**, with its state (placeholder or live) and how long the session has lasted. | M |
| UR-23 | OffSight **should show a notification** when a session goes live and when it ends. | S |
| UR-24 | OffSight **could keep a local activity history** (which app, when, approved or denied). The history stays on the Mac and the user can clear it. | C |

### 8.5 Placeholder graphic

| ID | Requirement | Priority |
|----|-------------|----------|
| UR-25 | OffSight **must ship with a clean, neutral default placeholder** (for example, the OffSight logo with "Camera off"). | M |
| UR-26 | The user **must be able to choose a custom image** (PNG, JPEG or HEIC) as the placeholder. | M |
| UR-27 | The user **could choose a generated placeholder**: initials or a name on a solid background. | C |
| UR-28 | The placeholder **must look correct in the main aspect ratios** (16:9, 4:3) and **must not appear mirrored or badly cropped** in Zoom, Teams or Meet. | M |

### 8.6 Camera sources

| ID | Requirement | Priority |
|----|-------------|----------|
| UR-29 | OffSight **must work with the built-in camera** of supported Macs. | M |
| UR-30 | OffSight **should work with external USB/UVC webcams and Continuity Camera** (iPhone). | S |
| UR-31 | The user **should be able to choose which physical camera** OffSight uses as the live feed. | S |

### 8.7 Meeting-app coverage

| ID | Requirement | Priority |
|----|-------------|----------|
| UR-32 | OffSight **must work with**: Zoom (desktop), Microsoft Teams (desktop), and Google Meet in Chrome and Safari. | M |
| UR-33 | OffSight **must also work with**: Webex, Slack huddles, Teams and Meet in Edge, Arc and Firefox, and FaceTime. | M |
| UR-34 | For browser-based meetings, **one approval covers the whole browser** for the session, and the approval prompt **must name the browser**. | M |
| UR-34a | On a best-effort basis, the prompt and menu **should also show the tab title or website** (for example, meet.google.com). If it can't be determined, OffSight shows the browser name alone and works normally otherwise. | S |

### 8.8 Bypass awareness

| ID | Requirement | Priority |
|----|-------------|----------|
| UR-35 | If a meeting app is using a **physical camera directly** and not through OffSight (so it is unprotected), OffSight **must detect this and warn the user**, with a one-click guide to fix it. | M |
| UR-35a | While a bypass is detected, the **menu bar icon must show a distinct "unprotected" indicator**, using shape or badge and not color alone. This indicator takes priority over all other states and stays until the bypass ends. Where macOS reveals it, the menu names the app responsible. | M |
| UR-36 | Onboarding **must guide the user** to set OffSight up as the camera in each installed meeting app it supports. | M |

### 8.9 Onboarding and settings

| ID | Requirement | Priority |
|----|-------------|----------|
| UR-37 | First run **must explain** what OffSight does, ask for any macOS permissions it needs (with a reason for each), and confirm that protection is active. | M |
| UR-38 | OffSight **must offer "Launch at login"**, turned **on** by default. | M |
| UR-39 | Settings **must cover**: placeholder choice, physical camera source, keyboard shortcuts, notifications, grace period (within safe limits), and launch at login. | M |
| UR-40 | OffSight **must not provide any way to exempt an app** from per-session approval: no allow-list and no "Always allow". This is excluded on purpose. | M |
| UR-41 | The user **must be able to pause OffSight** (all apps get the live feed with no prompts) only through an explicit action with a time limit (for example, 1 hour). The menu bar must show a clear "Protection paused" state, and protection must resume automatically when the time limit ends. | C |

## 9. Non-functional requirements

### 9.1 Privacy and security

| ID | Requirement | Priority |
|----|-------------|----------|
| NFR-01 | Video frames **must never leave the Mac** through OffSight, and **must never be written to disk**. | M |
| NFR-02 | OffSight **must make no network requests** except an optional update check, which the user can turn off. | M |
| NFR-03 | There **must be no analytics or telemetry** by default. | M |
| NFR-04 | Approval decisions **must come only from real user input**. Other apps, scripts or automation must not be able to approve a session on the user's behalf. | M |
| NFR-05 | Only the user can see the preview in the approval prompt, and it must not be captured by screen sharing where macOS allows that to be prevented. | S |

### 9.2 Performance

| ID | Requirement | Priority |
|----|-------------|----------|
| NFR-06 | The live feed through OffSight **must support at least 720p at 30 fps**, and **should support 1080p at 30 fps**. | M / S |
| NFR-07 | OffSight **must add no more than 1 frame (~33 ms) of latency** to the live feed. | M |
| NFR-08 | CPU use while idle **must be under 1%**. While passing the live feed, it **should be under 5%** on Apple silicon. | M / S |
| NFR-09 | The approval prompt **must appear within 500 ms** of a session starting. | M |

### 9.3 Reliability and compatibility

| ID | Requirement | Priority |
|----|-------------|----------|
| NFR-10 | OffSight **must support macOS 13 (Ventura) and later**: on Apple silicon for all versions, and on Intel Macs for every version that still runs on Intel. This is the oldest version that supports all required capabilities; see §12, Q6. | M |
| NFR-11 | OffSight **must recover by itself** if it crashes, staying fail-closed the whole time (see UR-04). | M |
| NFR-12 | Sleep/wake, lid close/open, display changes and plugging or unplugging a camera **must not leave any app on the live feed without approval**. | M |

### 9.4 Usability and accessibility

| ID | Requirement | Priority |
|----|-------------|----------|
| NFR-13 | All controls **must be usable by keyboard and VoiceOver**. | M |
| NFR-14 | The approval prompt **must be readable in one glance**: app name, a clear question, and two clearly labeled buttons. | M |
| NFR-15 | Status **must not be shown by color alone** (see UR-21). | M |
| NFR-16 | OffSight **should support light and dark mode**. | S |

### 9.5 Distribution

| ID | Requirement | Priority |
|----|-------------|----------|
| NFR-17 | OffSight **must be distributed through the Mac App Store and a Homebrew cask** in its first release. The Homebrew build is Developer ID–signed and notarized. Both builds are signed with the project's Apple Developer account. | M |
| NFR-17a | Signing credentials (certificates, private keys, provisioning profiles, App Store Connect API keys, passwords) **must never be committed to the repository**. They are supplied only at build time from a secure store (for example, CI encrypted secrets or the developer's Keychain). The repository must guard against accidental commits. | M |
| NFR-18 | OffSight **must uninstall cleanly**, removing any camera components it installed, with documented steps or a built-in uninstaller. | M |
| NFR-19 | OffSight is released **open source under the MIT License**. | M |

## 10. Key user flows

### Flow A: Joining a meeting (happy path)
1. The user joins a Zoom meeting. Zoom has "turn on video when joining" switched on.
2. Zoom starts the camera. **OffSight sends the placeholder** and other participants see the "Camera off" graphic.
3. The OffSight prompt appears: *"Zoom wants to use your camera. [preview] — Keep placeholder / Go live for this session."*
4. The user checks the preview and clicks **Go live for this session**.
5. Zoom gets the live feed and the menu bar icon switches to **Live**.
6. The meeting ends and Zoom stops the camera. After the grace period the session ends and the approval is discarded.

### Flow B: The next meeting
1. The user joins another Zoom meeting an hour later.
2. **Placeholder by default again**, and a new prompt appears. The earlier approval does not carry over.

### Flow C: Dropping off camera mid-meeting
1. While live, the user presses the panic shortcut or clicks **Close shutter** in the menu.
2. All apps switch to the placeholder within 250 ms. The meeting carries on without interruption.
3. The user can go live again from the menu for the same session.

### Flow D: Ignoring the prompt
1. The user joins a Teams call and ignores the prompt.
2. After the expiry period (30 seconds by default), the prompt closes itself and Teams stays on the placeholder.
3. Teams keeps showing the placeholder for the whole call. The user can still go live from the menu bar at any time.

### Flow E: Unprotected app detected
1. Webex is set to use the "FaceTime HD Camera" directly.
2. The menu bar icon switches to the **unprotected** indicator. OffSight also warns: *"Webex is using your camera directly and isn't protected. Switch Webex to OffSight Camera."* The warning includes a link to step-by-step instructions.

## 11. Constraints and assumptions

- **C1. Platform limits.** macOS doesn't let a third-party utility silently intercept or replace another app's access to the built-in camera. OffSight will most likely show up to meeting apps as a **camera device of its own** (for example, "OffSight Camera"), and the user selects it once in each meeting app. This affects onboarding (UR-36) and bypass detection (UR-35). The architecture document will confirm the approach.
- **C2.** The user is assumed to be the Mac's administrator, or able to approve installing a system camera extension.
- **C3.** "Session" is defined from the camera's point of view: an app starting and stopping video. OffSight has no reliable access to calendar events or meeting IDs.
- **C4.** For browser-based meetings, macOS reports the browser as the app using the camera. That's why approval covers the whole browser (UR-34) and the tab or site name is best effort only (UR-34a).
- **C5.** Mac App Store builds run in Apple's App Sandbox and go through App Review. Some features, especially bypass detection (UR-35/35a) and global shortcuts (UR-17), must be checked against sandbox rules. The architecture document will confirm each one and name any feature that differs between the App Store and Homebrew builds.
- **C6.** On macOS, apps that use OffSight Camera can be identified, but an app using a physical camera directly may only show up as "camera in use by another app". Naming the app responsible for a bypass is therefore best effort (UR-35a).

## 12. Review decisions (v0.2–v0.3)

All open questions from v0.1 are resolved:

| # | Question | Decision | Reflected in |
|---|----------|----------|--------------|
| Q1 | Browser approvals | One approval covers the whole browser for the session. The tab or site name is shown on a best-effort basis. | UR-34, UR-34a |
| Q2 | Prompt expiry | An unanswered prompt expires into safe mode (placeholder only). The user sets the expiry from 5 to 120 seconds; the default is 30 seconds. | UR-09a |
| Q3 | Grace period | 15 seconds by default; the user can set it from 5 to 300 seconds. | UR-12 |
| Q4 | App exemptions | No exemptions of any kind. | UR-40 |
| Q5 | Microphone protection | Deferred to v2. | §6.2 |
| Q6 | Minimum macOS | **macOS 13 Ventura**, the oldest version that supports every required capability. See the rationale below. | NFR-10 |
| Q7 | Distribution | Mac App Store and Homebrew first, signed with the project's Apple Developer account. Credentials are never stored in the repository. | NFR-17, NFR-17a, C5 |
| Q8 | Timed "Pause protection" | Kept. | UR-41 |

Further changes in this review:
- UR-08, UR-12, UR-26 and UR-33 are now **Must**.
- New requirement **UR-35a**: the menu bar icon shows an "unprotected" indicator while a bypass is detected. Bypass detection itself (**UR-35**) is now **Must**, because the new indicator depends on it.
- New requirement **UR-09a** (prompt expiry), and **UR-34** split into UR-34 (browser-wide approval) and UR-34a (best-effort tab or site name).
- New requirement **NFR-17a** (no signing credentials in the repository). A `.gitignore` covering credential files has been added.

### Q6 rationale: why macOS 13 Ventura

| Version | What it means for OffSight |
|---------|----------------------------|
| **Before 12.3** | The only way to offer a virtual camera is the legacy "DAL plug-in". Apple removed support for DAL plug-ins in macOS 14.1, they can't be sold on the Mac App Store, and they're a known security weakness. Supporting them would mean building and maintaining **a second, separate camera component**. **Not viable.** |
| **12.3 – 12.x** | Modern Camera Extensions first appear in 12.3. However, some of the system features OffSight needs only arrive in macOS 13: the modern launch-at-login API (UR-38) and the menu bar app framework (UR-20). Shipping products such as OBS and AJA treat 13.0 as the practical minimum for their camera extensions. Supporting 12.x would add workarounds for little gain. **Not recommended.** |
| **13 Ventura** | Camera Extensions plus all the system features above are available. It supports Macs from 2017 onward and covers every Must requirement. **Recommended minimum.** |
| **14 and later** | No capability we need is added. Raising the minimum would only drop users. |

**Trade-off to note:** Apple usually releases security updates only for the current macOS and the two before it, so 13 and 14 no longer receive them. Supporting them adds two versions to the test matrix, and they may need small workarounds for older behavior. If that cost turns out to be too high, we can raise the minimum to macOS 14 without changing any user requirement. The architecture document will confirm macOS 13 with a prototype on real hardware.

## 13. Acceptance criteria (summary)

The product meets these requirements when, on a supported Mac:

1. With Zoom, Teams and Google Meet (Chrome and Safari) set to use OffSight, every new camera session shows the placeholder to remote participants until the user approves.
2. An approval given in one session is **not** applied to the next session or to any other app.
3. Ignoring, dismissing or timing out the prompt never results in live video.
4. Killing the OffSight app, sleeping and waking the Mac, or unplugging the camera never results in live video without approval.
5. The panic shortcut switches every app to the placeholder within 250 ms without dropping the call.
6. The menu bar icon correctly shows idle, protected, live, unprotected (bypass) and paused states, and the states can be told apart without relying on color.
7. An unanswered prompt expires into the placeholder within the configured period (5–120 seconds), and never into live video.
8. A meeting app using a physical camera directly triggers the unprotected indicator for as long as the bypass lasts.
9. No video frames are written to disk or sent over the network by OffSight (verified by inspection and network monitoring).

## 14. Approval

| Role | Name | Decision | Date |
|------|------|----------|------|
| Product owner | Project owner (astatine-) | ☑ Approved (v0.3) | 2026-10-11 |

*Approved. The Architecture & Implementation Approach document is `docs/02-architecture-and-implementation.md`.*
