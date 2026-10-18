import AppKit
import AVFoundation
import OffSightCore
import SwiftUI

/// One pending approval shown in the prompt panel.
struct PromptItem: Identifiable, Equatable {
    let app: AppKey
    let displayName: String
    let icon: NSImage?
    let expiresAt: Date?
    let shownAt: Date
    var id: String { app.id }

    static func == (lhs: PromptItem, rhs: PromptItem) -> Bool {
        lhs.app == rhs.app && lhs.displayName == rhs.displayName && lhs.expiresAt == rhs.expiresAt
    }
}

final class PromptModel: ObservableObject {
    @Published var items: [PromptItem] = []
    @Published var now = Date()
    var onApprove: ((AppKey) -> Void)?
    var onKeepPlaceholder: ((AppKey) -> Void)?
}

/// Non-activating floating panel (UR-06…09a, UR-14, UR-15). It never takes keyboard focus and
/// has no default button, so a stray Return or Space in a meeting app cannot approve.
final class PromptPanelController {
    let model = PromptModel()
    private let panel: NSPanel
    private var shownAt: [AppKey: Date] = [:]

    init(captureSession: AVCaptureSession) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 340),
                        styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                        backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.sharingType = .none // NFR-05 (best effort, spike S7)
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentView = NSHostingView(rootView: PromptListView(model: model, session: captureSession))
    }

    func update(items newItems: [PromptItem]) {
        let now = Date()
        var items = newItems
        for index in items.indices {
            let app = items[index].app
            if shownAt[app] == nil {
                shownAt[app] = now
                announce("\(items[index].displayName) wants to use your camera. It sees the placeholder until you go live. To go live, use the OffSight menu.")
            }
            items[index] = PromptItem(app: app, displayName: items[index].displayName, icon: items[index].icon,
                                      expiresAt: items[index].expiresAt, shownAt: shownAt[app]!)
        }
        shownAt = shownAt.filter { entry in items.contains { $0.app == entry.key } }
        if model.items != items { model.items = items }
        model.now = now

        if items.isEmpty {
            panel.orderOut(nil)
        } else if !panel.isVisible {
            positionPanel()
            panel.orderFrontRegardless()
        }
    }

    /// VoiceOver users hear new prompts even though the panel never takes focus (UR-14, NFR-13).
    private func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    /// When the prompt for `app` first appeared (nil if it isn't showing).
    func shownAt(for app: AppKey) -> Date? { shownAt[app] }

    private func positionPanel() {
        guard let screen = NSScreen.main else { return }
        let size = panel.frame.size
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - 16, y: frame.maxY - size.height - 8))
    }
}

/// Approval needs a real, deliberate click (threat T4): ignore clicks in the first 300 ms and
/// events that did not come from the HID system.
enum ApprovalInputGuard {
    static func isGenuine(shownAt: Date) -> Bool {
        guard Date().timeIntervalSince(shownAt) >= 0.3 else { return false }
        guard let event = NSApp.currentEvent, let cgEvent = event.cgEvent else { return false }
        let sourceState = cgEvent.getIntegerValueField(.eventSourceStateID)
        return sourceState == Int64(CGEventSourceStateID.hidSystemState.rawValue)
    }
}

private struct PromptListView: View {
    @ObservedObject var model: PromptModel
    let session: AVCaptureSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CameraPreview(session: session)
                .accessibilityLabel("Camera preview, visible only to you")
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .bottomLeading) {
                    Text("Only you can see this preview")
                        .font(.caption2)
                        .padding(6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(6)
                }
            ForEach(model.items) { item in
                PromptCard(item: item, now: model.now,
                           onApprove: { model.onApprove?(item.app) },
                           onKeep: { model.onKeepPlaceholder?(item.app) })
            }
        }
        .padding(14)
        .frame(width: 380)
    }
}

private struct PromptCard: View {
    let item: PromptItem
    let now: Date
    let onApprove: () -> Void
    let onKeep: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if let icon = item.icon {
                    Image(nsImage: icon).resizable().frame(width: 32, height: 32)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(item.displayName) wants to use your camera").font(.headline)
                    Text("It sees the placeholder until you go live.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                if let expiresAt = item.expiresAt {
                    Text("Keeps placeholder in \(max(0, Int(expiresAt.timeIntervalSince(now).rounded(.up)))) s")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel("Prompt closes automatically and keeps the placeholder")
                }
                Spacer()
                Button("Keep placeholder") {
                    if ApprovalInputGuard.isGenuine(shownAt: item.shownAt) { onKeep() }
                }
                Button("Go live for this session") {
                    if ApprovalInputGuard.isGenuine(shownAt: item.shownAt) { onApprove() }
                }
                // The prompt accepts only real clicks (threat T4), so VoiceOver activation is
                // ignored here; the menu and the go-live shortcut work with VoiceOver.
                .accessibilityHint("Click with the pointer, or use Go live in the OffSight menu.")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

/// Local-only preview from OffSight's own capture session; never sent to the sink (UR-08).
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        if let connection = layer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
