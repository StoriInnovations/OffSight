# How reference and open-source CMIOExtension camera extensions produce and send frames

Scope: CoreMediaIO Camera Extensions (CMIOExtension, macOS 12.3+). Source code was read directly from shallow clones of the repos below (OBS at commit 7d98beb, 8 Oct 2026). Repos read: obsproject/obs-studio (`plugins/mac-virtualcam`), below/WWDC22_CoreMediaIO (a verbatim copy of the Xcode "Camera Extension" template), ldenoue/cameraextension, Halle/OffcutsCam, Halle/TechnicalDifficulties, Halle/ArtFilm and Halle/SinkCam, dognotdog/ptpwebcam (CMIO port, updated June 2026), dautovri/SimulatorCamera (updated Sept 2026), and jcm93/Record. GitHub code search for `kWhiteStripeHeight CMIOExtensionStreamSource` found about 20 repos. Every one checked is derived from the Apple template.

**Main finding:** every working implementation found advertises one format, `kCVPixelFormatType_32BGRA`, built with `CMVideoFormatDescriptionCreate(... extensions: nil ...)`. Each uses a pool whose only IOSurface setting is `kCVPixelBufferIOSurfacePropertiesKey: [:]`, and none sets any colour attachment. So OffSight's format, pool and format description match OBS and the Apple template almost exactly. Those settings are not what separates OffSight from the working code. The differences that remain are in timing, gating and which thread or timer sends the frames.

## Q1. What Apple's Xcode "Camera Extension" template and the WWDC22 session 10022 sample do

### Takeaway
The template advertises a single 1920x1080 32BGRA format with no format-description extensions. It uses an IOSurface-backed `CVPixelBufferPool` with an allocation threshold of 5. On each tick of a DispatchSourceTimer it fills a fresh pool buffer: it memsets the buffer to 0 and draws a 10-row white stripe as `0xFFFFFFFF`. It sets PTS to `CMClockGetTime(CMClockGetHostTimeClock())` and leaves duration and DTS invalid. It sends with `discontinuity: []` and `hostTimeInNanoseconds = PTS.seconds * NSEC_PER_SEC`. The WWDC transcript itself has no code and names no pixel format.

### Cited Findings
- The template's device-source init, quoted verbatim from a copy of the template — [below/WWDC22_CoreMediaIO ExtensionProvider.swift](https://github.com/below/WWDC22_CoreMediaIO/blob/main/Extension/ExtensionProvider.swift):
  ```swift
  let dims = CMVideoDimensions(width: 1920, height: 1080)
  CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA, width: dims.width, height: dims.height, extensions: nil, formatDescriptionOut: &_videoDescription)
  let pixelBufferAttributes: NSDictionary = [
      kCVPixelBufferWidthKey: dims.width,
      kCVPixelBufferHeightKey: dims.height,
      kCVPixelBufferPixelFormatTypeKey: _videoDescription.mediaSubType,
      kCVPixelBufferIOSurfacePropertiesKey: [:]
  ]
  CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, pixelBufferAttributes, &_bufferPool)
  let videoStreamFormat = CMIOExtensionStreamFormat.init(formatDescription: _videoDescription, maxFrameDuration: CMTime(value: 1, timescale: Int32(kFrameRate)), minFrameDuration: CMTime(value: 1, timescale: Int32(kFrameRate)), validFrameDurations: nil)
  _bufferAuxAttributes = [kCVPixelBufferPoolAllocationThresholdKey: 5]
  ```
