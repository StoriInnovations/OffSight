# macOS virtual camera products: architecture, placeholder/"privacy" image behaviour, and alternatives to a virtual-camera shutter

Research date: 2026-10-12. Several vendor help sites (help.elgato.com, help.airtime.com, camo.com, docs.ndi.video, docs.vdo.ninja, obsproject.com) could not be fetched from the research sandbox because the egress proxy blocked them. Claims from those sites come from search-engine excerpts and are marked "(search excerpt)". Primary-source code was read directly for OBS Studio (cloned 2026-10-08 HEAD `7d98beb`), Objective-See OverSight (HEAD 2024-09-24) and ldenoue/cameraextension (2022-07-04).

## Q1. Which products use a CMIOExtension and which use a legacy DAL plugin; do they relay frames from an app through a sink stream or generate them inside the extension?

### Takeaway
Since macOS 14.1 every maintained product has moved to a CoreMediaIO Camera Extension, because DAL plugins no longer load by default. The common design, used by OBS and the reference samples, is one source stream plus one sink stream. The host app pushes live frames into the sink. The extension draws its own placeholder from a timer only while the sink is idle. Abandoned products (Snap Camera, CamTwist, EpocCam, Logi Capture, older XSplit VCam for Mac) remained DAL-only and broke on macOS 14.1+.

