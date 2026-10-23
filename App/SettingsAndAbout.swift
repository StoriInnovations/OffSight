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

/// What the About window shows about the running builds, kept current by `AppController`.
final class AboutModel: ObservableObject {
    @Published var extensionLine = "Checking…"
    @Published var extensionUpToDate = true
}

/// About window with the horizontal lockup. The imageset carries the on-light and on-dark
/// artwork as appearance variants, so the effective appearance picks the right one. It also shows
/// the app's build and the camera extension build macOS is running, which can lag behind after
/// an update until the Mac restarts.
struct AboutView: View {
    @ObservedObject var model: AboutModel

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private var appVersion: String {
        guard let version = BuildVersion(infoDictionary: Bundle.main.infoDictionary) else { return "Unknown" }
        guard let date = version.buildDate else { return version.display }
        return "\(version.display), built \(Self.dateFormatter.string(from: date))"
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
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow {
                    Text("App").foregroundStyle(.secondary)
                    Text(appVersion)
                }
                GridRow {
                    Text("Build").foregroundStyle(.secondary)
                    Text(BuildChannel.current.label)
                }
                GridRow(alignment: .top) {
                    Text("Camera extension").foregroundStyle(.secondary)
                    Label(model.extensionLine,
                          systemImage: model.extensionUpToDate ? "checkmark.circle" : "exclamationmark.triangle")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(model.extensionUpToDate ? Color.primary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.caption)
            .textSelection(.enabled)
            Text("© 2026 Stori Innovations · MIT License")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 420)
    }
}
