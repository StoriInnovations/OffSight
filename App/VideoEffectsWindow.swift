import AppKit
import AVFoundation
import CoreImage
import SwiftUI

/// "Video Effects for Live Video": a local preview of OffSight's own camera capture plus the
/// system video-effects controls for OffSight.
///
/// macOS applies video effects (Portrait, Studio Light, Background…) per app, and only while that
/// app is using a camera; the system panel shows nothing for an app whose camera is off. So this
/// window keeps OffSight's capture running while it is open. Effects chosen for OffSight are meant
/// to apply to the physical camera before OffSight passes live video on, in every meeting app,
/// and never to the placeholder (OffSight Camera itself is too large for effects to apply).
/// Two previews show whether they do: the system's own preview, and the frames OffSight actually
/// sends (B2). Nothing from either preview is sent to any app.
final class VideoEffectsWindowController: NSObject, NSWindowDelegate {
    /// Called with true when the window opens and false when it closes.
    var onVisibilityChange: ((Bool) -> Void)?

    private var window: NSWindow?
    private let model: VideoEffectsModel
    private let sent: SentFramesModel
    private let session: AVCaptureSession

    init(capture: CameraCapture) {
        session = capture.session
        model = VideoEffectsModel(capture: capture)
        sent = SentFramesModel(capture: capture)
        super.init()
    }

    func show() {
        if window == nil {
            let view = VideoEffectsView(model: model, sent: sent, session: session)
            let newWindow = NSWindow(contentViewController: NSHostingController(rootView: view))
            newWindow.title = "Video Effects for Live Video"
            newWindow.styleMask = [.titled, .closable]
            newWindow.isReleasedWhenClosed = false
            newWindow.sharingType = .none // NFR-05: keep the preview out of screen sharing
            newWindow.delegate = self
            newWindow.center()
            window = newWindow
        }
        onVisibilityChange?(true)
        model.start()
        sent.start()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.stop()
        sent.stop()
        onVisibilityChange?(false)
    }
}

/// Which effects macOS currently applies to OffSight's camera, polled while the window is open.
final class VideoEffectsModel: ObservableObject {
    struct Effect: Identifiable {
        let id: String
        let active: Bool
    }

    @Published private(set) var effects: [Effect] = []
    @Published private(set) var cameraName: String?
    @Published private(set) var cameraAuthorised = true
    /// The active camera mode and the effects it supports.
    @Published private(set) var modeDescription: String?

    private weak var capture: CameraCapture?
    private var timer: Timer?

    init(capture: CameraCapture) {
        self.capture = capture
    }

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func showSystemControls() {
        NSApp.activate(ignoringOtherApps: true)
        AVCaptureDevice.showSystemUserInterface(.videoEffects)
    }

    private func refresh() {
        cameraAuthorised = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        guard let device = capture?.device else {
            cameraName = nil
            effects = []
            modeDescription = nil
            return
        }
        cameraName = device.localizedName
        modeDescription = capture?.activeModeDescription
        var list: [Effect] = [
            Effect(id: "Portrait", active: device.isPortraitEffectActive),
            Effect(id: "Studio Light", active: device.isStudioLightActive),
            Effect(id: "Center Stage", active: device.isCenterStageActive),
        ]
        if #available(macOS 14.0, *) {
            list.append(Effect(id: "Reactions", active: AVCaptureDevice.reactionEffectsEnabled))
        }
        if #available(macOS 15.0, *) {
            list.append(Effect(id: "Background", active: device.isBackgroundReplacementActive))
        }
        effects = list
    }
}

/// The frames OffSight's capture delivers, which are what meeting apps get when live, shown at
/// about 10 fps while the window is open. Display only; never sent anywhere.
final class SentFramesModel: ObservableObject {
    @Published private(set) var image: CGImage?

    private weak var capture: CameraCapture?
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var frameCount = 0

    init(capture: CameraCapture) {
        self.capture = capture
    }

    func start() {
        frameCount = 0
        capture?.onTapFrame = { [weak self] pixelBuffer in self?.receive(pixelBuffer) }
    }

    func stop() {
        capture?.onTapFrame = nil
        image = nil
    }

    /// Capture queue.
    private func receive(_ pixelBuffer: CVPixelBuffer) {
        frameCount += 1
        guard frameCount % 3 == 0 else { return }
        let full = CIImage(cvPixelBuffer: pixelBuffer)
        let scale = 480 / max(full.extent.width, 1)
        // Mirrored like the system preview beside it, so the two compare side by side.
        let small = full.transformed(by: CGAffineTransform(scaleX: -scale, y: scale))
        guard let rendered = context.createCGImage(small, from: small.extent) else { return }
        DispatchQueue.main.async { [weak self] in
            guard self?.capture?.onTapFrame != nil else { return }
            self?.image = rendered
        }
    }
}

private struct VideoEffectsView: View {
    @ObservedObject var model: VideoEffectsModel
    @ObservedObject var sent: SentFramesModel
    let session: AVCaptureSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                pane(caption: "macOS preview") {
                    CameraPreview(session: session)
                        .accessibilityLabel("Camera preview from macOS, visible only to you")
                }
                pane(caption: "Sent to meeting apps") {
                    if let image = sent.image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .accessibilityLabel("The video OffSight sends when live, visible only to you")
                    }
                }
            }
            if !model.cameraAuthorised {
                Text("OffSight needs camera access. Allow it in System Settings › Privacy & Security › Camera.")
                    .font(.callout)
            }
            Text("Only you see these previews. If an effect shows on the left but not on the right, macOS is not applying it to the video OffSight sends.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.cameraName.map { "Effects on \($0)" } ?? "Starting the camera…")
                        .font(.headline)
                    ForEach(model.effects) { effect in
                        Label(effect.id, systemImage: effect.active ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(effect.active ? Color.accentColor : Color.secondary)
                    }
                    if let mode = model.modeDescription {
                        Text("Camera mode \(mode)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Choose Effects…", action: model.showSystemControls)
                    .keyboardShortcut(.defaultAction)
            }

            Text("Choose effects in the panel that opens (Portrait, Studio Light, Background and others). They apply to your live video in every meeting app, and never to the placeholder. If the panel shows several apps, pick OffSight. You can also open it from the video icon in Control Center while this window is open.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 440)
    }

    private func pane<Content: View>(caption: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                Color.black
                content()
            }
            .frame(width: 196, height: 110)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
