# OffSight — App Store submission notes

How to upload a build, what to put in App Store Connect, and the notes for App Review.

## Upload a build

```
scripts/appstore-upload.sh                 # version from Config/Base.xcconfig
VERSION=1.0.0 scripts/appstore-upload.sh   # or set it
```

The script archives the `AppStore` configuration, checks the archive (privacy manifest, embedded camera extension, App Sandbox), and uploads it with automatic signing. Xcode must be signed in to an account with the App Manager role, or set `ASC_KEY_PATH`, `ASC_KEY_ID` and `ASC_ISSUER_ID` for an App Store Connect API key. The build appears in **TestFlight** after processing.

For the first build (spike S1): add it to an **internal** group first and walk through the reviewer steps below on that build yourself. Then add it to an **external** TestFlight group. That sends it through Beta App Review, which tells us early whether App Review accepts the camera-extension design.

Installing a TestFlight build replaces the copy in /Applications, including a Debug build from `scripts/dev-install.sh`, and macOS may ask again to allow the camera extension. Run `scripts/dev-install.sh` again to go back to the Debug build.

**TestFlight › Test Information** (external testing):

| Field | Value |
|---|---|
| Beta App Description | OffSight is a camera shutter in software: meeting apps see a "Camera off" picture until you approve them for the current call. |
| What to Test | Choose OffSight Camera in your meeting apps (Zoom, Teams, Google Meet, Webex, Slack, FaceTime). Check that each app gets the placeholder until you click Go live, that Close all shutters (⌃⌥⌘O) works, and that the next call asks again. Report anything where an app sees live video without your approval. |
| Feedback Email | the project's support address |
| Privacy Policy URL | as in the table below |

**Beta App Review Information:** contact details, no sign-in, and the notes from "Notes for App Review" below.

## App Store Connect fields

| Field | Value |
|---|---|
| Name | OffSight |
| Subtitle (30 chars max) | A camera shutter, in software |
| Category | Utilities |
| Privacy Policy URL | `https://storiinnovations.github.io/offsight/privacy.html` (or the custom domain) |
| Support URL | `https://storiinnovations.github.io/offsight/support.html` |
| Marketing URL | `https://storiinnovations.github.io/offsight/` |
| App Privacy | **Data Not Collected** |
| Age rating | 4+ (no objectionable content) |
| Encryption | Not used (`ITSAppUsesNonExemptEncryption` = NO in Info.plist) |
| Copyright | Match the LICENSE holder |

**Description (draft):**

> OffSight is a camera shutter in software. Meeting apps see a “Camera off” picture until you say Go live, for that app, for that call. When the call ends, the shutter closes again on its own.
>
> • Choose OffSight Camera once in Zoom, Teams, Google Meet, Webex, Slack or FaceTime.
> • When an app turns the camera on, OffSight asks you first, with a private preview only you can see.
> • Approval lasts for one call. There is no “always allow”.
> • Close every shutter at once from the menu bar or with a keyboard shortcut.
> • Use the OffSight picture, your own image, or your initials as the placeholder.
> • If anything goes wrong, apps keep the placeholder: OffSight fails safe.
> • Everything happens on your Mac. OffSight collects no data and has no network access.
>
> OffSight is open source (MIT License) and provided as is.

**Keywords:** camera,privacy,webcam,shutter,zoom,teams,meet,video call,placeholder,cover

**Screenshots** (2880×1800 or 1440×900): the approval prompt over a meeting app; the menu with a live and a protected session; the placeholder in a meeting app; Settings › Camera.

## Notes for App Review

Paste into **App Review Information › Notes**:

> OffSight is a menu bar app (no Dock icon; look for the iris icon at the top right). It provides a camera extension, "OffSight Camera", which meeting apps choose as their camera. Until the user approves an app for the current call, that app receives a "Camera off" placeholder picture instead of the real camera.
>
> To review:
> 1. Open OffSight. The welcome guide asks to allow the camera extension: System Settings › General › Login Items & Extensions › Camera Extensions › OffSight (macOS 15+), or Privacy & Security › Allow (macOS 13–14). Then allow camera access.
> 2. Open Photo Booth and choose Camera › OffSight Camera. Photo Booth shows the "Camera off" placeholder, and OffSight shows a prompt near the top right of the screen with a private preview.
> 3. Click "Go live for this session": Photo Booth now shows the real camera.
> 4. In the OffSight menu, click "Close all shutters": Photo Booth shows the placeholder again.
> 5. Quit Photo Booth. Open QuickTime Player, choose File › New Movie Recording, and pick OffSight Camera in the menu next to the record button: OffSight asks again, this time for QuickTime Player. Approval is per app and lasts one camera session; there is no "always allow".
>
> Note on Photo Booth: if Photo Booth is opened with OffSight Camera already chosen, Photo Booth sometimes doesn't start the camera and shows a black picture. Choosing Camera › OffSight Camera again starts it. Meeting apps such as Teams and Google Meet aren't affected.
>
> If the menu says "Installed but not running", macOS needs a restart to start the camera extension; this can happen right after installing or updating.
>
> Why the extension: a camera extension is Apple's supported way to provide a camera to other apps. OffSight relays the real camera through it only after the user approves each app for each call.
>
> Privacy: no data is collected and the app has no network entitlement. Video is never recorded or stored. Launch at login is offered as a pre-ticked option on the last welcome step (the user's choice), and is implemented as a launch agent so OffSight also restarts if it quits unexpectedly.

**Sign-in required:** No. **Demo account:** not applicable.

## Guidelines to keep in mind

- **2.4.5 (Mac App Store):** sandboxed ✓; nothing installed outside the app except the system extension it embeds ✓; launch at login only with consent ✓ (onboarding).
- **5.1.1 (privacy):** camera use explained in the permission text and the welcome guide ✓; privacy policy URL ✓.
- **2.3 (accurate metadata):** screenshots must show the real app.
- **The App Store build shows the browser name only** for browser meetings; the tab or site name (UR-34a) is in the Homebrew build only, because it needs Apple Events access to browsers.