### Cited Findings
- **Apple platform change.** Starting with macOS Sonoma 14.1, only cameras and video output devices that use modern system extensions are supported. Legacy support can be restored from macOS Recovery with a `system-override` command, but then "the camera privacy indicator won't display in the menu bar while a camera with older software is in use." — [Apple Support HT213969 / 108387](https://support.apple.com/HT213969) (search excerpt)
- **Apple's rationale.** Camera extensions replace DAL plug-ins, which loaded untrusted code into the client app's process. Camera extensions have been available since macOS 12.3. — [WWDC22 "Create camera extensions with Core Media IO"](https://developer.apple.com/videos/play/wwdc2022/10022/)
- **OBS Studio (open source; read directly).** The tree has both `src/dal-plugin` (legacy) and `src/camera-extension` (Swift CMIOExtension). The extension's device has two streams: `OBSCameraStreamSource` (`direction: .source`) and `OBSCameraStreamSink` (`direction: .sink`). When OBS's "Start Virtual Camera" starts the sink, a consume timer running at 3x the frame rate calls `consumeSampleBuffer(from:)` and forwards each buffer to the source stream with `stream.send(...)`. When the sink is not running, a placeholder timer generates frames inside the extension. — [obs-studio plugins/mac-virtualcam/src/camera-extension/OBSCameraDeviceSource.swift](https://github.com/obsproject/obs-studio/blob/master/plugins/mac-virtualcam/src/camera-extension/OBSCameraDeviceSource.swift)
- **OBS version support.** OBS says the virtual camera in OBS 29.1 and earlier is not compatible with macOS 14 and recommends OBS 30.0 or newer. — [OBS KB: Virtual Camera Troubleshooting](https://obsproject.com/kb/virtual-camera-troubleshooting) (search excerpt)
- **OBS sandboxing.** The OBS camera extension is sandboxed and shares an app group `$(TeamIdentifierPrefix)com.obsproject.obs-studio`. Its Info.plist declares `CMIOExtensionMachServiceName` plus fixed device, source and sink UUIDs. — [obs-studio camera-extension/cmake/macos](https://github.com/obsproject/obs-studio/tree/master/plugins/mac-virtualcam/src/camera-extension/cmake/macos)
- **ldenoue/cameraextension sample** (basis of the App Store app Screegle). It uses the same source+sink design: "the sink stream is used by our own app to send frames to the virtual camera, which immediately forwards them to its source stream; when the sink stream is not started, the camera simply shows a black frame with a text (+ number of seconds)." The app polls through the CoreMediaIO C API whether the source stream has started, and only then begins sending frames to the sink. It claims these cameras "work in any app on macOS (including Apple's own apps such as FaceTime, QuickTime, Safari, etc.)." — [github.com/ldenoue/cameraextension README](https://github.com/ldenoue/cameraextension)
- **Sink stream vs XPC.** An Apple forum thread discusses using a sink stream instead of XPC to move frames from app to extension. It notes that an IOSurfaceRef cannot be sent directly over NSXPCConnection, but an IOSurface object can. — [Apple Developer Forums 706184](https://developer.apple.com/forums/thread/706184)
- **Camo (Reincubate).** Camo's release notes say macOS 14.1 removed DAL plugin support. Camo Studio warns when it detects a DAL plugin. Its installer sets up a camera extension, and Camo Studio requires macOS 12.3+, the minimum version for camera extensions. — [Camo Studio release notes](https://camo.com/support/camo/release-notes?b=20240102); [Camo downloads](https://reincubate.com/camo/downloads/) (search excerpts)
- **Airtime (formerly mmhmm).** The virtual camera is now called "Airtime". It requires macOS 13+ and ships as AirtimeCamera.dmg / AirtimeCreator.dmg. — [help.airtime.com Airtime Camera section](https://help.airtime.com/hc/en-us/sections/33869100521879-Airtime-Camera); [Airtime blog: mmhmm becomes Airtime](https://www.airtimetools.com/blog/mmhmm-becomes-airtime) (search excerpts)
- **Ecamm Live.** The virtual camera requires Ecamm Live Pro. On first use macOS blocks the newly installed extension and the user must allow it in System Settings, which is the camera-extension approval flow. — [Ecamm: Virtual camera doesn't show up in apps](https://support.ecamm.com/en/articles/3824881-virtual-camera-doesn-t-show-up-in-apps) (search excerpt)
- **Elgato Camera Hub.** Release 1.7 (28 July 2023) says the virtual camera "uses a new framework, deeply integrated by Apple into macOS," without naming the framework. A macOS 15 Sequoia help article tells users to enable Camera Hub under System Settings > General > Login Items & Extensions > Camera Extensions, which confirms it is a CMIOExtension. Release 2.0 (8 April 2025) fixed the virtual camera freezing when Camera Hub was opened or closed from the tray, and fixed "green virtual camera output in Zoom on macOS." — [Camera Hub 1.7 notes](https://help.elgato.com/hc/en-us/articles/18035635191693-Elgato-Camera-Hub-1-7-Release-Notes); [Sequoia virtual camera article](https://help.elgato.com/hc/en-us/articles/30069817477777-Elgato-Camera-Hub-How-to-enable-Virtual-Camera-on-macOS-15-Sequoia); [Camera Hub 2.0 notes](https://help.elgato.com/hc/en-us/articles/34177528821265-Elgato-Camera-Hub-2-0-Release-Notes) (search excerpts)
- **NDI Virtual Input (NDI Tools for Mac).** It installs a camera extension, which users must approve under System Settings > General > Login Items & Extensions > Camera Extensions. NDI warns of issues since its 6.1 update, often caused by multiple copies of the extension being installed. The fix is to uninstall, reboot and reinstall. Earlier "not detected after Sonoma" reports were attributed to legacy camera support being turned off. — [NDI docs: Virtual Input](https://docs.ndi.video/all/using-ndi/ndi-tools/ndi-tools-for-mac/virtual-input); [NDI FAQ: issues with Virtual Input for macOS](https://docs.ndi.video/all/faq/common-issues/im-having-issues-with-virtual-input-for-macos) (search excerpts)
- **mimoLive (Boinx).** The vendor reported that Sonoma 14.1 removed DAL support and that it was building a camera extension. — [Boinx forum](https://forum.boinx.com/t/no-more-virtual-camera-my-show-is-dead/19016) (search excerpt)
- **CamTwist.** It installs `CamTwist.plugin` into `/Library/CoreMediaIO/Plug-Ins/DAL`, so it is DAL-only. Its last release (3.4.3) was reported as 2017, from a low-authority aggregator. — [Softpedia](https://mac.softpedia.com/get/Video/CamTwist.shtml); [Zoom Community](https://community.zoom.com/meetings-2/camtwist-and-streamlabs-virtual-cameras-not-showing-up-in-zoom-on-macos-45542) (search excerpts)
- **Snap Camera.** The desktop app shut down on 25 January 2023. Before that, it conflicted on macOS 12 with Logitech's `LogiCapture.plugin` in `/Library/CoreMediaIO/Plug-Ins/DAL/`, so both were DAL plugins. — [TechRadar](https://www.techradar.com/news/snap-is-closing-its-zoom-video-filter-tool); [Snap community thread](https://community.snap.com/snapar/discussion/1127/support-for-snap-camera-macos-12-monterey-m1-intel) (search excerpts)
- **Logitech.** Logitech said Logi Capture support would end in 2022 and that G HUB, plus Logi Tune on macOS, takes over camera settings. Logitech said there were no plans for Logi Capture to support M1/M2. — [Logitech support 4412009959575](https://support.logi.com/hc/en-us/articles/4412009959575) (search excerpt)
- **EpocCam (Elgato).** It is no longer sold and gets no further updates. Its listed requirements stop at macOS Big Sur 11. — [Elgato EpocCam macOS Setup Guide](https://help.elgato.com/hc/en-us/articles/360051151552-EpocCam-macOS-Setup-Guide) (search excerpt)
- **XSplit VCam for Mac.** Its requirements page is filed under "Legacy" and lists Mojave through Monterey on Intel, with no Sonoma or later. — [XSplit VCam Mac system requirements](https://support.xsplit.com/en/article/xsplit-vcam-mac-system-requirements-v00x2t) (search excerpt)

### Inferences
- Every maintained product that works on current macOS (OBS, Camo, Airtime, Ecamm, Elgato, NDI) ships a CMIOExtension. Where code is visible (OBS, the Screegle sample), live frames arrive through a sink stream, and the "app not running/idle" image is generated inside the extension from a timer. OffSight's architecture, with the extension relaying a sink and a placeholder, is therefore mainstream. The difference most likely lies in how the placeholder frames are produced.
- Apple's 14.1 support article says restoring legacy DAL support disables the camera privacy indicator. A shutter product should not rely on DAL.

### Gaps
- I found no source confirming the internal architecture of Camo, Airtime, Ecamm or Elgato beyond "uses a camera extension": for example, whether they use a sink stream or XPC/IOSurface, or whether frames are generated in the extension. Their source is closed and no reverse-engineering write-ups were found.
- I found no information on Iriun Webcam, Krisp's camera feature or Hand Mirror's architecture. XSplit VCam's current Mac status (whether it has a camera extension) is unconfirmed.

## Q2. What pixel format, resolution and frame rate do they advertise?

### Takeaway
Only OBS and the open samples publish this. OBS's camera extension advertises exactly one format: 1920x1080, 32BGRA, fixed 60 fps. Its placeholder comes from an IOSurface-backed `CVPixelBufferPool` at that size. The older OBS DAL plugin advertised NV12 (420v) at a 1280-wide default. Commercial vendors do not document their formats.

### Cited Findings
- **OBS camera extension (read directly).**
  - `let OBSCameraFrameRate: Int = 60`.
  - The format description is `CMVideoFormatDescriptionCreate(codecType: kCVPixelFormatType_32BGRA, width: 1920, height: 1080)`.
  - The stream format sets `minFrameDuration = maxFrameDuration = 1/60`, with `validFrameDurations: nil`. One format only, and `activeFormatIndex` is always 0.
  - The pool attributes are width, height, pixel format, and `kCVPixelBufferIOSurfacePropertiesKey: [:]`, so buffers are IOSurface-backed. The pool aux attribute is `kCVPixelBufferPoolAllocationThresholdKey: 5`.
  - Source stream properties are `.streamActiveFormatIndex` and `.streamFrameDuration`.
  - The sink additionally exposes `.streamSinkBufferQueueSize = 1`, `.streamSinkBuffersRequiredForStartup = 1`, `.streamSinkBufferUnderrunCount` and `.streamSinkEndOfData`.
  - The device reports `transportType = kIOAudioDeviceTransportTypeVirtual` and `model = "OBS Camera Extension"`.

  — [OBSCameraDeviceSource.swift](https://github.com/obsproject/obs-studio/blob/master/plugins/mac-virtualcam/src/camera-extension/OBSCameraDeviceSource.swift), [OBSCameraStreamSource.swift](https://github.com/obsproject/obs-studio/blob/master/plugins/mac-virtualcam/src/camera-extension/OBSCameraStreamSource.swift), [OBSCameraStreamSink.swift](https://github.com/obsproject/obs-studio/blob/master/plugins/mac-virtualcam/src/camera-extension/OBSCameraStreamSink.swift)
- **OBS host side (read directly).** The OBS app pushes into the sink frames in OBS's output format, mapped to CoreVideo NV12 (`420v`/`420f`), I420, UYVY or P010. Unsupported formats are CPU-converted to NV12. Its pixel buffer pool is also IOSurface-backed (`kCVPixelBufferIOSurfacePropertiesKey: @{}`). The sample buffers it sends can therefore differ in pixel format from the advertised BGRA format description, which apparently still works in practice. — [obs-studio plugins/mac-virtualcam/src/obs-plugin/plugin-main.mm](https://github.com/obsproject/obs-studio/blob/master/plugins/mac-virtualcam/src/obs-plugin/plugin-main.mm)
- **OBS DAL plugin (legacy, read directly).** `DEFAULT_WIDTH 1280`. The stream format is `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`. The placeholder is drawn into a `kCVPixelFormatType_32ARGB` buffer. — [obs-studio dal-plugin/OBSDALStream.mm](https://github.com/obsproject/obs-studio/blob/master/plugins/mac-virtualcam/src/dal-plugin/OBSDALStream.mm)
- **ldenoue/Screegle sample (read directly).** It advertises `kCVPixelFormatType_32BGRA` with IOSurface-backed pool buffers, `kFrameRate = 30`, and min = max frame duration. — [ldenoue/cameraextension cameraextensionProvider.swift](https://github.com/ldenoue/cameraextension/blob/main/cameraextension/cameraextensionProvider.swift)
- **Apple forum, March 2026.** A CMIOExtension rendering `NSImage`/`CGImage` into `CVPixelBuffer`s with a 60 fps `DispatchSourceTimer` on macOS 26.2 showed a good first frame, then jitter, then a solid accent colour, with "Invalid display 0x00000000" in Console. Setting `useSoftwareRenderer` on CIContext reduced but did not fix it. Apple DTS redirected the discussion to thread 817476 without public guidance. — [Apple Developer Forums 817478](https://developer.apple.com/forums/thread/817478)

### Inferences
- OBS is the best public reference for an in-extension placeholder that clients accept: 1920x1080 32BGRA, a single format, fixed 60 fps, IOSurface-backed pool buffers, PTS from the host-time clock, and a full redraw on every tick. If OffSight's placeholder buffers differ, those differences are the first variables to test, because QuickTime is more tolerant than Photo Booth or Teams. Examples of differences: non-IOSurface buffers created with `CVPixelBufferCreate`, a different size or format from the advertised format description, sparse or one-shot sends, or reused timestamps.
- The 2026 forum report shows that AppKit drawing (`NSImage`/`NSGraphicsContext`) inside a headless extension can misbehave on macOS 26. Pre-rendering the placeholder once into raw pixel data or a CGImage, then copying bytes into each pool buffer, avoids per-frame AppKit drawing. This is an inference; the forum gave no confirmed fix.

### Gaps
- No vendor support doc, `system_profiler` dump or ioreg listing was found for Camo, Airtime, Ecamm, Elgato or NDI formats. Commercial products' advertised resolutions and frame rates remain unknown.

## Q3. How do they show a static image or "paused" state? Do they keep sending frames continuously, animate it, or add noise?

### Takeaway
Every implementation with visible code keeps a timer that sends a fresh frame at the full advertised frame rate while in placeholder mode. OBS redraws a static 1920x1080 PNG 60 times a second. The Screegle sample also draws text with a running seconds counter, so the image changes. None sends a single frame and stops. Commercial products describe status cards (Camo) or rely on the meeting app's own "video off" UI (Zoom). No vendor documents a "camera off" image that is a frozen single frame.

### Cited Findings
- **OBS (read directly).** `startStreaming()` creates a `DispatchSourceTimer` (`.strict`, user-interactive queue, leeway 0) that repeats every 1/60 s. On each tick, unless the sink has started, it does the following:
  - takes a fresh buffer from the pool;
  - locks it and wraps it in a `CGContext` (`noneSkipFirst | byteOrder32Little`);
  - draws the bundled `placeholder.png` (1920x1080 RGB) through `NSGraphicsContext`;
  - builds a `CMSampleBuffer` with `presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock())`;
  - calls `stream.send(..., hostTimeInNanoseconds: PTS)`.

  The timer is cancelled only when the last client stops. — [OBSCameraDeviceSource.swift](https://github.com/obsproject/obs-studio/blob/master/plugins/mac-virtualcam/src/camera-extension/OBSCameraDeviceSource.swift)
- **OBS placeholder customisation.** The DAL-era placeholder lived in the plugin bundle or `/Library/Application Support/obs-studio/plugin_config/mac-virtualcam/placeholder.png`. Users report that replacing it often had no effect and that the DAL path disappeared after OBS 30. The extension loads the image from its own bundle, which is not user-replaceable without breaking the signature. — [OBS forum: replace placeholder](https://obsproject.com/forum/threads/replace-obs-virtual-camera-placeholder.137182); [OBS forum: change offline image](https://obsproject.com/forum/threads/is-it-possible-to-change-the-obs-virtual-camera-offline-image.131163/) (search excerpts); [OBSDALStream.mm](https://github.com/obsproject/obs-studio/blob/master/plugins/mac-virtualcam/src/dal-plugin/OBSDALStream.mm)
- **ldenoue/Screegle sample (read directly).** A 30 fps strict timer fills black and draws `lastMessage + " \(Int(timestamp.seconds))"` on every frame. The placeholder therefore visibly changes once a second and is regenerated every frame. Timestamps come from the host clock. — [cameraextensionProvider.swift](https://github.com/ldenoue/cameraextension/blob/main/cameraextension/cameraextensionProvider.swift)
- **Camo.** The Camo FAQ says the camera shows on-screen status when video is paused, no device is connected, or Camo Studio is not running. The text is designed to read correctly whether or not the consuming app mirrors it. Camo's "Privacy" feature is different: a background blur ("cloaks your surroundings with a pleasing diffused image effect", hotkey ⌘⇧⌥P), not a camera-off frame. — [Camo FAQ](https://camo.com/support/camo/camo-faq); [Camo: adjusting video settings](https://reincubate.com/support/camo/adjusting-video-settings) (search excerpts)
- **Camo idle state.** Camo's menu-bar icon shows idle, ready, active and warning states, where idle means no device is connected or selected. Closing the window does not quit Camo; only "Quit Camo Studio" does. — [Navigating Camo's interface](https://reincubate.com/support/camo/how-to-use-camo) (search excerpt)
- **Airtime/mmhmm.** No documented "away" frame was found. Airtime's help says to open Airtime Creator or Airtime Camera before selecting "Airtime" in FaceTime (Video menu), Photo Booth or Safari. — [help.airtime.com 33869374216599](https://help.airtime.com/hc/en-us/articles/33869374216599) (search excerpt)
- **CamLoop (third party).** CamLoop is a macOS menu-bar app that loops a few seconds of recorded video through a virtual camera so the user can step away. It is a "looped live footage" approach rather than a static card. — [Product Hunt: CamLoop](https://www.producthunt.com/p/camloop/camloop) (search excerpt)
- **Zoom "Stop Video".** Zoom handles this in its own client: other participants see the user's profile picture, or a black tile with their name if none is set. The host controls whether profile pictures show. — [Zoom Community](https://community.zoom.com/meetings-2/my-profile-picture-stopped-showing-when-i-turn-off-video-during-a-meeting-23815); [Guiding Tech](https://www.guidingtech.com/show-profile-picture-instead-video-zoom-meeting) (search excerpts)
- **Elgato Camera Hub.** No software "privacy frame" was found. The Facecam Neo "privacy" feature is a physical lens shutter. — [Elgato Facecam Neo quick start](https://www.elgato.com/explorer/products/neo/facecam-neo-quick-start-guide/) (search excerpt)

### Inferences
- Published practice is to send a placeholder continuously at the advertised frame rate with host-clock timestamps, rebuilding each frame into a fresh pool buffer. Sometimes the content changes (Screegle's counter), but OBS shows a constant image works. Sending one frame, or frames with repeated or old timestamps, departs from this pattern.
- Zoom's "video off" approach (the app stops capturing and shows an avatar) is not available to a third-party camera. It does show that "camera off" UX in meeting apps comes from the meeting app, not from a frame.

### Gaps
- I found no documentation of the exact frames Camo, Airtime, Ecamm or Elgato send in a paused or idle state: their frame rate, whether they animate, or whether they add noise. No reverse-engineering posts were found. No source said any product adds dither or noise to keep encoders or clients alive.

## Q4. Known compatibility notes and support articles (Photo Booth, Teams grey screen, FaceTime black screen)

### Takeaway
Most "Photo Booth/FaceTime/Safari don't support virtual cameras" advice dates from the DAL era, when Apple apps refused to load third-party plugins. With camera extensions, vendors such as Airtime and Ecamm document use in FaceTime and Photo Booth. Remaining failures are usually setup-related: the extension not approved, duplicate extensions installed, the host app not started first, or a reboot needed. Teams virtual-camera fixes from 2020–21 involved code-signing library validation, which no longer applies to extensions.

### Cited Findings
- **VDO.Ninja's list (date unclear, likely DAL-era).** It lists Photo Booth, Safari and FaceTime as unsupported for OBS and other virtual cameras. It advises enabling OBS's Screen Recording permission, relaunching, and starting the virtual camera before opening the consuming app. — [VDO.Ninja docs](https://docs.vdo.ninja/common-errors-and-known-issues/virtual-cam-not-working-on-mac) (search excerpt)
- **OBS DAL-era issue.** Re-signing Photo Booth let the virtual camera work, but FaceTime "just shows a blank screen". An OBS maintainer said a CoreMediaIO System Extension was planned to address this. — [obs-studio issue #3967](https://github.com/obsproject/obs-studio/issues/3967) (search excerpt)
- **Camera extensions in Apple apps.** The ldenoue sample says camera-extension cameras work in FaceTime, QuickTime and Safari. Airtime documents using its camera in Safari, Photo Booth and FaceTime. — [ldenoue/cameraextension](https://github.com/ldenoue/cameraextension); [Airtime help](https://help.airtime.com/hc/en-us/articles/33869374216599) (search excerpt)
- **Ecamm.** Rebooting the Mac may be needed before FaceTime sees the virtual camera. — [Ecamm support 3824881](https://support.ecamm.com/en/articles/3824881-virtual-camera-doesn-t-show-up-in-apps) (search excerpt)
- **Airtime and macOS camera effects.** If any macOS camera effect (Portrait mode etc.) is enabled for a camera in Zoom, Meet or Teams, it is applied to all cameras, including Airtime. The fix is to quit both apps, switch to the FaceTime camera, turn off effects in the green Control Center video indicator, then switch back. — [Airtime: Prevent unwanted effects on the virtual camera feed](https://help.airtime.com/hc/en-us/articles/35745674133527) (search excerpt)
- **Teams (2020–21, DAL era).** Teams for macOS 1.4.00.8872+ fixed virtual-camera support. Earlier workarounds stripped the code signature (`codesign --remove-signature`) or used Teams in Chrome. — [mimoLive: Virtual Camera Microsoft Teams](https://mimolive.com/virtual-camera-microsoft-teams/); [MPU forum](https://talk.macpowerusers.com/t/tip-reenable-virtual-web-cams-in-macos-ver-of-microsoft-teams/19518) (search excerpts)
- **Elgato colour and freeze fixes.** Camera Hub 2.0 fixed "green virtual camera output in Zoom on macOS" and freezes when Camera Hub opens or closes. Vendors do hit client-specific rendering bugs, consistent with frame-format or pixel-buffer issues. — [Camera Hub 2.0 release notes](https://help.elgato.com/hc/en-us/articles/34177528821265-Elgato-Camera-Hub-2-0-Release-Notes) (search excerpt)
- **NDI.** Multiple installed copies of the camera extension break Virtual Input. Fix by uninstalling, restarting and reinstalling. — [NDI FAQ](https://docs.ndi.video/all/faq/common-issues/im-having-issues-with-virtual-input-for-macos) (search excerpt)
- **OBS 31 on Sequoia.** "The virtual camera is not installed" is fixed by allowing the system extension under Login Items & Extensions. — [OBS forum](https://obsproject.com/forum/threads/mac-camera-wont-work-since-installed-obs.158898/) (search excerpt)
- **Sink-stream hangs.** A developer reported a sink-stream extension receiving 420v buffers whose frames stopped after repeated connect/disconnect, with QuickTime hanging on quit. — [Apple Developer Forums, Core Media tag](https://developer.apple.com/forums/tags/core-media/?page=2&sortBy=oldest) (search excerpt; thread not opened)

### Inferences
- No source documents a case exactly like OffSight's, where a static placeholder shows grey in Photo Booth and Teams but works in QuickTime while relayed live video works everywhere. Because relayed live frames work in all three apps, the extension, approval and client support are fine. The likely culprit is how placeholder frames are built or timed, compared with the live path. Things to compare against the live path:
  - pixel format and dimensions against the advertised format description;
  - IOSurface backing;
  - colour attachments;
  - PTS and host-time monotonicity;
  - a continuous cadence versus one-off sends.
- Grey (rather than black) often means a client got no decodable frame or a format it rejects. This is an inference, not sourced.

### Gaps
- I found no vendor KB article titled "Camo not showing in Photo Booth" or "virtual camera grey in Teams" for the camera-extension era. Current Microsoft Teams (new Teams, 2024+) virtual-camera guidance for macOS was not found.

## Q5. Alternatives to a virtual camera for a "shutter" product: notifications, TCC, Screen Time, MDM, Endpoint Security; what privacy products do

### Takeaway
The privacy apps found detect camera use and optionally kill the process. None intercept frames:
- OverSight watches CoreMediaIO properties and the unified log, and its "Block" action sends SIGKILL to the process.
- Micro Snitch only alerts and logs.

System-level blocking exists only for administrators, through MDM PPPC profiles that can deny but never grant the Camera service per bundle ID. A virtual-camera shutter like OffSight is the only approach found that lets the meeting app keep running while showing a branded image.

### Cited Findings
- **OverSight detection (read directly).**
  - It registers `CMIOObjectAddPropertyListenerBlock` on each camera's running-somewhere property and reads it with `CMIOObjectGetPropertyData`.
  - To find which process is using the camera, it streams the unified log through the private OSLog API. Predicates: `subsystem=='com.apple.cmio' OR subsystem=='com.apple.coremedia'`. On macOS 13.3+ it parses `subsystem=='com.apple.cmio'` debug messages containing `CMIOExtensionPropertyDeviceControlPID = <pid>`, and it also has a `subsystem=='com.apple.SystemStatus'` path.

  — [objective-see/OverSight Application/AVMonitor.m](https://github.com/objective-see/OverSight/blob/master/Application/Application/AVMonitor.m)
- **OverSight blocking (read directly).** The notification offers Allow / Allow Always / Block. "Block" calls `kill(processID, SIGKILL)` on the process using the camera. — [AVMonitor.m](https://github.com/objective-see/OverSight/blob/master/Application/Application/AVMonitor.m)
- **CMIO property caveat.** On macOS 12, apps like iTunes and Music triggered `kCMIODevicePropertyDeviceIsRunningSomewhere` listener callbacks without actually starting the camera. — [Apple Developer Forums 697124](https://developer.apple.com/forums/thread/697124) (search excerpt)
- **Micro Snitch (Objective Development).** It notifies and logs camera and microphone activation, with no option to disable devices. A macOS Big Sur/Monterey bug falsely reported the built-in camera of M1/M2 laptops as active; Apple fixed it in Ventura. — [TidBITS 2020](https://tidbits.com/2020/07/22/feeling-paranoid-micro-snitch-tells-you-if-your-mac-is-spying-on-you/); [obdev Micro Snitch support](https://ns1.obdev.at/support/microsnitch/1j87r) (search excerpts)
- **MDM PPPC.** For the Camera service, PPPC profiles can only Deny, never Allow. Denials are per bundle ID, stored in TCC's MDM overrides, and users cannot change them in System Settings. — [Swif: macOS PPPC policy](https://help.swif.ai/en/articles/11103442-macos-privacy-preferences-pppc-policy); [Jamf community](https://community.jamf.com/t5/jamf-pro/pppc-utility-how-to-get-it-to-work/m-p/226882/highlight/true) (search excerpts)
- **Apple privacy indicator.** The menu-bar camera indicator is part of the system. Restoring legacy DAL support disables it for those devices. — [Apple Support HT213969](https://support.apple.com/HT213969) (search excerpt)
- **Windows contrast.** Windows has an OS-level "privacy shutter notification" mechanism for camera drivers. No equivalent public macOS API was found in this research. — [Microsoft Learn: privacy shutter notification](https://learn.microsoft.com/en-sg/WINDOWS-HARDWARE/DRIVERS/stream/privacy-shutter-notification) (search excerpt)

### Inferences
- **What a non-MDM consumer app can do:**
  - detect camera use (CMIO listeners, or log parsing like OverSight);
  - kill or quit the app;
  - present its own virtual camera.

  It cannot programmatically revoke TCC camera permission for another app. Users can toggle it in System Settings, and MDM can deny it. `tccutil reset Camera <bundle-id>` only resets the decision to "ask", which is general macOS knowledge not sourced here.
- **Value of the virtual-camera approach.** Unlike killing the process or denying TCC, it lets the meeting continue with a branded "camera paused" frame. It does not stop the meeting app from opening the real camera if the user selects it, so detection (an OverSight-style CMIO listener on the physical camera) is a useful complement for warning the user.
- **Fallback for an unapproved app.** If the placeholder cannot be made reliable in some clients, OffSight could have the extension relay a placeholder video produced by the menu-bar app through the sink, the same path that already works, instead of generating frames in the extension.

### Gaps
- No public documentation was found on using Endpoint Security to block camera access. ES has no camera-open event type documented in the sources found, so this was not confirmed. Screen Time camera restriction on macOS was not confirmed. "Lens" and "Camera blocker" as macOS products were not found. No source covered Hand Mirror's or Krisp's camera architecture. Continuity Camera is an Apple system camera, not a virtual camera, and no source on its placeholder behaviour was found within the call budget.