- The template's frame loop, quoted verbatim. It gets a pool buffer, memsets it to 0 (BGRA black with alpha 0), writes white `0xFFFFFFFF` rows, stamps it and sends it — [below/WWDC22_CoreMediaIO](https://github.com/below/WWDC22_CoreMediaIO/blob/main/Extension/ExtensionProvider.swift):
  ```swift
  _timer = DispatchSource.makeTimerSource(flags: .strict, queue: _timerQueue)
  _timer!.schedule(deadline: .now(), repeating: Double(1/kFrameRate), leeway: .seconds(0))
  ...
  err = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, self._bufferPool, self._bufferAuxAttributes, &pixelBuffer)
  ...
  memset(bufferPtr, 0, rowBytes * height)
  ...
  var timingInfo = CMSampleTimingInfo()
  timingInfo.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock())
  err = CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: self._videoDescription, sampleTiming: &timingInfo, sampleBufferOut: &sbuf)
  if err == 0 {
      self._streamSource.stream.send(sbuf, discontinuity: [], hostTimeInNanoseconds: UInt64(timingInfo.presentationTimeStamp.seconds * Double(NSEC_PER_SEC)))
  }
  ```
- Timing details in the template:
  - `CMSampleTimingInfo()` is used without setting `duration` or `decodeTimeStamp`.
  - The timer interval is written `Double(1/kFrameRate)`, with `kFrameRate` an `Int` of 60. That is integer division, so it evaluates to 0.
  - The same code also appears in Halle's TechnicalDifficulties as `Double(1 / kFrameRate)`.
  - Sources: [below/WWDC22_CoreMediaIO](https://github.com/below/WWDC22_CoreMediaIO/blob/main/Extension/ExtensionProvider.swift); [Halle/TechnicalDifficulties](https://github.com/Halle/TechnicalDifficulties/blob/main/Extension/ExtensionProvider.swift)
- The stream source declares `clockType: .hostTime`, and its `streamProperties` return `activeFormatIndex = 0` and `frameDuration = CMTime(1, kFrameRate)`. The same structure is copied into OBS, shown under Q2 — [OBS OBSCameraStreamSource.swift](https://github.com/obsproject/obs-studio/blob/master/plugins/mac-virtualcam/src/camera-extension/OBSCameraStreamSource.swift)
- The Objective-C version of the template sends with `sendSampleBuffer:sbuf discontinuity:CMIOExtensionStreamDiscontinuityFlagNone hostTimeInNanoseconds:(uint64_t)(CMTimeGetSeconds(timingInfo.presentationTimeStamp) * NSEC_PER_SEC)` — [Apple Developer Forums thread 761771](https://developer.apple.com/forums/thread/761771)
- The WWDC22 session 10022 transcript describes the sink path this way: "Clients feed your sink stream by inserting sample buffers into a simple queue. That translates to a consumeSampleBuffer call in your extension, and once you've consumed that buffer, you notify them with notifyScheduledOutputChanged." It says a stream "uses a standard clock, such as the host time clock, or provides its own custom clock". It describes the template demo as a "horizontal white line that moves up and down the frame at 60 frames per second". The transcript has no code and names no pixel format — [WWDC22 10022](https://developer.apple.com/videos/play/wwdc2022/10022/)
- Unmodified template output displays in Photo Booth:
  - The ptpwebcam CMIO port's notes from 2026 record "Runtime validated: white-stripe visible in Photo Booth with simulated camera". That code is template-derived: BGRA, `extensions: nil`, `IOSurfacePropertiesKey: [:]`. Source: [dognotdog/ptpwebcam PORTING_STATUS.md](https://github.com/dognotdog/ptpwebcam/blob/master/PORTING_STATUS.md)
  - A search summary also reported a developer forum post saying the template "loads in Photo Booth and shows the expected video (a white horizontal line which moves down the picture)". This came from search results pointing to forum threads [709204](https://developer.apple.com/forums/thread/709204) and [736838](https://developer.apple.com/forums/thread/736838). I did not fetch either thread to verify the quote.
- A known QuickTime freeze: the unmodified template displays in QuickTime "for a while", then the preview freezes while frames are still being sent. Changing the discontinuity flags did not help. The thread has no replies — [Apple Developer Forums thread 761771](https://developer.apple.com/forums/thread/761771)

### Inferences
- Because `1/kFrameRate` is integer division, the template's timer is scheduled with a 0 interval. It therefore fires much faster than 60 fps. Despite that, the stripe displays in Photo Booth, so Photo Booth does not need a sending rate that matches the advertised frame duration.
- The template's background pixels have alpha 0 (memset 0). Photo Booth still shows the stripe, so a "proper" alpha value is evidently not required.

### Gaps
- I could not fetch Apple's own documentation page for the template code ("Creating a camera extension with Core Media I/O") or the session's code tab. The quotes above come from a repo that copies the template, not from Apple directly.
- Whether newer Xcode versions (16 or 26) fixed the `1/kFrameRate` bug was not verified.

## Q2. How OBS Studio's macOS virtual camera (CMIO extension, OBS 30+) creates formats and frames

### Takeaway
OBS uses the same pattern as the template:
- **Advertised format:** BGRA 1920x1080, `extensions: nil`, at 60 fps.
- **Pool:** `IOSurfacePropertiesKey: [:]`, threshold 5.
- **Placeholder:** a 60 fps timer draws a PNG with NSImage/CoreGraphics into a fresh pool buffer every tick and stamps it with host time.

OBS stops sending placeholder frames as soon as the sink stream starts. Sink frames are forwarded unchanged, with OBS's own PTS and format description. Those frames are actually NV12, UYVY, I420 or P010 at whatever size OBS outputs, not the advertised BGRA 1920x1080, and they display anyway. The format is not 2vuy/NV12 at the advertised level; that only applies to the frames OBS pushes through the sink.

### Cited Findings
- **Format and pool**, from `OBSCameraDeviceSource.swift` — [OBS OBSCameraDeviceSource.swift](https://github.com/obsproject/obs-studio/blob/master/plugins/mac-virtualcam/src/camera-extension/OBSCameraDeviceSource.swift):
  - `let OBSCameraFrameRate: Int = 60`
  - `CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA, width: 1920, height: 1080, extensions: nil, ...)`
  - Pool attributes are `[kCVPixelBufferWidthKey, kCVPixelBufferHeightKey, kCVPixelBufferPixelFormatTypeKey: _videoDescription.mediaSubType, kCVPixelBufferIOSurfacePropertiesKey: [CFString: CFTypeRef]()]`.
  - The stream format uses min = max = 1/60 and `validFrameDurations: nil`.
  - `_bufferAuxAttributes = [kCVPixelBufferPoolAllocationThresholdKey: 5]`.
  - There is one format for both the source and the sink stream.
- **Placeholder frames**, also from `OBSCameraDeviceSource.swift` — [same file](https://github.com/obsproject/obs-studio/blob/master/plugins/mac-virtualcam/src/camera-extension/OBSCameraDeviceSource.swift):
  - The timer is `DispatchSource.makeTimerSource(flags: .strict, queue: _timerQueue)` with `repeating: 1.0 / Double(OBSCameraFrameRate)` and `leeway: .seconds(0)`.
  - The queue is `.userInteractive` with autoreleaseFrequency `.workItem`.
  - Each tick does `if self.sinkStarted { return }`, then `CVPixelBufferPoolCreatePixelBufferWithAuxAttributes`, then lock.
  - It draws with `CGContext(data: base, ..., space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)` and `self._placeholderImage.draw(in: CGRect(x:0,y:0,width:width,height:height))` through `NSGraphicsContext`.
  - It then unlocks and sets `timingInfo.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock())`, leaving duration unset.
  - It sends with `CMSampleBufferCreateForImageBuffer(... formatDescription: self._videoDescription ...)` and `send(sampleBuffer, discontinuity: [], hostTimeInNanoseconds: UInt64(timingInfo.presentationTimeStamp.seconds * Double(NSEC_PER_SEC)))`.
  - The placeholder PNG is drawn again in full on every frame.
- **Sink handling** — [same file](https://github.com/obsproject/obs-studio/blob/master/plugins/mac-virtualcam/src/camera-extension/OBSCameraDeviceSource.swift):
  - `startStreamingSink` sets `sinkStarted = true` and starts a second `.strict` timer at `1/(60*3)` s, so it polls at 180 Hz.
  - Each poll calls `consumeSampleBuffer(from: client)`.
  - The callback builds `CMIOExtensionScheduledOutput(sequenceNumber:, hostTimeInNanoseconds: now)` from a fresh host-clock read.
  - If `_streamingCounter > 0`, it calls `send(sampleBuffer!, discontinuity: [], hostTimeInNanoseconds: UInt64(sampleBuffer!.presentationTimeStamp.seconds * NSEC_PER_SEC))`. That forwards the producer's sample buffer as-is, with no re-wrap and no new format description.
  - It then calls `notifyScheduledOutputChanged(output)`.
- **The sink stream's properties** — [OBS OBSCameraStreamSink.swift](https://github.com/obsproject/obs-studio/blob/master/plugins/mac-virtualcam/src/camera-extension/OBSCameraStreamSink.swift):
  - It advertises `.streamSinkBufferQueueSize`, `.streamSinkBuffersRequiredForStartup`, `.streamSinkBufferUnderrunCount` and `.streamSinkEndOfData`.
  - It returns `sinkBufferQueueSize = 1` and `sinkBuffersRequiredForStartup = 1`.
  - It stores the `CMIOExtensionClient` in `authorizedToStartStream(for:)` and uses it in `startStream()`.
- **Producer side (OBS app)** — [OBS plugin-main.mm](https://github.com/obsproject/obs-studio/blob/master/plugins/mac-virtualcam/src/obs-plugin/plugin-main.mm):
  - It maps the OBS output format to CoreVideo: I420 becomes `420YpCbCr8Planar[FullRange]`, NV12 becomes `420YpCbCr8BiPlanar{Video,Full}Range`, UYVY becomes `422YpCbCr8[FullRange]`, and P010 becomes the 10-bit bi-planar formats. Unsupported formats fall back to NV12.
  - It creates a pool with `kCVPixelBufferIOSurfacePropertiesKey: @{}`.
  - It sets up `CMIOStreamCopyBufferQueue` and `CMVideoFormatDescriptionCreate(kCFAllocatorDefault, video_format, w, h, NULL, &formatDescription)`, again with no extensions.
  - It copies frames by memcpy and sets `presentationTimeStamp = CMTimeMake(frame->timestamp, NSEC_PER_SEC)`.
  - It calls `CMSampleBufferCreateForImageBuffer(... vcam->formatDescription ...)` and then `CMSimpleQueueEnqueue`.
  - So in normal operation the frames that reach Teams, Zoom and Photo Booth are YUV, typically NV12, while the extension advertises BGRA.
- **Mismatches are passed through:** in a 2026 issue (macOS 26, OBS 32.1.2), ffmpeg/AVFoundation captured the OBS camera as `rawvideo (UYVY) ... 2560x1440`. The extension still advertises 1920x1080, and Chrome only offers 1080p — [obs-studio#13559](https://github.com/obsproject/obs-studio/issues/13559)
- **Known display failure with a YUV format:** "When NV12 is selected ... virtual camera works fine. Changing the format to I420 [Full range], virtual camera stays on black screen" (OBS 30.1.1, macOS 14) — [obs-studio#10452](https://github.com/obsproject/obs-studio/issues/10452)
- I found no OBS issue about a grey placeholder in Photo Booth or Teams. Searches returned only install, activation and code-signing issues (for example #10381, #9912, #11571) — [OBS issue search](https://github.com/obsproject/obs-studio/issues/10381)

### Inferences
- OBS's placeholder pipeline is close to identical to OffSight's: BGRA, no extensions, an IOSurface pool with empty properties, a CoreGraphics draw into a fresh pool buffer, host-clock PTS, `discontinuity: []`, and hostTime taken from the PTS. Small differences remain:
  - OBS leaves sample duration invalid; OffSight sets 1/30.
  - OBS runs at 60 fps; OffSight runs at 30.
  - OBS redraws each frame; OffSight copies a pre-rendered buffer.
  - OBS never sends placeholder and sink frames at the same time, because of the `sinkStarted` gate.
- The OBS placeholder is widely seen in meeting apps when OBS is not feeding the camera. If BGRA without colour attachments caused grey frames, that would be a widely reported OBS bug, and I found no such report.
- Mixing a producer's own PTS with the extension's PTS can make timestamps non-monotonic. That could happen if placeholder frames keep going while sink frames arrive, or if OffSight forwards sink frames with the producer's PTS. OBS avoids interleaving by gating on `sinkStarted`.

### Gaps
- The shallow clone had no history, so I could not review commit messages for camera-extension fixes related to placeholders, Teams or Photo Booth.
- OBS has no documented test of the placeholder specifically in Photo Booth.

## Q3. Laurent Denoue, Halle Winkler (The Offcuts), and other GitHub CMIO extension repos

### Takeaway
All of these are template-derived: BGRA advertised, `extensions: nil`, an IOSurface pool with `[:]`, and host-clock PTS with `hostTime = PTS * 1e9`. Several deliberately send buffers whose pixel format differs from the advertised one, such as 32ARGB, 2vuy, or whatever arrives from the sink. Several build a per-frame format description from the buffer instead of using the advertised one. One sends the same static image buffer on every tick. The only documented case of "Photo Booth blank" was caused by sample-buffer timing: the producer's original timestamps were propagated through. It was not caused by pixel format.

### Cited Findings
- **ldenoue/cameraextension** — [ldenoue cameraextensionProvider.swift](https://github.com/ldenoue/cameraextension/blob/main/cameraextension/cameraextensionProvider.swift):
  - It advertises BGRA (`//codecType: kCVPixelFormatType_32ARGB` is left commented out) and uses an IOSurface pool `[:]` with threshold 5.
  - Its placeholder is drawn per frame with CGContext `byteOrder32Little | premultipliedFirst`: a black fill plus text with a seconds counter.
  - Each timer tick does `if self.sinkStarted { return }`.
  - The sink loop is recursive. `consumeSampleBuffer` runs again from inside its own callback, with no timer. It forwards `sbuf` unchanged with `hostTimeInNanoseconds: sbuf.presentationTimeStamp.seconds * NSEC_PER_SEC`, then calls `notifyScheduledOutputChanged` with a host-clock read taken at that moment.
  - OBS's extension code is visibly derived from this file: same names, `sinkStarted`, `lastTimingInfo`.
  - The README says that when the sink is not started, "the camera simply shows a black frame with a text (+ number of seconds)". Source: [ldenoue/cameraextension](https://github.com/ldenoue/cameraextension)
- **ldenoue's app side** also creates BGRA buffers with `kCVPixelBufferIOSurfacePropertiesKey: [:]` before pushing them into the sink — [ldenoue ViewController.swift](https://github.com/ldenoue/cameraextension/blob/main/samplecamera/ViewController.swift)
- **Halle Winkler, TechnicalDifficulties** (sample for part 2 of "Getting To Grips With The Core Media IO Camera Extension" on The Offcuts) sends a static image — [Halle/TechnicalDifficulties ExtensionProvider.swift](https://github.com/Halle/TechnicalDifficulties/blob/main/Extension/ExtensionProvider.swift):
  - It advertises BGRA 1080x720 with `extensions: nil`.
  - It renders a placeholder image once into a single `CVPixelBufferCreate(..., kCVPixelFormatType_32ARGB, [IOSurfacePropertiesKey: [:]])` buffer, using CGContext `noneSkipFirst` and the image's own colour space. That buffer is not from the pool, and its format is not the advertised BGRA.
  - Every tick it sends the same buffer, wrapped with `CMVideoFormatDescriptionCreateForImageBuffer` and `CMSampleBufferCreateReadyWithImageBuffer`, with PTS from the host clock.
  - Because of a copy/paste bug, the code calls `send` twice per tick.
- **Halle Winkler, ArtFilm** (part 3, the "creative camera") — [Halle/ArtFilm ExtensionProvider.swift](https://github.com/Halle/ArtFilm/blob/main/Extension/ExtensionProvider.swift):
  - It advertises BGRA, but its output buffer is `CVPixelBufferCreate(..., kCVPixelFormatType_422YpCbCr8 /* 2vuy */, ...)`.
  - It processes frames with vImage, uses `CMVideoFormatDescriptionCreateForImageBuffer` per frame, and sends from the AVCaptureVideoDataOutput callback instead of a timer.
- **Halle/SinkCam** (an output-device example) credits Laurent Denoue's sample and uses the same structure. Its sink callback builds `CMIOExtensionScheduledOutput` with a host-clock time and forwards with `hostTimeInNanoseconds: sbuf.presentationTimeStamp`. Its README warns that "any video source that is aware of it" can target the sink, so client IDs or PIDs should be checked. Source: [Halle/SinkCam](https://github.com/Halle/SinkCam)
- **dognotdog/ptpwebcam**, CMIO port, 2026 — [ptpwebcam PtpWebcamCameraExtensionProvider.swift](https://github.com/dognotdog/ptpwebcam/blob/master/PtpWebcamCameraExtension/PtpWebcamCameraExtensionProvider.swift):
  - It advertises BGRA with `extensions: nil`.
  - Live-view frames are sent with a format description derived from the buffer ("so any camera resolution is accepted without reconfiguring a pool or cached descriptor") and host-clock PTS.
  - The demo timer is correctly `1.0 / Double(kFrameRate)` with 2 ms leeway, and it calls `CVPixelBufferCreate` for every frame instead of using a pool.
  - Its notes say the white stripe was validated in Photo Booth.
- **dautovri/SimulatorCamera**, Sept 2026 — [dautovri SimulatorCameraProvider.swift](https://github.com/dautovri/SimulatorCamera/blob/main/SimulatorCameraExtension/SimulatorCameraProvider.swift):
  - It advertises BGRA, `extensions: nil`, IOSurface pool `[:]`, threshold 5, and min = max frame duration.
  - The sink path is a recursive `consumeSampleBuffer` loop that waits 100 ms before re-arming after an error.
  - It calls `notifyScheduledOutputChanged` for every buffer, even when the frame is then dropped.
  - It re-wraps the sink's `CVPixelBuffer` into a new sample buffer with its own host-clock PTS (`send(pb)`) instead of forwarding the producer's sample buffer.
  - It rejects sink buffers that are not BGRA or not the exact advertised size (`SimCamFrameCheck`). Source for that check: [SimulatorCamera CameraContract.swift](https://github.com/dautovri/SimulatorCamera/blob/main/Shared/CameraContract.swift)
  - Its docs say the camera "works in Photo Booth". Source: [SimulatorCamera docs/ARCHITECTURE.md](https://github.com/dautovri/SimulatorCamera/blob/main/docs/ARCHITECTURE.md)
- **jcm93/Record** follows the same template pattern: BGRA, `extensions: nil`, `IOSurfacePropertiesKey: [:]`, sink forwarding, and `hostTimeInNanoseconds` taken from the PTS. In one path it re-wraps into a new sample buffer (`newSbuf`) before sending — [jcm93/Record RecordCameraExtensionProvider.swift](https://github.com/jcm93/Record/blob/main/RecordCameraExtension/RecordCameraExtensionProvider.swift)
- **The only diagnosed "Photo Booth blank screen" case in a source-plus-sink extension** came down to timing:
  - The author wrote: "Nevermind, the pixel format was not the issue. 420v works fine. Lots of reboots later I realized I wasn't setting the timing info right... make sure to update the timing info before sending the sample buffer to the source stream". The fix used `CMSampleBufferCreateCopyWithNewTiming` with `presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock())`.
  - A second developer replied that they had also been "propagating the sampleTimingInfo that originated in the client app all the way through" and had seen "strange behaviour".
  - No Apple staff replied in the thread.
  - Source: [Apple Developer Forums thread 725481](https://developer.apple.com/forums/thread/725481)
- **Broadify (pivotrecruiting/broadify-bridge, Oct 2026):** Teams and Zoom picked up the advertised 1280x720 BGRA format while the producer delivered 1920x1080. The fix was to advertise one fixed 1920x1080 BGRA 30 fps format and to scale frames, or convert RGBA to BGRA, to match it. The PR also found that an older extension build was still active after an upgrade, so the running binary was stale; `systemextensionsctl` showed build 17 while app build 19 was installed. On-device verification was still open when the PR merged — [broadify-bridge PR #221](https://github.com/pivotrecruiting/broadify-bridge/pull/221)
- I could not fetch The Offcuts blog itself (theoffcuts.org, parts 1–3), because of a DNS failure in this environment and archive.org being blocked. Only the sample repos were reviewed — [Halle/TechnicalDifficulties README](https://github.com/Halle/TechnicalDifficulties)

### Inferences
- All of these working samples use the same format, pool and description settings as OffSight. So the explanation for "QuickTime shows the placeholder, but Photo Booth and Teams show grey" is more likely in timing, gating or delivery than in the pixel format or attachments. Even OffSight's white-bar and mid-grey test frames fail in Photo Booth, and the template's near-identical white bar works there, which points the same way.
- These are hypotheses to check against OffSight, not confirmed causes:
  1. **Wrong units for `hostTimeInNanoseconds`.** OffSight passes "now". Every reference passes `PTS.seconds * 1e9` from `CMClockGetHostTimeClock`. If "now" in OffSight comes from `mach_absolute_time()` or `DispatchTime.now().uptimeNanoseconds`, the units or clock base differ: on Apple Silicon, mach ticks are about 41.67 ns each, not 1 ns.
  2. **Interleaved timestamps.** Placeholder frames and sink or live frames may be sent at the same time with interleaved or non-monotonic PTS. OBS and ldenoue strictly gate the placeholder with `sinkStarted`.
  3. **Producer PTS forwarded.** Sink frames forwarded with the producer's PTS produce the documented Photo Booth blank screen in thread 725481.
  4. **Sample duration.** OffSight sets duration 1/30, while every reference leaves duration and DTS invalid. That is unlikely to matter, but it is a difference.
  5. **Stale extension binary** after an upgrade, as in the Broadify PR.
- QuickTime appears more tolerant than Photo Booth of timing problems; the 725481 thread pins Photo Booth's blank screen on timing. That would fit OffSight's "QuickTime displays, Photo Booth doesn't" pattern. This is inference.

### Gaps
- I found no public write-up describing exactly OffSight's symptom: a static placeholder visible in QuickTime but grey in Photo Booth and Teams, while live frames work.
- I found no "The Missing Manual for camera extensions" article. Searches returned nothing under that title, so it may not exist under that name.

## Q4. Evidence that apps need a YUV format (420v/420f/2vuy) or particular colour attachments, or that BGRA without attachments renders grey

### Takeaway
No evidence was found that BGRA without colour attachments is rendered grey. The evidence points the other way:
- Every reference implementation advertises BGRA with no extensions and sets no colour attachments, and they display in Photo Booth, QuickTime, Teams and Zoom.
- A community-tested rule is "declare 32BGRA in `.formats`, send whatever you want". QuickTime reportedly accepts only 32BGRA in `.formats`, while Photo Booth accepts 420v or BGRA.
- Sending YUV buffers under a BGRA advertisement works; that is how OBS normally runs.

### Cited Findings
- On pixel formats, the 725481 thread author wrote: "Photo Booth will accept either 420v or kCVPixelFormatType_32BGRA (maybe more?) in the stream source's formats property. You can even send it sample buffers with a format different from the one in `.formats` and it will work just fine. But QuickTime only accepts kCVPixelFormatType_32BGRA in `.formats`. It too works even if you send it 420v sample buffers. Lesson: declare kCVPixelFormatType_32BGRA in `.formats`, and send whatever you want." This is a community member's finding from Mar 2023, with no Apple confirmation — [Apple Developer Forums thread 725481](https://developer.apple.com/forums/thread/725481)
- The same author also said "kCVPixelFormatType_32BGRA works fine" for Photo Booth — [thread 725481](https://developer.apple.com/forums/thread/725481)
- In practice OBS advertises BGRA and sends NV12, UYVY, I420 or P010 with no colour attachments (`CMVideoFormatDescriptionCreate(..., NULL, ...)`). I420 full range is the one combination reported to stay black — [OBS plugin-main.mm](https://github.com/obsproject/obs-studio/blob/master/plugins/mac-virtualcam/src/obs-plugin/plugin-main.mm); [obs-studio#10452](https://github.com/obsproject/obs-studio/issues/10452)
- None of the eight CMIO extension codebases reviewed sets any of the following: `kCVImageBufferColorPrimariesKey`, `TransferFunction`, `YCbCrMatrix`, `CVBufferSetAttachment`, `CMSetAttachment`, `kCVPixelBufferMetalCompatibilityKey`, or non-empty IOSurface properties. This was checked by a grep across all the Swift sources — [ldenoue](https://github.com/ldenoue/cameraextension), [Halle/ArtFilm](https://github.com/Halle/ArtFilm), [Halle/TechnicalDifficulties](https://github.com/Halle/TechnicalDifficulties), [Halle/SinkCam](https://github.com/Halle/SinkCam), [below/WWDC22_CoreMediaIO](https://github.com/below/WWDC22_CoreMediaIO), [ptpwebcam](https://github.com/dognotdog/ptpwebcam), [jcm93/Record](https://github.com/jcm93/Record), [SimulatorCamera](https://github.com/dautovri/SimulatorCamera)
- The DAL-plugin era (pre-12.3) is separate and is the subject of another note. Here it matters only in two ways:
  - OBS's legacy `dal-plugin/` directory still ships in the tree, alongside a Mach-port path (`sendPixelBuffer:`) used when CMIO extensions are unsupported — [OBS plugin-main.mm](https://github.com/obsproject/obs-studio/blob/master/plugins/mac-virtualcam/src/obs-plugin/plugin-main.mm)
  - DAL-era app incompatibilities (Photo Booth, Chrome, Teams, older Zoom) were about library validation and code signing, not pixel formats. The README advises `codesign --remove-signature` workarounds for Teams and Chrome — [ptpwebcam README](https://github.com/dognotdog/ptpwebcam/blob/master/README.md)

### Inferences
- Moving OffSight to 420v or 2vuy, or adding colour attachments, is unlikely on this evidence to fix grey frames in Photo Booth or Teams. It would be a low-cost experiment to rule things out, not a fix backed by reference behaviour.
- Pixel content is not the trigger either. The template's alpha-0 black with a white stripe works in Photo Booth, while OffSight's white-bar and mid-grey frames do not. That points to how and when OffSight sends frames: timestamps or `hostTimeInNanoseconds` units, concurrent senders, stream or client state, or a stale extension build.

### Gaps
- There is no Apple-authored statement on which pixel formats CMIOExtension consumers require; thread 725481 has no Apple reply.
- No source tested BGRA with explicit colour attachments against BGRA without them in Photo Booth or Teams on macOS 14–26.
- How Photo Booth behaves on macOS 26 Tahoe with camera extensions specifically is not documented in any source found.
