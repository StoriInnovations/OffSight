# Survey: live video stretched in meeting apps (B4)

2026-10-23. Live video sometimes looked horizontally stretched in Microsoft Teams. This note
records what was found about where stretching can happen and why the fix is "crop on a shape
mismatch" rather than more formats.

## How OffSight sizes OffSight Camera

`OffSightConstants.effectsFreeFormat` scales the camera's own mode uniformly until it is at least
1920×1440, so macOS video effects can't apply to (and blank) the placeholder. No resolution is
hard-coded: the MacBook Pro camera's 1920×1080 mode becomes 2560×1440, a 4:3 640×480 mode would
become 1920×1440. The shape is the camera's, to within a pixel of rounding.

The advertised format is fixed while any app uses OffSight Camera (Apple: "Don't change stream
formats during the life cycle of the associated stream"), so a new size is applied only once the
camera is idle.

## Findings

| Finding | Source |
|---|---|
| Chromium (Meet in Chrome and Edge) asks its capture output for a size with `AVVideoScalingModeResizeAspectFill`: crop to keep the shape, never stretch. Its comment says the key is honoured on macOS. | Chromium `media/capture/video/apple/video_capture_device_avfoundation.mm` (`setCaptureHeight:width:frameRate:`) |
| Chromium picks among the device's own formats and scales its own copy to what the call needs. The size an app wants (e.g. 1280×720) never reaches a camera extension; the extension only learns which of its formats was selected. | Same file (`FindBestCaptureFormat`) |
| Scaling modes: **Resize** "doesn't preserve the aspect ratio"; **Fit** preserves it "by reducing the specified width or height" and "doesn't scale a small source up"; **ResizeAspectFill** crops to the destination. The default when no mode is set isn't documented. | Apple: AVVideoScalingModeFit / Resize / ResizeAspectFill |
| On macOS "a capture session can still automatically configure the capture format after you make changes"; preventing it means holding the device lock, which "may degrade capture quality in other apps sharing the device". | Apple: Capture device formats; `lockForConfiguration()` |
| Video effects apply only to video smaller than 1920×1440; a camera extension can't opt out (the other way out is a compressed stream). | Apple Media Engineer, developer forums thread 805786 |
| OBS's camera extension offers a single 1920×1080 format; OBS users also report horizontal stretching in Teams, with no documented fix. | OBS `plugins/mac-virtualcam/src/camera-extension/OBSCameraDeviceSource.swift`; OBS forum "video quality in ms teams" |
| Teams users report distorted virtual-camera video on macOS and other platforms; workarounds are anecdotal (e.g. fixing output at 1920×1080). Microsoft pages could not be opened for this survey. | Microsoft Q&A "USB camera aspect ratio squashed in Teams on macOS"; Tech Community "Using OBS virtual camera on Teams messes up aspect ratio" |

## The MacBook Pro camera's modes (Mac17,9, 2026-10-23)

All support Portrait, Center Stage and Background at 15–30 fps.

| Mode | Shape | Scaled for OffSight Camera |
|---|---|---|
| 1920×1080, 1280×720 | 16:9 | 2560×1440 |
| 640×480 | 4:3 | 1920×1440 |
| 1760×1328 | 1.325 | 1920×1450 |
| 1552×1552 | 1:1 (Center Stage) | 1920×1920 |
| 1328×1760, 1080×1920 | portrait | beyond the 3840×2160 limit |

The largest landscape mode is the near-4:3 sensor mode; the 16:9 modes are crops of it. Since
every mode supports effects, macOS is free to move the camera between shapes, for example when
another app opens it.

## Where OffSight stretched

Before this change the capture output was asked for exactly OffSight Camera's size with no
scaling mode, and the CPU fallback (`CPUFrameConverter`) stretched whatever arrived into that
size, assuming "both are the same shape". Diagnostics from a stretched call showed the fallback
in use ("Live frames: converted on the CPU"). OffSight also releases the device lock after
choosing the mode, so the mode can change mid-call; a 4:3 or square frame stretched into 16:9
looks like faces made wider.

## Decision

1. **Never stretch inside OffSight** (done): `AVVideoScalingModeResizeAspectFill` on the capture
   output, and the CPU fallback centre-crops to OffSight Camera's shape
   (`Dimensions.aspectFillCrop`). A mismatch costs a slight crop until the call ends.
2. **Make mode changes visible** (done): camera mode changes and changes in the live frames'
   size or pixel format are logged and noted in the diagnostics timeline.
3. **Not holding the device lock**: Apple warns it degrades other apps, and (1) makes mode
   changes harmless.
4. **Not offering 1280×720 or 1920×1080**: below 1920×1440 macOS applies effects to the
   placeholder again. If an app is shown to want 4:3, OffSight could also offer 1920×1440
   (the camera's 4:3 shape) and switch the camera to follow the app's choice; several apps share
   one stream and one camera, so cropping would still be needed.

Verify on device: a Teams call while another app opens the built-in camera or Center Stage is
toggled; diagnostics should show the mode change and live video should stay undistorted. Also
re-check B2 (Background effect reaches meeting apps), since the capture output's settings changed.
