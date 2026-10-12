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

/// Settings (UR-39): the placeholder image (UR-26) and the optional coloured status icon
/// (brand README, "Colour").
struct SettingsView: View {
    @AppStorage(AppDefaults.useColouredStatusIconKey) private var useColouredStatusIcon = false

    var body: some View {
        Form {
            PlaceholderSettings()
            Divider()
                .padding(.vertical, 6)
            Toggle("Coloured status icon", isOn: $useColouredStatusIcon)
            Text("Adds a coloured badge to the menu bar icon. The shapes alone always show the state.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 380)
    }
}

/// Choose what meeting apps see until you go live: the built-in artwork or your own image.
private struct PlaceholderSettings: View {
    @State private var thumbnail: CGImage?
    @State private var name: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Placeholder")
                .font(.headline)
            HStack(alignment: .top, spacing: 12) {
                preview
                    .frame(width: 128, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.4)))
                VStack(alignment: .leading, spacing: 6) {
                    Text(name ?? "OffSight default")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack {
                        Button("Choose Image…", action: chooseImage)
                        Button("Use Default", action: useDefault)
                            .disabled(name == nil)
                    }
                }
            }
            Text("Shown to meeting apps until you go live. PNG, JPEG or HEIC; it fills the frame, so the edges of images with another shape are trimmed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear(perform: reload)
    }

    @ViewBuilder
    private var preview: some View {
        if let thumbnail {
            Image(decorative: thumbnail, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Image(PlaceholderLayout.Artwork.wide16x9.assetName)
                .resizable()
                .aspectRatio(contentMode: .fill)
        }
    }

    private func reload() {
        name = PlaceholderImageStore.originalName
        thumbnail = PlaceholderImageStore.loadThumbnail()
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = PlaceholderImageStore.allowedTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose the image meeting apps see until you go live."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PlaceholderImageStore.importImage(from: url)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        reload()
    }

    private func useDefault() {
        PlaceholderImageStore.useDefault()
        errorMessage = nil
        reload()
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
