import AppKit
import OffSightCore
import SwiftUI

/// Small window controller that hosts a SwiftUI view and brings the (menu bar only) app forward.
final class HostedWindowController<Content: View> {
    private var window: NSWindow?
    private let title: String
    private let makeContent: () -> Content

    init(title: String, content: @escaping () -> Content) {
        self.title = title
        self.makeContent = content
    }

    func show() {
        if window == nil {
            let newWindow = NSWindow(contentViewController: NSHostingController(rootView: makeContent()))
            newWindow.title = title
            newWindow.styleMask = [.titled, .closable]
            newWindow.isReleasedWhenClosed = false
            newWindow.center()
            window = newWindow
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// About window with the horizontal lockup. The imageset carries the on-light and on-dark
/// artwork as appearance variants, so the effective appearance picks the right one.
struct AboutView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(BrandAsset.lockupHorizontal)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 258)
                .accessibilityLabel("OffSight")
            Text("A software camera shutter: meeting apps see a placeholder until you approve live video for each session.")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(version)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("© 2026 Stori Innovations · MIT License")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 380)
    }
}
