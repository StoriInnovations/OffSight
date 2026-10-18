import AppKit
import AVFoundation
import SwiftUI

/// Optional small self-view in a corner of the screen while any app is live (Settings › Camera).
///
/// Besides showing the user what meeting apps see, it keeps OffSight presenting camera video on
/// screen while live. macOS applied the video effects chosen for OffSight to its preview while the
/// prompt was open, but not to the live video sent after the prompt closed (B2); this tests
/// whether an on-screen preview is what keeps them running.
///
/// Like the prompt preview it is visible only to the user: excluded from screen sharing (NFR-05)
/// and never sent to any app.
final class SelfViewPanelController {
    private var panel: NSPanel?
    private let session: AVCaptureSession

    init(session: AVCaptureSession) {
        self.session = session
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        if visible {
            makePanelIfNeeded().orderFrontRegardless()
        } else {
            panel?.orderOut(nil)
        }
    }

    private func makePanelIfNeeded() -> NSPanel {
        if let panel { return panel }
        let size = NSSize(width: 192, height: 108)
        let newPanel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        newPanel.contentView = NSHostingView(rootView: SelfView(session: session))
        newPanel.level = .floating
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.isMovableByWindowBackground = true
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = true
        newPanel.hidesOnDeactivate = false
        newPanel.sharingType = .none // NFR-05
        newPanel.setAccessibilityLabel("OffSight self-view while live")
        if !newPanel.setFrameUsingName("OffSightSelfView"), let screen = NSScreen.main {
            let visible = screen.visibleFrame
            newPanel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 16, y: visible.minY + 16))
        }
        newPanel.setFrameAutosaveName("OffSightSelfView")
        panel = newPanel
        return newPanel
    }
}

private struct SelfView: View {
    let session: AVCaptureSession

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            CameraPreview(session: session)
                .accessibilityLabel("Your live camera, visible only to you")
            Label("Live", systemImage: "video.fill")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(6)
        }
        .frame(width: 192, height: 108)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
