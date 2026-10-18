# Bug reports: macOS virtual-camera frames not displaying in some apps (Photo Booth, FaceTime, Teams, Zoom, Meet, WhatsApp) while displaying in others (QuickTime, OBS)

Scope note: Reports are from the CMIOExtension era (macOS 12.3+) unless marked **[DAL era]**. Research as of 2026-10-12. About 20 tool calls; the Apple Developer Forums coverage is incomplete because some replies sit behind "Load more" links. fossies.org did not resolve, so OBS source was read from raw.githubusercontent.com.

## Q1. Apple Developer Forums threads on CMIOExtension frames not appearing (black, grey, blank or frozen) in specific apps, and any Apple DTS answers

### Takeaway
Two forum threads give a confirmed, reproducible fix, and both point to timing. Photo Booth showed a blank screen until each buffer was re-stamped with a host-clock PTS through `CMSampleBufferCreateCopyWithNewTiming`. Clients also run a CMIO "synchronizer" that silently drops frames whose timestamps arrive "too quickly" relative to the expected cadence. No Apple DTS engineer has answered a Photo Booth, FaceTime or Teams blank-frame thread. The only DTS replies found cover format changes at runtime (thread 728019) and a redirect (thread 817478).

### Cited Findings
- **Thread 725481, "CMIOExtensionStreamSource supported pixel formats" (Feb–Mar 2023, Ventura).**
  - **Symptom:** no client could connect to the source stream, and Photo Booth showed a blank screen. The OP first suspected 420v, but later wrote: "the pixel format was not the issue. 420v works fine."
  - **Real cause:** wrong timing info. The fix re-stamps each buffer before sending: `CMSampleTimingInfo timing_info = {.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock())}; CMSampleBufferCreateCopyWithNewTiming(..., 1, &timing_info, &sbuf); sendSampleBuffer:sbuf ...`. Duration and DTS were left zero/invalid.
  - **Format behaviour per the OP:** Photo Booth accepts 420v or 32BGRA in `.formats`, and still works when buffers differ from the declared format. QuickTime accepts only 32BGRA in `.formats` but renders 420v buffers. The OP's advice: declare 32BGRA in `.formats`, then send whatever format you want.
  - No Apple reply.
  - [Apple Developer Forums 725481](https://developer.apple.com/forums/thread/725481)
- **Thread 726417, "Clarification on appropriate values for CMIOExtensionStreamProperties" (Mar 2023, Ventura).**
  - **Client-side log:** `CMIO_Unit_Synchronizer_Video.cpp:1435:SyncUsingIntegralFrameTiming observing getting frames too quickly by a lot ... : dropping this frame`. After a sink restart the log showed `creating discontinuity because the timebase jumped`, even though the extension passed `DiscontinuityFlagNone`. The poster inferred that CMIO detects timebase jumps by itself.
  - **Fix:** rewriting each buffer's `CMSampleTimingInfo` in the extension, as in 725481, made the "too quickly" drops stop.
  - **Reference pattern:** a community reply derives both the PTS and `hostTimeInNanoseconds` from `CMClockGetTime(CMClockGetHostTimeClock())`, using the same value for both (`ns = CMTimeGetSeconds(time) * 1e9`).
  - **Pool exhaustion:** with three clients, one of them an AVAssetWriter, the extension's CVPixelBufferPool ran dry. The poster suspected that clients such as Photo Booth hold sample buffers (CIImage/QCRenderer) and recommended allocating individually when the pool is exhausted. This is unconfirmed.
  - No Apple reply.
  - [Apple Developer Forums 726417](https://developer.apple.com/forums/thread/726417)
- **Thread 726416, "13.1 Ventura CMIO multiple-client connections confuse the CMIO system".**
  - **Setup:** the stock Xcode template, with frames going to both QuickTime and Photo Booth.
  - **Symptom:** after repeated quit/relaunch cycles, frames stop and QuickTime hangs on quit. The log showed `__CMIO_Unit_Input_HAL.cpp:1724:DoInputRenderCallback Dropping 512 frames, because we're out of buffers`.
  - **OP's suggestion:** "If the problem appears with Photo Booth as a client, try creating the CVPixelBufferRef as an individual allocation instead of from a pool". Whether this works is unverified.
  - No Apple reply.
  - [Apple Developer Forums 726416](https://developer.apple.com/forums/thread/726416)
- **Thread 761771, "Camera Extension: Video Freezes" (Aug 2024).**
  - **Symptom:** the unmodified Xcode template's moving white line displays in QuickTime, then freezes after a while. The extension keeps calling `sendSampleBuffer`, so the consumer has stopped pulling frames.
  - **Code:** `hostTimeInNanoseconds` was computed as `CMTimeGetSeconds(timingInfo.presentationTimeStamp) * NSEC_PER_SEC`.
  - **Tried without success:** the `Time` and `SampleDropped` discontinuity flags.
  - No replies and no resolution.
  - [Apple Developer Forums 761771](https://developer.apple.com/forums/thread/761771)
- **Thread 706184 (XPC from app to CMIOExtension).** The poster reports that the extension "loads in Photo Booth and shows the expected test video". So the stock template's generated pattern does render in Photo Booth, and Photo Booth does not inherently reject synthetic frames. [Apple Developer Forums 706184](https://developer.apple.com/forums/thread/706184)
- **Thread 728019, "Camera Extension CMIOExtensionDevice update CMIOExtensionStreams in run time" (Apr 2023), with a DTS reply.**
  - **Symptom:** removing and re-adding streams to change formats produced `Invalid streamID` / -50 errors.
  - **Side effect:** recreating the device made the client fall back to the FaceTime camera.
  - **DTS advice:** expose all formats up front and reject unsupported ones in `setStreamProperties`, or tear down the device. DTS also recommended filing Feedback. An earlier search snippet from the same thread says DTS suggested sending buffers at a new resolution directly instead of changing the format list.
  - [Apple Developer Forums 728019](https://developer.apple.com/forums/thread/728019)
- **Thread 817478, "Virtual Camera Shows Jittering Frames and Solid Accent Color on macOS" (Mar 2026, macOS 26.2).**
  - **Symptom:** the CMIOExtension camera appears in Zoom and Google Meet. The first frame is sometimes correct, then frames jitter, and eventually the output becomes a solid accent colour (for example blue).
  - **Setup:** frames drawn from NSImage/CGImage through CGContext into CVPixelBuffers, on a 60 fps DispatchSourceTimer.
  - **Log:** `Invalid display 0x00000000`. The poster suspects headless drawing problems. A software CIContext reduced but did not remove the flicker.
  - **DTS:** Quinn redirected the discussion to thread 817476. No technical answer in this thread.
  - [Apple Developer Forums 817478](https://developer.apple.com/forums/thread/817478)
- **Thread 721710, Camera Extension latency in non-native apps.** A camera extension built on the FaceTime HD stream worked in FaceTime and Photo Booth but was very laggy in non-Apple apps. The suggested fix was to back pixel buffers with IOSurface to avoid copies. [Apple Developer Forums 721710](https://developer.apple.com/forums/thread/721710)
- **WWDC22 session 10022.** Apple states that legacy DAL plug-ins do not work in Apple apps such as FaceTime, QuickTime Player and Photo Booth. Camera extensions are the supported path. [WWDC22 10022](https://developer.apple.com/videos/play/wwdc2022/10022/)

### Inferences
- The only confirmed Photo Booth "blank" fix in the CMIOExtension era is timing-related. Clients that go through the CMIO unit/synchronizer (Photo Booth, and probably the AVCaptureSession clients Teams uses) appear stricter about PTS cadence than QuickTime's preview. That fits OffSight's pattern, where QuickTime is fine and Photo Booth and Teams are not.
- For OffSight, these are worth checking in the client's logs, filtered on `CMIO_Unit_Synchronizer_Video`, `SyncUsingIntegralFrameTiming` and `out of buffers`, while the placeholder runs:
  - **Synchronizer drops.** If two producers (the live path and a placeholder timer) both send during a transition, or the timer fires early or jittery, PTS deltas fall below roughly 1/30 s. The synchronizer then drops those frames as "too quickly" and keeps the last good frame, which would show as frozen or grey.
  - **Pool exhaustion from client-held buffers.** If Photo Booth holds buffers and the pool hits its threshold, `CVPixelBufferPoolCreatePixelBuffer` fails and no frame goes out. Check the return code on the placeholder path.

### Gaps
- No Apple DTS answer was found that says what Photo Booth, FaceTime or Teams require of sample buffer timing or attachments.
- Thread 817476, where DTS redirected the 817478 discussion, was not fetched.

## Q2. Stack Overflow, GitHub and other projects: specific app failures, causes and fixes

### Takeaway
The strongest 2026 report is kortexa-ai/aicamera #71. A CMIOExtension publishing only 32BGRA was black in WhatsApp for Mac (Catalyst / FigCaptureSession), and so was OBS's virtual camera. QuickTime and native AVFoundation clients worked. The fix was to publish 420v source formats with a continuous frame-rate range and convert BGRA to 420v with VTPixelTransferSession. Other GitHub, OBS and Teams reports are mostly install, signing or permission problems, not frame-content problems. I found no relevant Stack Overflow question with an accepted answer.

### Cited Findings
- **kortexa-ai/aicamera #71, "Camera view is black in WhatsApp for Mac: publish 420v source formats for Catalyst clients" (closed Sep 26 2026).**
  - **Who failed:** WhatsApp for Mac 26.38.20, a Catalyst app, showed black. OBS Virtual Camera, which publishes 32BGRA with no extensions, "fails identically".
  - **Who worked:** QuickTime and native AVFoundation clients.
  - **Diagnosis:** WhatsApp uses the iOS-style FigCaptureSession pipeline. Graph building aborted with `Fig assert "err == 0" (err=-12780)` in `BWMultiStreamCameraSourceNode.m:4577` right after the 32BGRA format was applied, so `StartStream` was never issued. Working devices (a UVC webcam with 709 colour extensions, and Continuity Camera at 420v 1280x720 with a 1–30 fps range) publish 420v.
  - **Secondary findings:**
    - Single-point frame rates (15/30/60) caused AVFoundation to throw `NSInvalidArgumentException` for 24 fps requests.
    - Forcing 1280x720 after a client had chosen another format was tolerated by native clients, but Catalyst probably does not tolerate it.
  - **Fix:**
    - The source stream publishes 420v at 640x480, 1280x720 and 1920x1080, with one continuous frame-duration range from 1/60 s to 1 s.
    - The sink stays 32BGRA.
    - A VTPixelTransferSession converts BGRA frames, including the placeholder, to the active source format.
  - **Rollout note:** after the extension update, the device vanished until `registerassistantservice` was killed and the host relaunched.
  - [GitHub kortexa-ai/aicamera #71](https://github.com/kortexa-ai/aicamera/issues/71)
- **pivotrecruiting/broadify-bridge PR #221 (merged Oct 2 2026).**
  - **Symptom:** Teams and Zoom negotiated 720p because the extension advertised only 1280x720 BGRA, while frames were 1920x1080.
  - **Fix:** advertise one fixed 1920x1080 BGRA 30 fps format, "similar to OBS", and scale mismatched frames into the destination size with vImage.
  - **Stale extension:** a newer embedded extension was never re-activated while an older build was still running (build 17 active, app build 19). The fix compares the active build from `systemextensionsctl list` and re-activates it.
  - No grey or black symptom is described.
  - [GitHub broadify-bridge PR #221](https://github.com/pivotrecruiting/broadify-bridge/pull/221)
- **OBS camera extension source (obs-studio master, `OBSCameraDeviceSource.swift`).**
  - **Advertised format:** a single format, 32BGRA 1920x1080, with min = max frame duration of 1/60 and `validFrameDurations: nil`.
  - **Placeholder:** drawn on a `.strict` DispatchSource timer at 1/60 s, only while the sink is not started.
  - **Timing:** PTS = `CMClockGetTime(CMClockGetHostTimeClock())`, duration not set, and `hostTimeInNanoseconds = UInt64(pts.seconds * NSEC_PER_SEC)`. Discontinuity is `[]`.
  - **Pool:** `kCVPixelBufferPoolAllocationThresholdKey: 5`, IOSurface-backed.
  - **Device properties:** only transportType = virtual and model. No suspended property.
  - **Streaming:** start and stop are reference-counted.
  - So OBS's setup is almost identical to OffSight's, apart from 60 vs 30 fps, and it is "compatible with all Mac applications" according to OBS. Per aicamera #71, it nonetheless fails in Catalyst/FigCaptureSession clients.
  - [OBSCameraDeviceSource.swift](https://raw.githubusercontent.com/obsproject/obs-studio/master/plugins/mac-virtualcam/src/camera-extension/OBSCameraDeviceSource.swift); [OBS Virtual Camera Troubleshooting KB](https://obsproject.com/kb/virtual-camera-troubleshooting)
- **OBS KB.**
  - OBS 30+ on macOS 13+ uses a camera extension "compatible with all Mac applications".
  - It must be approved under System Settings > General > Login Items & Extensions > Camera Extensions on macOS 15+, then OBS restarted.
  - It recommends Chromium-based browsers for best compatibility.
  - [OBS KB](https://obsproject.com/kb/virtual-camera-troubleshooting)
- **OBS forum, "Virtual Camera Problems - macOS 14.1 & OBS 29.1.3".** In Teams the "Virtual Camera" option was listed but showed only black, and Zoom did not list it at all. Reinstalling did not help, and other Macs worked. Unresolved. This was OBS 29, so most likely still the DAL plugin. [OBS forum](https://obsproject.com/forum/threads/virtual-camera-problems-macos-14-1-obs-29-1-3.170516/post-627985)
- **OBS forum, OBS 30.0.1.** The virtual camera disappeared after an in-app update because the system extension was not re-registered. The fix was to delete OBS (which removes the extension), reinstall and re-approve. [OBS forum](https://obsproject.com/forum/threads/obs-could-not-find-virtual-camera-after-updating-to-30-0-1.171689/)
- **[DAL era] johnboiles/obs-mac-virtualcam README.** Since Mojave, Photo Booth and FaceTime refuse to load non-Apple DAL plugins. Duplicating and renaming Photo Booth worked as a workaround, and there was no workaround for FaceTime. [obs-mac-virtualcam](https://github.com/johnboiles/obs-mac-virtualcam)
- **[DAL era] obs-mac-virtualcam #171.** The camera was missing in Teams. The log showed a Library Validation rejection ("mapping process and mapped file (non-platform) have different Team IDs"). Re-signing Teams was the suggested fix, and one user fixed it by reinstalling. [GitHub #171](https://github.com/johnboiles/obs-mac-virtualcam/issues/171)
- **[DAL era] obs-studio #3967.** FaceTime showed the OBS test card but not the scene. The suspected cause was hardened runtime blocking the plugin's Mach IPC. SimpleDALPlugin reportedly worked in FaceTime and Photo Booth. [GitHub obs-studio #3967](https://github.com/obsproject/obs-studio/issues/3967)
- **obs-studio #12015 (Sequoia).** The OBS camera kept overriding FaceTime's camera choice even after uninstall. The fix was deleting `~/Library/Preferences/com.apple.FaceTime.plist`. [GitHub obs-studio #12015](https://github.com/obsproject/obs-studio/issues/12015)
- **carl-eis/rtsp-rust-virtualcam #15 (design notes, unverified).**
  - Draw the placeholder on a `.strict`, zero-leeway timer while the sink is not running.
  - Count startStream/stopStream per client.
  - Offer NV12/420v from an IOSurface pool with an allocation threshold.
  - Lists FaceTime, Photo Booth, Zoom, Teams, Chrome, Safari and OBS as verification targets, but reports no results.
  - [GitHub rtsp-rust-virtualcam #15](https://github.com/carl-eis/rtsp-rust-virtualcam/issues/15)
- **Microsoft Q&A / Tech Community Teams-on-Mac black-camera threads.** These are almost entirely permission or device-selection fixes, with no virtual-camera frame diagnosis. One third-party guide attributes black-only-in-meetings to a previously selected virtual camera. [Tech Community thread](https://techcommunity.microsoft.com/t5/microsoft-teams/teams-camera-shows-black-screen-mac-works-in-other-apps-tried/td-p/3061586); [Microsoft Q&A](https://learn.microsoft.com/en-us/answers/questions/1249926/when-i-am-using-my-camera-in-teams-it-is-just-a-bl)

### Inferences
- OBS ships essentially OffSight's configuration (single 1080p 32BGRA format, host-clock PTS, same-value hostTime, placeholder on a timer) and is reported to work in Photo Booth and Teams. That makes "BGRA is unsupported by Photo Booth or Teams" an unlikely sole cause, and thread 725481 also shows Photo Booth accepts BGRA.
- 420v plus continuous frame-rate ranges is a compatibility improvement worth having for Catalyst and FigCaptureSession clients (WhatsApp, possibly others).
- OffSight's own symptom is that live frames work while placeholder and test frames fail in the same session and format. Because the format is the same, the cause is more likely to be per-buffer: timing, cadence, attachments, pool behaviour, or which code path calls `send`.
- **Testing caveat:** a "flat mid-grey" test pattern cannot be told apart from a client's own grey "no video" surface. Only the moving white bar is a conclusive test.

### Gaps
- No Stack Overflow question with an accepted answer was found for "camera extension black/grey Photo Booth" or "CMIOExtensionStream send not displayed".
- No GitHub issue was found that reports specifically "grey in Photo Booth/Teams but fine in QuickTime" for a camera extension.
- No Zoom, Webex or Chrome/Meet reports specific to camera extensions and frame content were found, beyond thread 817478.

## Q3. Known requirements and pitfalls: pixel format, timestamps and hostTime, discontinuity, attachments, frame-rate ranges, device suspended or running-somewhere, Center Stage, OS-version changes; static-frame detection in Teams or Photo Booth

### Takeaway
The community-validated recipe uses the same value for PTS and `hostTimeInNanoseconds`, taken from the host clock and stamped at send time. The CMIO client synchronizer drops frames with too-short PTS deltas and invents discontinuities on timebase jumps. On format, 420v is needed for Catalyst/Fig clients, and continuous frame-duration ranges avoid AVFoundation exceptions. Colour attachments, `DisplayImmediately`, the suspended and running-somewhere properties, Center Stage interference, and Teams or Photo Booth "static or covered camera" detection all lack any documented evidence.

### Cited Findings
- **PTS and hostTime.**
  - Thread 725481 and thread 726417 (community fix): PTS = `CMClockGetTime(CMClockGetHostTimeClock())`, with `hostTimeInNanoseconds` = the same value in ns.
  - OBS uses the same convention.
  - Thread 761771 used PTS-derived host time and still saw QuickTime freeze, with no answer.
  - [725481](https://developer.apple.com/forums/thread/725481); [726417](https://developer.apple.com/forums/thread/726417); [OBS source](https://raw.githubusercontent.com/obsproject/obs-studio/master/plugins/mac-virtualcam/src/camera-extension/OBSCameraDeviceSource.swift); [761771](https://developer.apple.com/forums/thread/761771)
- **Cadence and synchronizer.** `SyncUsingIntegralFrameTiming ... getting frames too quickly ... dropping this frame`, and "creating discontinuity because the timebase jumped" even with flag None. [726417](https://developer.apple.com/forums/thread/726417). The same synchronizer messages appear in QuickTime logs for a physical camera with a laggy, low frame rate (one frame per ~5 s). [Apple Community 251375319](https://discussions.apple.com/thread/251375319)
- **Pixel format.**
  - Photo Booth accepts 420v or BGRA, and QuickTime requires BGRA in `.formats`. [725481](https://developer.apple.com/forums/thread/725481)
  - Catalyst/FigCaptureSession (WhatsApp) fails with BGRA-only and works with 420v. [aicamera #71](https://github.com/kortexa-ai/aicamera/issues/71)
- **Frame-rate ranges.**
  - Single-point frame rates made AVFoundation throw for unlisted rates (24 fps). A continuous 1/60–1 s range fixed it. [aicamera #71](https://github.com/kortexa-ai/aicamera/issues/71)
  - The advertised size determines what Teams and Zoom negotiate. [broadify PR #221](https://github.com/pivotrecruiting/broadify-bridge/pull/221)
- **Runtime format changes.** Avoid them. DTS says to expose all formats up front, and removing streams causes -50 errors and fallback to the FaceTime camera. [728019](https://developer.apple.com/forums/thread/728019)
- **Buffer pools.** Clients may retain buffers. "Out of buffers" drops were seen with QuickTime and Photo Booth, and individual allocation was suggested as a fallback. [726416](https://developer.apple.com/forums/thread/726416); [726417](https://developer.apple.com/forums/thread/726417)
- **IOSurface.** IOSurface-backed buffers are recommended for non-Apple clients' latency. [721710](https://developer.apple.com/forums/thread/721710)
- **Colour attachments.**
  - Colour keys must be attached after `CVPixelBufferCreate` with `CVBufferSetAttachments`, because the attributes dictionary does not set them. [Apple Developer Forums 808137](https://developer.apple.com/forums/thread/808137)
  - VideoToolbox error -12917 (`kVTInsufficientSourceColorDataErr`) occurs when RGB source buffers lack colour space info. [Apple QA1839](https://developer.apple.com/library/archive/qa/qa1839/_index.html)
  - Working camera devices publish 709 colour extensions, while OBS's BGRA format has none. [aicamera #71](https://github.com/kortexa-ai/aicamera/issues/71)
  - No source ties missing attachments directly to grey or black in Photo Booth or Teams.
- **Headless drawing.** CGContext/NSImage drawing inside the extension logged "Invalid display 0x00000000" and gave jitter or solid-colour output in Zoom and Meet on macOS 26.2. [817478](https://developer.apple.com/forums/thread/817478)
- **Stale extension or registration.**
  - After an extension update the device can vanish or the old build keeps running. [aicamera #71](https://github.com/kortexa-ai/aicamera/issues/71); [broadify PR #221](https://github.com/pivotrecruiting/broadify-bridge/pull/221); [OBS forum 30.0.1](https://obsproject.com/forum/threads/obs-could-not-find-virtual-camera-after-updating-to-30-0-1.171689/)
  - A device may not enumerate until the host app restarts. [734259](https://developer.apple.com/forums/thread/734259)

### Inferences
These are hypotheses for OffSight, not sourced facts.
1. **Check the sending path for the placeholder.** Confirm that placeholder frames take the same send path, with the same PTS and hostTime derivation, as live frames. Rule out overlap where both a live callback and a placeholder timer send in the same 33 ms window, or a non-strict timer whose jitter sends frames early. Either would trigger "too quickly" drops in synchronizer-based clients but not in QuickTime.
2. **Copy the attachments live frames carry.** Live frames derived from a real camera probably carry colour attachments: primaries, transfer function and YCbCr matrix, or a CGColorSpace. Placeholder buffers freshly drawn into pool buffers probably carry none. Attach colour space and primaries, for example sRGB or 709, to placeholder buffers with `CVBufferSetAttachments` and test.
3. **Log pool-allocation failures.** If Photo Booth retains frames, the placeholder path may silently fail allocation. Log the `CVPixelBufferPoolCreatePixelBuffer` return code and fall back to `CVPixelBufferCreate`.
4. **Test conclusively.** Use the moving bar rather than flat grey, and watch the client's Console logs for `CMIO_Unit_Synchronizer_Video`, `out of buffers` and `-12780`.

### Gaps
- **Teams or Photo Booth static-frame detection:** no evidence found that either detects static, black or "covered camera" frames and replaces them with a grey placeholder. Searches turned up nothing from Microsoft or Apple on this.
- **`kCMSampleAttachmentKey_DisplayImmediately`:** no reports found tying it to camera-extension display.
- **Device properties:** no reports found tying `kCMIODevicePropertyDeviceIsRunningSomewhere` or a device-suspended property to missing frames. OBS does not implement a suspended property.
- **Center Stage and video effects:** no reports found of Center Stage or other video effects interfering with third-party camera-extension frames.
- **macOS 26 (Tahoe) changes:** none found beyond thread 817478 (26.2), which has no resolution.
- **Must hostTime match PTS?** There is no Apple statement on whether `hostTimeInNanoseconds` must equal the buffer PTS, or whether frames must come from the stream's own clock. Common practice (OBS, forum fixes) uses the same host-clock value for both.
- **Photo Booth start/stop on occlusion:** no source found describing the behaviour or any requirement it imposes, such as immediately sending a frame after `startStream`.
