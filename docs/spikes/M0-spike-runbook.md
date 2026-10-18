# M0: First run & spike runbook (built-in camera)

This runbook gets the M0 build running on your Mac with the **built-in camera**. It then walks through the spike checks that need real hardware. Report results by filling in the table at the end and pasting the **Copy diagnostics** output.

> The M0 build is a working vertical slice: placeholder by default, a per-session prompt with preview, go live, close shutter, and bypass detection. It is **not** the finished product. Settings, onboarding, shortcuts and the custom placeholder come in later milestones.

## 1. One-time setup

1. **Use full Xcode for command-line builds:** `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`, then `sudo xcodebuild -license accept` and `xcodebuild -runFirstLaunch`. Check with `xcodebuild -version`.
1. **Xcode account:** Xcode → Settings → Accounts → add the Apple ID that belongs to team **83QJANVRBL**.
2. **XcodeGen:** `brew install xcodegen`
3. **App ID:** make sure `com.storiinnovations.offsight` has the **System Extension** capability (setup runbook step 2). Xcode's automatic signing may do this for you on the first build.
4. Clone the repo and check out the M0 branch.

## 2. Build, install, run

```bash
./scripts/dev-install.sh
```

This generates the Xcode project, builds a development-signed app, copies it to `/Applications` (system extensions only activate from there) and launches it.

On first launch:
1. macOS shows **"System Extension Blocked"** or asks you to allow it. Open System Settings and allow **OffSight**:
   - macOS 15 and later: *General → Login Items & Extensions → Camera Extensions*
   - macOS 13–14: *Privacy & Security*, near the bottom
   The OffSight menu also has an **Approve OffSight Camera in System Settings…** item.
2. Allow **camera access** for OffSight when asked.
3. The menu bar shows a camera-with-slash icon. Its menu should read **Camera extension: Connected**.

To watch the logs live while testing:

```bash
log stream --predicate 'subsystem == "com.storiinnovations.offsight"' --level info
```

### After updates

`dev-install.sh` replaces the camera extension only when the extension's code has changed. App-only changes leave it alone. When the extension *is* replaced, macOS stops the old one but may not start the new one until the Mac restarts. The script says so, and the OffSight menu then shows **"Installed but not running — restart the Mac if this persists"**. Restart once and it comes up.

## 3. Basic flow (Zoom first)

| Step | Expected |
|------|----------|
| In Zoom → Settings → Video → Camera, choose **OffSight Camera** | The preview in Zoom shows the dark **"Camera off · Protected by OffSight"** placeholder. The menu bar icon changes to *protected* (filled camera with slash). |
| Start or join a test meeting with video on | The **OffSight prompt** appears top-right with a **live preview** of you. Zoom still shows the placeholder. |
| Wait without clicking | The countdown reaches 0, the prompt closes, and Zoom **stays on the placeholder**. |
| Menu → **Go live for Zoom (this session)** | Zoom shows your live video within about a second. The icon turns into a red filled camera. |
| Menu → **Close shutter for Zoom** | Zoom goes back to the placeholder straight away, and the call stays connected. |
| Leave the meeting, wait more than 15 s, start a new one | You are prompted again; the earlier approval is gone. |
| Stop and start your video in Zoom within 15 s | No new prompt; the earlier decision is kept. |

Then repeat the flow with **Teams**, **Webex** and **Google Meet in Chrome** (and in Safari if convenient).

## 4. Spike checks

| ID | Check | How |
|----|-------|-----|
| S2 | **Client identity:** each app is named correctly in the prompt and menu. | Copy diagnostics while each app is using the camera. Look at *Clients* (signing IDs) and *Resolved apps*. |
| S2 | **Start/stop signals:** turning video off in an app ends its session; leaving and rejoining after more than 15 s prompts again. | As in §3. Note any app where this doesn't happen. |
| S2 | **Property notifications:** *Snapshot listener callbacks* in diagnostics is above 0. | Copy diagnostics after a few start/stops. |
| S3 | **Format compatibility:** every app lists OffSight Camera and shows the placeholder correctly (not stretched, not upside-down). | Note what each app shows. Zoom mirrors your *self-view* by default; others see it the right way round. |
| S4 | **Bypass detection:** in one app, pick the **FaceTime HD Camera** directly. The OffSight icon should switch to a **warning triangle** within about 1 s, and the menu explains it. OffSight's own preview must *not* trigger it. | Watch the icon. |
| S5 | **Frame tag & sink authentication:** with an app live, diagnostics shows *auth mode: codesign*, *live forwarded* increasing, and few *stale generation* or *missing tag* rejects. | Copy diagnostics while live. If the auth mode is `signingID-fallback…`, the code-signature check doesn't work inside the extension sandbox. Note that, because it's a key spike result. |
| S5 | **Generation fence:** while Zoom is live, open the camera in Teams. **Both** must switch to the placeholder at once, and Teams is prompted. | Watch both apps. |
| T5 | **Fail closed:** while live, quit OffSight from its menu. Zoom must switch to the placeholder within a fraction of a second. | Relaunch OffSight afterwards. |
| S6 | Launch at login and crash restart. | Not in M0. Later milestone. |
| S7 | **Preview hidden from screen sharing:** share your screen in a meeting while the prompt is showing. Is the prompt visible to others? | Note the result. |

## 5. Results to send back

Copy this table, fill it in, and paste it together with the **Copy Diagnostics** output (OffSight › Settings › Advanced) for each app:

| App | Named correctly? | Placeholder OK? | Prompt shown? | Go live works? | Close shutter OK? | New prompt after rejoin? | Notes |
|-----|------------------|-----------------|---------------|----------------|-------------------|--------------------------|-------|
| Zoom | | | | | | | |
| Teams | | | | | | | |
| Webex | | | | | | | |
| Meet (Chrome) | | | | | | | |
| Meet (Safari) | | | | | | | |

Also tell me your Mac model, macOS version, and whether the bypass, fail-closed and screen-share checks passed.

## 6. Removing the dev build

OffSight menu → **Remove camera extension**, then quit OffSight and delete `/Applications/OffSight.app`.
