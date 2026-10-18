# Consumer-side and API semantics of CoreMediaIO Camera Extension frame delivery (macOS 12.3+ to 26)

Source key (used throughout):
- CMIOExtensionStream.h / CMIOExtensionProperties.h / CMIOSampleBuffer.h / CMIOHardwareStream.h: macOS 14.5 SDK headers, mirrored at https://github.com/alexey-lysiuk/macos-sdk/tree/main/MacOSX14.5.sdk/System/Library/Frameworks/CoreMediaIO.framework/Versions/A/Headers. The 13.3 SDK headers in the same mirror match. I could not get macOS 15 or 26 SDK headers from this mirror. Raw URLs:
  - [CMIOExtensionStream.h](https://raw.githubusercontent.com/alexey-lysiuk/macos-sdk/main/MacOSX14.5.sdk/System/Library/Frameworks/CoreMediaIO.framework/Versions/A/Headers/CMIOExtensionStream.h)
  - [CMIOExtensionProperties.h](https://raw.githubusercontent.com/alexey-lysiuk/macos-sdk/main/MacOSX14.5.sdk/System/Library/Frameworks/CoreMediaIO.framework/Versions/A/Headers/CMIOExtensionProperties.h)
  - [CMIOSampleBuffer.h](https://raw.githubusercontent.com/alexey-lysiuk/macos-sdk/main/MacOSX14.5.sdk/System/Library/Frameworks/CoreMediaIO.framework/Versions/A/Headers/CMIOSampleBuffer.h)
  - [CMIOHardwareStream.h](https://raw.githubusercontent.com/alexey-lysiuk/macos-sdk/main/MacOSX14.5.sdk/System/Library/Frameworks/CoreMediaIO.framework/Versions/A/Headers/CMIOHardwareStream.h)
- Chromium: [media/capture/video/apple/video_capture_device_avfoundation.mm (main)](https://raw.githubusercontent.com/chromium/chromium/main/media/capture/video/apple/video_capture_device_avfoundation.mm). The file has moved from the old `mac/` path, which now returns 404.
- OBS Studio camera extension, a production CMIOExtension whose design closely matches ours: [OBSCameraDeviceSource.swift](https://github.com/obsproject/obs-studio/blob/master/plugins/mac-virtualcam/src/camera-extension/OBSCameraDeviceSource.swift) and [OBSCameraStreamSource.swift](https://github.com/obsproject/obs-studio/blob/master/plugins/mac-virtualcam/src/camera-extension/OBSCameraStreamSource.swift)
- WWDC22 session 10022, "Create camera extensions with Core Media IO": [transcript page](https://developer.apple.com/videos/play/wwdc2022/10022/)

---

## Q1. CMIOExtensionStream.send(_:discontinuity:hostTimeInNanoseconds:): what hostTimeInNanoseconds must be, how it relates to PTS, what happens on mismatch, and the clock type

### Takeaway
The only documentation says that `hostTimeInNanoseconds` is "the host time in nanoseconds when the buffer was captured", and that the sample buffer's timestamps must be relative to the stream's clock (the host-time clock for `.hostTime`). In practice, OBS, the Apple template-derived code and the forum fixes all set PTS = `CMClockGetTime(CMClockGetHostTimeClock())` and hostTime = PTS in nanoseconds. Our extension already does exactly this, so timestamp mismatch is an unlikely cause of the grey placeholder, unless the placeholder path builds its timing differently from the live path.

### Cited Findings
- Header doc for `sendSampleBuffer:discontinuity:hostTimeInNanoseconds:` — [CMIOExtensionStream.h](https://raw.githubusercontent.com/alexey-lysiuk/macos-sdk/main/MacOSX14.5.sdk/System/Library/Frameworks/CoreMediaIO.framework/Versions/A/Headers/CMIOExtensionStream.h):
  - `@param hostTimeInNanoseconds` is "The host time in nanoseconds when the buffer was captured."
  - "The sample will be deliver[ed] to clients whose media type authorization status is authorized."
  - "The sample buffer timestamps should be relative to the clock timebase specified with clockType."
  - "Attempting to send a sample buffer on a sink stream will throw an exception."
- The developer.apple.com page for the Swift API says the same: "The host time in nanoseconds when the stream captured the buffer. Specify sample buffer timestamps that are relative to the clock timebase specified by the clockType property." — [Apple docs JSON](https://developer.apple.com/tutorials/data/documentation/coremediaio/cmioextensionstream/send(_:discontinuity:hosttimeinnanoseconds:).json)
- `CMIOExtensionStreamClockType` has three values — [CMIOExtensionStream.h](https://raw.githubusercontent.com/alexey-lysiuk/macos-sdk/main/MacOSX14.5.sdk/System/Library/Frameworks/CoreMediaIO.framework/Versions/A/Headers/CMIOExtensionStream.h):
  - `HostTime` (0): "the stream's clock is the host time clock".
  - `LinkedCoreAudioDeviceUID` (1).
  - `Custom` (2): "cannot be set directly by the extension, but instead is set automatically when a CMIOExtensionStreamCustomClockConfiguration is used".
- `CMIOExtensionStreamDiscontinuityFlags` exposes only None (0), Unknown (1<<0), Time (1<<1) and SampleDropped (1<<6). These map onto the legacy `kCMIOSampleBufferDiscontinuityFlag_*` bits: UnknownDiscontinuity = 1<<0, TimecodeDiscontinuity = 1<<1, DataWasDropped = 1<<6 — [CMIOExtensionStream.h](https://raw.githubusercontent.com/alexey-lysiuk/macos-sdk/main/MacOSX14.5.sdk/System/Library/Frameworks/CoreMediaIO.framework/Versions/A/Headers/CMIOExtensionStream.h), [CMIOSampleBuffer.h](https://raw.githubusercontent.com/alexey-lysiuk/macos-sdk/main/MacOSX14.5.sdk/System/Library/Frameworks/CoreMediaIO.framework/Versions/A/Headers/CMIOSampleBuffer.h)
- OBS's placeholder path works in third-party apps, and it is functionally identical to ours — [OBSCameraDeviceSource.swift](https://github.com/obsproject/obs-studio/blob/master/plugins/mac-virtualcam/src/camera-extension/OBSCameraDeviceSource.swift):
  - `timingInfo.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock())`, with duration and DTS left invalid (a default `CMSampleTimingInfo()`).
  - `CMSampleBufferCreateForImageBuffer(... dataReady: true ... formatDescription: self._videoDescription ...)`.
  - `stream.send(sampleBuffer, discontinuity: [], hostTimeInNanoseconds: UInt64(timingInfo.presentationTimeStamp.seconds * Double(NSEC_PER_SEC)))`.
  - The stream is created with `direction: .source, clockType: .hostTime` — [OBSCameraStreamSource.swift](https://github.com/obsproject/obs-studio/blob/master/plugins/mac-virtualcam/src/camera-extension/OBSCameraStreamSource.swift)
- In the sink-to-source relay path, OBS sends `hostTimeInNanoseconds` derived from the incoming buffer's own PTS. It sets a fresh host-clock time only on the `CMIOExtensionScheduledOutput` — [OBSCameraDeviceSource.swift](https://github.com/obsproject/obs-studio/blob/master/plugins/mac-virtualcam/src/camera-extension/OBSCameraDeviceSource.swift)
- Developer report (no Apple reply): a source/sink extension's 420v frames showed a blank screen in Photo Booth. The cause was "incorrect sample timing". The fix was to re-stamp each buffer with `CMSampleBufferCreateCopyWithNewTiming` using PTS = `CMClockGetTime(CMClockGetHostTimeClock())` before sending. A second developer said they had been passing through the client app's timing unchanged — [Apple Developer Forums 725481](https://developer.apple.com/forums/thread/725481)
- Developer report: before re-timing, logs from `CMIO_Unit_Synchronizer_Video.cpp` said frames arrived "too quickly" and were dropped. There was also a "timebase jump" discontinuity, even though `CMIOExtensionStreamDiscontinuityFlagNone` was passed. Re-stamping timing with the host clock removed the "too quickly" message — [Apple Developer Forums 726417](https://developer.apple.com/forums/thread/726417)
- Unresolved report: with the stock Xcode template, QuickTime's preview froze after a while even though frames were still being sent. That code passed `hostTimeInNanoseconds = CMTimeGetSeconds(PTS) * NSEC_PER_SEC`. Setting the discontinuity to Time or SampleDropped did not help — [Apple Developer Forums 761771](https://developer.apple.com/forums/thread/761771)
- WWDC22 10022 describes the stream as using "a standard clock, such as the host time clock, or provides its own custom clock to drive the timing of each buffer it produces". It also says: "All the buffers your extension provides are validated before being delivered to an app." — [WWDC22 10022](https://developer.apple.com/videos/play/wwdc2022/10022/)
- Consumer side: Chromium treats the PTS of each delivered sample as host time. It runs `CMClockConvertHostTimeToSystemUnits(CMSampleBufferGetPresentationTimeStamp(sb))`, then `TimeTicks::FromMachAbsoluteTime`, and computes frame timestamps relative to the first frame's PTS — [Chromium video_capture_device_avfoundation.mm](https://raw.githubusercontent.com/chromium/chromium/main/media/capture/video/apple/video_capture_device_avfoundation.mm)

### Inferences
- In the CMIO (legacy DAL) graph that AVCaptureSession builds, a per-client video "Synchronizer" unit (`CMIO_Unit_Synchronizer_Video`) evidently paces and drops frames based on PTS against the host clock. Buffers that arrive "too quickly" are dropped, and timebase jumps are flagged. So PTS must be on the host-time clock, monotonically increasing, and spaced at no less than the active frame duration. QuickTime appears more tolerant than Photo Booth.
- `hostTimeInNanoseconds` must be in nanoseconds, not mach ticks. On Apple Silicon a mach tick is about 41.67 ns, so passing `mach_absolute_time()` raw would be wrong. `CMClockGetTime(hostClock).seconds * 1e9` is the community-standard value. Our extension already uses PTS = host-clock "now" and hostTime = that PTS in ns, so the two values agree.
- Our live and placeholder paths share the same timing code, so timing is unlikely to explain "live shows, placeholder grey". Two exceptions are worth checking:
  - The placeholder and live senders run concurrently, producing interleaved or non-monotonic PTS or more than 30 fps, which would trip the Synchronizer's "too quickly" drop.
  - The placeholder reuses a previously created sample buffer with a stale PTS.
- Passing discontinuity flags did not help in the forum reports. Using `[]` (None) for normal frames is standard. `.time` would only be appropriate when switching the source (live to placeholder) if PTS jumps.

### Gaps
- No Apple document or DTS answer states precisely what happens when `hostTimeInNanoseconds` and the buffer PTS disagree. It is also unknown whether the proxy (registerassistantservice) or the client-side DAL shim uses `hostTimeInNanoseconds` at all, or only the PTS. Exact drop thresholds in `CMIO_Unit_Synchronizer_Video` are undocumented.
- I could not fetch macOS 15 or 26 SDK headers to confirm that the doc text is unchanged. The 13.3 and 14.5 headers are identical on these points.

---

## Q2. How AVFoundation clients handle a BGRA-only device, and what Photo Booth, Teams and WebRTC/Chrome request

### Takeaway
A CMIOExtension's `CMIOExtensionStreamFormat`s become `AVCaptureDeviceFormat`s. With a BGRA-only device, any client that asks AVCaptureVideoDataOutput for a different pixel format causes AVCapture to convert BGRA to that format inside the capture graph. Chromium/WebRTC does not accept 'BGRA' as a device format: it falls back to requesting '420v' via `videoSettings`, so every Chrome/WebRTC frame from our device is converted BGRA to 420v. Photo Booth was empirically shown to accept BGRA- or 420v-declared extensions. The Teams pixel-format behaviour is undocumented.

### Cited Findings
- WWDC22 10022 — [WWDC22 10022](https://developer.apple.com/videos/play/wwdc2022/10022/):
  - "Your extension stream source publishes CMIOExtensionStreamFormats. Those become AVCaptureDeviceFormats. Clients can read and write the active format index to change the active format."
  - AVFoundation "re-publishes DAL plug-ins as AVCaptureDevices"; "To the client of this interface, there's no difference between CoreMedia IO Extensions and DAL plug-ins."
- Apple docs (AVCaptureVideoDataOutput) — [Apple docs](https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutput):
  - "Avoid defaulting to a BGRA format, because BGRA formats aren't native and require conversion."
  - The output "can output pixel buffers in several pixel formats".
- Apple docs (`videoSettings`) — [Apple docs](https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutput/videosettings):
  - "To receive samples in their device-native format, set this value to an empty dictionary"; "To receive samples in a default uncompressed format, set this value to nil."
  - For uncompressed output, `kCVPixelBufferPixelFormatTypeKey`, `kCVPixelBufferWidthKey` and `kCVPixelBufferHeightKey` are supported.
  - Width/height that exceed the active format, or whose aspect ratio does not match it, throw an invalidArgumentException.
- `availableVideoPixelFormatTypes` "may change if the video capture device's activeFormat value changes" — [Apple docs](https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutput/availablevideopixelformattypes)
- TN3121: when the device's active format is 420v and the output requests 'BGRA', "AVCapture has to convert every captured '420v' pixel buffer to 'BGRA'". The availableVideoPixelFormatTypes array "depends on the activeFormat of the capture device" — [TN3121](https://developer.apple.com/documentation/technotes/tn3121-selecting-a-pixel-format-for-an-avcapturevideodataoutput)
- Chromium (main) — [Chromium video_capture_device_avfoundation.mm](https://raw.githubusercontent.com/chromium/chromium/main/media/capture/video/apple/video_capture_device_avfoundation.mm):
  - `FourCCToChromiumPixelFormat` maps only five FourCCs: '420f' (NV12, behind the feature `kAVFoundationCaptureAccept420FullRange`, enabled by default), '420v' (NV12), '2vuy' (UYVY), 'yuvs' (YUY2) and 'dmb1' (MJPEG). Everything else, including 'BGRA', is `PIXEL_FORMAT_UNKNOWN`.
  - `FindBestCaptureFormat` skips formats with unknown FourCC ("Ignoring device supported format, unknown FourCC") and formats whose dimensions do not exactly match the requested size.
  - If no format qualifies, `best_fourcc` stays at `kDefaultFourCCPixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` ('420v').
  - It then sets `videoSettings = {Width, Height, AVVideoScalingModeKey: ResizeAspectFill, PixelFormatType: best_fourcc}`, so AVFoundation scales and converts to the request.
  - Frame rate is set on the AVCaptureConnection (`videoMinFrameDuration`/`videoMaxFrameDuration`) only if `supportsVideoMinFrameDuration`/`supportsVideoMaxFrameDuration`. Chromium does not set `activeVideoMinFrameDuration` on the device.
  - If the SampleBufferTransformer path is used, every frame is further converted to IOSurface-backed NV12. When the transform fails, Chromium logs "Failed to transform captured frame. Dropping frame."
  - The macOS stall-restart watchdog is disabled by default on macOS 14+ "due to a redesign of the camera capture in macOS 14".
- Empirical (developer, not Apple) — [Apple Developer Forums 725481](https://developer.apple.com/forums/thread/725481):
  - Photo Booth accepts either 420v or 32BGRA in the extension's `formats`, and works even when the buffers sent differ from the declared format.
  - QuickTime accepted only 32BGRA in `formats` but also displayed 420v buffers.
  - The developer's conclusion: declare BGRA and send whatever format you want.
- OBS's shipping camera extension declares exactly one 32BGRA 1920x1080 format, built with `CMVideoFormatDescriptionCreate(... extensions: nil ...)`, and sets min = max frame duration with `validFrameDurations: nil`. It is used widely with Teams, Zoom and browsers — [OBSCameraDeviceSource.swift](https://github.com/obsproject/obs-studio/blob/master/plugins/mac-virtualcam/src/camera-extension/OBSCameraDeviceSource.swift)

### Inferences
- A BGRA-only format declaration is not in itself what breaks Photo Booth or Teams. OBS ships the same declaration, and our live frames display with it. What differs between our live and placeholder frames must be in the buffers themselves.
- With a BGRA device, the conversion BGRA to 420v/2vuy (Chrome; probably Teams and Zoom too) happens in the client process's capture graph. That plausibly explains the "CMIOUnitVideoToolboxCompressorEntry" in Photo Booth's graph log: CMIO unit names suggest a VideoToolbox pixel-transfer or compression stage. This is not verified.
- Synthetic buffers that pass straight through to QuickTime's native-format preview, but fail a conversion step, would display in QuickTime and be grey or blank in converting clients. Causes include non-IOSurface-backed memory, a wrong actual pixel format, or a size or stride mismatch. This fits the observed pattern and should be checked first (see Q4).

### Gaps
- No public source documents the pixel format Photo Booth, FaceTime, Zoom or new Teams request from AVCaptureVideoDataOutput.
- New Teams (WebView2/Edge-based on Windows; on macOS a WKWebView/Electron-hybrid with native media stack "SlimCore") — I found no reliable source on whether its camera capture goes through Chromium's AVFoundation capturer or Microsoft's own native AVFoundation code, or what FourCC it requests. Community threads only show historical Teams issues: virtual cameras hidden by library validation in 2020–21, and "new Teams" picking a camera but getting no video — [mimoLive](https://mimolive.com/?p=22038), [MS Tech Community](https://techcommunity.microsoft.com/discussions/microsoftteams/new-microsoft-teams-has-broken-virtual-cameras-again-/4062479/replies/4065139).

---

## Q3. Frame dropping rules: late frames, non-increasing PTS, discontinuity flags, sequence numbers, CMIOStreamClock

### Takeaway
Apple does not document explicit drop rules for CMIOExtension source streams. Two layers can drop frames:
- The client-side CMIO graph's video Synchronizer drops frames that arrive faster than the frame duration ("too quickly") and flags timebase jumps.
- AVCaptureVideoDataOutput drops frames when the app's delegate queue is busy (`alwaysDiscardsLateVideoFrames`, default true).

In addition, the system validates buffers before delivery and withholds them from unauthorized clients. Sequence numbers and discontinuity attachments are added by the framework. Extensions only pass the reduced `DiscontinuityFlags`.

### Cited Findings
- Developer log evidence: messages from `CMIO_Unit_Synchronizer_Video.cpp` reported frames received "too quickly" and dropped, plus a timebase-jump discontinuity. These were cured by re-stamping PTS from the host clock — [Apple Developer Forums 726417](https://developer.apple.com/forums/thread/726417)
- `alwaysDiscardsLateVideoFrames`: "If this property is true, the output immediately discard[s] frames that [were] captured while the dispatch queue handling existing frames blocks in the captureOutput(_:didOutput:from:) delegate method... The default is true." — [Apple docs](https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutput/alwaysdiscardslatevideoframes)
- "All the buffers your extension provides are validated before being delivered to an app." The proxy "registerassistantservice" enforces consent: "If the user has denied camera access, the proxy stops buffers from going to that app." — [WWDC22 10022](https://developer.apple.com/videos/play/wwdc2022/10022/)
- Attachment keys — [CMIOSampleBuffer.h](https://raw.githubusercontent.com/alexey-lysiuk/macos-sdk/main/MacOSX14.5.sdk/System/Library/Frameworks/CoreMediaIO.framework/Versions/A/Headers/CMIOSampleBuffer.h):
  - `kCMIOSampleBufferAttachmentKey_SequenceNumber` is "a number that increments monotonically for every buffer of a given stream; it can be ... used to detect gaps".
  - `kCMIOSampleBufferAttachmentKey_DiscontinuityFlags` is a CFNumber SInt32.
  - `CMIODiscontinuityFlagsHaveHardDiscontinuities(flags)` treats everything except `DurationWasExtended` as a hard discontinuity.
  - Other flags include `NoDataMarker` ("a dummy buffer that is sent through the graph if the source has no data"), `DataWasDropped` ("a unit did not pull on its input fast enough"), `TimingReferenceJumped` and `DataFormatChanged`.
  - The header defines no `kCMIOSampleBufferAttachmentKey_HostTime`. The host-time-related attachment present is `kCMIOSampleBufferAttachmentKey_CAAudioTimeStamp`, which is for CoreAudio-device buffers.
- Stream properties — [CMIOHardwareStream.h](https://raw.githubusercontent.com/alexey-lysiuk/macos-sdk/main/MacOSX14.5.sdk/System/Library/Frameworks/CoreMediaIO.framework/Versions/A/Headers/CMIOHardwareStream.h):
  - `kCMIOStreamPropertyNoDataTimeoutInMSec` ('pmn1') is how long "a device should allow to go by without seeing data before it determines that it is experiencing a period of 'no data'". `kCMIOStreamPropertyNoDataEventCount` counts such periods.
  - `kCMIOStreamPropertyClock` ('pmcl') is "a clock abstraction for a device's stream", created with `CMIOStreamClockCreate` and driven by `CMIOStreamClockPostTimingEvent`.
- Developer observation: Photo Booth and similar apps may hold CMSampleBuffers for long periods. With 3+ clients, a small extension CVPixelBufferPool can run dry, so allocation fails and no frame is sent. The suggestion was to allocate individually when the pool is exhausted — [Apple Developer Forums 726417](https://developer.apple.com/forums/thread/726417)
- OBS creates its pool with `kCVPixelBufferIOSurfacePropertiesKey` and allocates with `kCVPixelBufferPoolAllocationThresholdKey: 5`. On `kCVReturnPoolAllocationFailed` it logs and skips the frame — [OBSCameraDeviceSource.swift](https://github.com/obsproject/obs-studio/blob/master/plugins/mac-virtualcam/src/camera-extension/OBSCameraDeviceSource.swift)

### Inferences
- Frames are likely dropped silently in these cases:
  - PTS not on the host clock.
  - PTS not increasing, or duplicate PTS.
  - Frames delivered faster than the active frame duration. Example: a placeholder timer and a live path both sending, or a 2x timer that sends every tick.
  - A pixel-buffer pool running dry because clients hold buffers.
  - Buffers failing system validation.
- Duplicate-timestamp and stale-PTS handling is undocumented, but the Synchronizer behaviour suggests both are dropped.
- If Photo Booth's display is grey (rather than frozen on a previous frame), it is probably receiving nothing that it can render. Either every placeholder frame is dropped or validated away, or it renders content that becomes grey after conversion (see Q4). Photo Booth and Teams then fall back to a grey "no video" view.

### Gaps
- No Apple source lists the validation rules applied to extension buffers, such as format-description match, IOSurface backing or dimensions. It is also unknown whether a failing buffer is dropped silently or logged. On macOS 26 one could check `log stream --predicate 'subsystem == "com.apple.cmio"'` in the client and in registerassistantservice; that is a suggestion, not a sourced fact.
- Exact Synchronizer thresholds (how early is "too quickly", how far PTS may deviate from "now") are not public.

---

## Q4. Format description extensions and CVPixelBuffer attachments that consumers may need

### Takeaway
Nothing public says consumers require colour or FormatName extensions on the format description. OBS ships with `extensions: nil` and an IOSurface-backed BGRA pool, and the system displays it. What is documented, and is the strongest lead, is that CMSampleBuffer pixel buffers should be IOSurface-backed. Cross-process delivery and GPU conversion paths depend on IOSurface. Separately, the buffer's real format, dimensions and alpha must match what the format description claims.

### Cited Findings
- Community advice on camera-extension latency: "Recommend that any CVPixelBufferRef objects that you send via CMSampleBufferRef objects be backed by IOSurface (specify in pixel buffer properties) which will prevent unnecessary copies from being made when the frames are sent to the client." The poster, not an Apple employee, said this matters most on Intel Macs with discrete GPUs — [Apple Developer Forums 721710](https://developer.apple.com/forums/thread/721710)
- OBS pool attributes: `{Width: 1920, Height: 1080, PixelFormatType: mediaSubType of the format description ('BGRA'), kCVPixelBufferIOSurfacePropertiesKey: [:]}`. The placeholder is drawn with `CGContext(... space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: noneSkipFirst | byteOrder32Little)` into the locked pool buffer, so it has no alpha — [OBSCameraDeviceSource.swift](https://github.com/obsproject/obs-studio/blob/master/plugins/mac-virtualcam/src/camera-extension/OBSCameraDeviceSource.swift)
- `CVPixelBufferGetIOSurface` returns NULL if the buffer is not IOSurface-backed. IOSurface backing requires `kCVPixelBufferIOSurfacePropertiesKey` in the creation attributes, either directly or via the pool — [Apple QA1781](https://developer.apple.com/library/ios/qa/qa1781/_index.html), [CVPixelBuffer docs](https://developer.apple.com/documentation/corevideo/cvpixelbuffer-q2e.md)
- Format descriptions given to `CMIOExtensionStreamFormat` are "The format description of the samples delivered by the stream." — [CMIOExtensionProperties.h](https://raw.githubusercontent.com/alexey-lysiuk/macos-sdk/main/MacOSX14.5.sdk/System/Library/Frameworks/CoreMediaIO.framework/Versions/A/Headers/CMIOExtensionProperties.h)
- WWDC: "All the buffers your extension provides are validated before being delivered to an app." — [WWDC22 10022](https://developer.apple.com/videos/play/wwdc2022/10022/)
- Chromium assumes that a delivered sample's format-description subtype equals the CVPixelBuffer's pixel format: `DCHECK_EQ(pixelBufferPixelFormat, sampleBufferPixelFormat)`. It also has a Rec.709 "Apple" colour space constant used for capture frames — [Chromium video_capture_device_avfoundation.mm](https://raw.githubusercontent.com/chromium/chromium/main/media/capture/video/apple/video_capture_device_avfoundation.mm)

### Inferences (ranked likely causes of "placeholder or test pattern grey in Photo Booth/Teams but fine in QuickTime")
1. **The placeholder CVPixelBuffer is not IOSurface-backed.** Examples: `CVPixelBufferCreate` without `kCVPixelBufferIOSurfacePropertiesKey`, `CVPixelBufferCreateWithBytes`, or a buffer from `CIContext`/`CGBitmapContext` memory. Live camera-derived frames come from AVCapture or VideoToolbox pools, which are IOSurface-backed. Converting clients (Photo Booth via a VideoToolbox unit, Teams and Chrome via BGRA-to-420v conversion) may operate on the IOSurface. A non-IOSurface buffer may be serialized differently or reach them empty. QuickTime may use the native BGRA directly. Test: assert `CVPixelBufferGetIOSurface(pb) != nil` for placeholder frames, and allocate placeholders from an IOSurface-backed `CVPixelBufferPool` as OBS does.
2. **Alpha channel.** If the placeholder or test pattern is rendered with premultiplied alpha and a transparent or zero-alpha background, a client that composites with alpha (for example a CALayer-based preview) shows the window's grey background. QuickTime may treat 'BGRA' as opaque. OBS explicitly uses `noneSkipFirst`. Test: fill the placeholder with alpha = 0xFF.
3. **Mismatch between the buffer and the advertised format description.** Examples: a placeholder at a different size (for example 1280x720 or a Retina-scaled size), a different actual pixel format ('ARGB'/'RGBA' from a CG or CI render), or an odd bytes-per-row. The sample buffer would then not match the stream format, so it fails system validation or client conversion. `CMSampleBufferCreateForImageBuffer` also returns an error when the format description does not match the image buffer, so check its OSStatus. Prefer `CMVideoFormatDescriptionCreateForImageBuffer` checked with `CMVideoFormatDescriptionMatchesImageBuffer`.
4. **The same pixel buffer or IOSurface is resent every frame**, and is mutated or kept locked while clients still hold it. Clients such as Photo Booth hold buffers (forum 726417). Allocate a fresh pool buffer per frame.
5. Missing colour attachments (`kCVImageBufferColorPrimariesKey`, `TransferFunctionKey`, `YCbCrMatrixKey`) are the least likely cause of grey. Conversion falls back to defaults, which would shift colours rather than blank them. Adding `CVBufferSetAttachment(... kCVImageBufferColorPrimaries_ITU_R_709_2 ...)` or a `CGColorSpace` attachment is harmless, though.

### Gaps
- No primary source confirms that a non-IOSurface buffer reaches clients grey or blank, or that format-description extensions are required. These are inferences from Apple guidance, the OBS reference implementation and the observed QuickTime-vs-converting-client split.

---

## Q5. streamFrameDuration / streamMaxFrameDuration, validFrameDurations = nil, and clients setting frame rates

### Takeaway
With `validFrameDurations = nil`, the whole range from minFrameDuration to maxFrameDuration counts as valid. With min = max = 1/30 that range is exactly 30 fps, which OBS ships. Chromium only sets frame durations on the connection when supported, and tolerates a single-rate format. Ignoring frame-duration sets in `setStreamProperties` is not documented to break clients. Properly returning the current `frameDuration`/`maxFrameDuration` (and optionally `streamMaxFrameDuration`) is the expected contract.

### Cited Findings
- On `streamFormatWithFormatDescription:maxFrameDuration:minFrameDuration:validFrameDurations:` — [CMIOExtensionProperties.h](https://raw.githubusercontent.com/alexey-lysiuk/macos-sdk/main/MacOSX14.5.sdk/System/Library/Frameworks/CoreMediaIO.framework/Versions/A/Headers/CMIOExtensionProperties.h):
  - `validFrameDurations` is "The list of valid CMTime as dictionaries. If nil the full range between min and max is valid."
  - "A frame duration is the reciprocal of a frame rate. If a CMIOExtensionStreamFormat's validFrameDurations property is not nil and not empty, the frame duration are discrete... Current frame duration and maximum frame duration can be changed with the properties CMIOExtensionPropertyStreamFrameDuration and CMIOExtensionPropertyStreamMaxFrameDuration."
- `CMIOExtensionPropertyStreamFrameDuration` "needs to be a dictionary representing a CMTime struct that is consistent with the frame duration specification provided by the current active format". `CMIOExtensionPropertyStreamMaxFrameDuration` is "a dictionary representing a CMTime struct" — [CMIOExtensionProperties.h](https://raw.githubusercontent.com/alexey-lysiuk/macos-sdk/main/MacOSX14.5.sdk/System/Library/Frameworks/CoreMediaIO.framework/Versions/A/Headers/CMIOExtensionProperties.h)
- WWDC: "The frame duration, which is equivalent to max frame rate. And max frame duration, which is the same as min frame rate." — [WWDC22 10022](https://developer.apple.com/videos/play/wwdc2022/10022/)
- OBS exposes only `[.streamActiveFormatIndex, .streamFrameDuration]` as available properties, returning frameDuration = 1/30. It uses min = max = 1/30 and `validFrameDurations: nil` — [OBSCameraStreamSource.swift](https://github.com/obsproject/obs-studio/blob/master/plugins/mac-virtualcam/src/camera-extension/OBSCameraStreamSource.swift), [OBSCameraDeviceSource.swift](https://github.com/obsproject/obs-studio/blob/master/plugins/mac-virtualcam/src/camera-extension/OBSCameraDeviceSource.swift)
- A developer saw every format report exactly 30 fps. The cause was one format per frame rate with min = max. The fix was one format per frame size spanning min..max, with discrete `validFrameDurations` [29.97, 30, 59.94, 60]. An Apple Media Engineer engaged only to ask which client app was used — [Apple Developer Forums 812036](https://developer.apple.com/forums/thread/812036)
- Chromium prefers formats whose `videoSupportedFrameRateRanges` include the requested rate (±0.001 fps) but will still select a non-matching format. It then sets the connection's `videoMinFrameDuration`/`videoMaxFrameDuration` only if supported — [Chromium video_capture_device_avfoundation.mm](https://raw.githubusercontent.com/chromium/chromium/main/media/capture/video/apple/video_capture_device_avfoundation.mm)

### Inferences
- A single fixed 30 fps format with `validFrameDurations = nil` is a normal, shipping configuration. It is not a plausible cause of grey frames, especially since our live frames display under the same configuration.
- The frame duration matters for drops. If a client sets `activeVideoMinFrameDuration` lower, our setter ignores it and the device stays at 30 fps. The pacing unit presumably uses the active duration. Sending more than 30 fps, or bursty sends, risks "too quickly" drops.

### Gaps
- It is unknown what AVFoundation does if a client's `activeVideoMinFrameDuration` set is silently ignored, that is, whether a later read returns the old value or an error is thrown. No source found.

---

## Q6. Effects of a sink stream on the device (stream selection, direction)

### Takeaway
AVFoundation uses only the first input (source) stream of a device, so the source stream should be added first. Sink streams are CMIO output streams with no AVFoundation equivalent. Shipping extensions (OBS, Apple's template-derived samples) add source then sink and work, so a sink stream alone does not cause grey frames, provided the source is first.

### Cited Findings
- WWDC22 10022 — [WWDC22 10022](https://developer.apple.com/videos/play/wwdc2022/10022/):
  - "Your device can present multiple streams, but be aware that AVFoundation ignores all but the first input stream."
  - "CMIOExtension streams are created with a direction of either source or sink."
  - "output devices have no AVFoundation API equivalent. To send frames to an output device, you must use the CoreMedia IO C API directly."
- `kCMIOStreamPropertyDirection` ('sdir'): "A UInt32 where a value of 0 means that this CMIOStream is an output stream and a value of 1 means that it is an input stream." — [CMIOHardwareStream.h](https://raw.githubusercontent.com/alexey-lysiuk/macos-sdk/main/MacOSX14.5.sdk/System/Library/Frameworks/CoreMediaIO.framework/Versions/A/Headers/CMIOHardwareStream.h)
- Sink properties (`SinkBufferQueueSize`, `SinkBuffersRequiredForStartup`, `SinkBufferUnderrunCount`, `SinkEndOfData`) translate to `kCMIOStreamPropertyOutputBufferQueueSize`, `OutputBuffersRequiredForStartup`, `OutputBufferUnderrunCount` and `EndOfData` — [CMIOExtensionProperties.h](https://raw.githubusercontent.com/alexey-lysiuk/macos-sdk/main/MacOSX14.5.sdk/System/Library/Frameworks/CoreMediaIO.framework/Versions/A/Headers/CMIOExtensionProperties.h)
- OBS adds `_streamSource.stream` before `_streamSink.stream`. Both share the same BGRA `CMIOExtensionStreamFormat`. The placeholder timer stops sending once `sinkStarted` is true, after which the sink path relays frames — [OBSCameraDeviceSource.swift](https://github.com/obsproject/obs-studio/blob/master/plugins/mac-virtualcam/src/camera-extension/OBSCameraDeviceSource.swift)

### Inferences
- If the sink stream is added before the source, or if the sink is somehow exposed as an input, AVFoundation could bind to the wrong stream. Since our live frames display, the source stream is clearly the one being used. This is not the cause of the placeholder failure, but the add order is worth confirming.
- Using a sink: if live frames arrive via the sink and the placeholder is generated in-extension, the two paths may create pixel buffers differently. Sink-delivered buffers originate from the host app's IOSurface-backed buffers. That reinforces inference Q4-1: check that the in-extension placeholder buffers are IOSurface-backed and opaque.
- The mode switch must be clean. The placeholder timer must stop sending when live frames resume, and vice versa, to avoid duplicate or interleaved PTS (Q3).

### Gaps
- No source describes AVFoundation's behaviour when a device has only a sink stream or lists the sink first. The WWDC statement covers only "first input stream".
