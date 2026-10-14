import AppKit
import Carbon.HIToolbox
import OffSightCore
import SwiftUI

/// Live state and actions the Settings window needs from AppController.
final class SettingsModel: ObservableObject {
    struct CameraChoice: Identifiable, Hashable {
        let id: String
        let name: String
    }

    @Published var extensionStatus = ""
    @Published var launchAtLogin = false
    @Published var launchAtLoginNeedsApproval = false
    @Published var cameras: [CameraChoice] = []
    /// Shown under a shortcut macOS refused (usually taken by another app).
    @Published var shortcutProblem: String?

    var openVideoEffects: () -> Void = {}
    var installExtension: () -> Void = {}
    var removeExtension: () -> Void = {}
    var openExtensionApproval: () -> Void = {}
    var openCameraPrivacySettings: () -> Void = {}
    var copyDiagnostics: () -> Void = {}
    var showOnboarding: () -> Void = {}

    func refresh() {
        launchAtLogin = LaunchAtLogin.isEnabled
        launchAtLoginNeedsApproval = LaunchAtLogin.needsApproval
        cameras = CameraCapture.availableCameras().map { CameraChoice(id: $0.id, name: $0.name) }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        LaunchAtLogin.setEnabled(enabled)
        refresh()
    }
}

/// Settings (UR-39), grouped into five tabs:
/// - General: launch at login, notifications, menu bar icon
/// - Camera: live camera, placeholder image, video effects for live video
/// - Approvals: prompt expiry and grace period (no "always allow", by design: UR-40)
/// - Shortcuts: close all shutters, go live for the prompted app
/// - Advanced: camera extension and diagnostics
struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        TabView {
            GeneralTab(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            CameraTab(model: model)
                .tabItem { Label("Camera", systemImage: "video") }
            ApprovalsTab()
                .tabItem { Label("Approvals", systemImage: "hand.raised") }
            ShortcutsTab(model: model)
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            AdvancedTab(model: model)
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .padding(20)
        // Grouped forms scroll and have no natural height of their own, so the window needs a
        // fixed size (without one it collapses to just the tab bar).
        .frame(width: 540, height: 500)
        .onAppear(perform: model.refresh)
    }
}

/// Explanatory text under a control.
private struct Note: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: General

private struct GeneralTab: View {
    @ObservedObject var model: SettingsModel
    @AppStorage(AppDefaults.notificationsEnabledKey) private var notifications = true
    @AppStorage(AppDefaults.useColouredStatusIconKey) private var colouredIcon = false

    var body: some View {
        Form {
            Section {
                Toggle("Launch OffSight at login", isOn: Binding(get: { model.launchAtLogin },
                                                                 set: { model.setLaunchAtLogin($0) }))
                Note("Recommended: protection only works while OffSight is running. Without it, meeting apps still get the placeholder, but you can't go live.")
                if model.launchAtLoginNeedsApproval {
                    Button("Allow in Login Items…") { LaunchAtLogin.openSystemSettings() }
                }
            }
            Section {
                Toggle("Notify when an app goes live and when its session ends", isOn: $notifications)
            }
            Section {
                Toggle("Coloured status icon", isOn: $colouredIcon)
                Note("Adds a coloured badge to the menu bar icon. The shapes alone always show the state.")
            }
            Section {
                Button("Show Welcome Guide…", action: model.showOnboarding)
                Note("Walks through setup again: the camera extension, permissions and your meeting apps.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Camera

private struct CameraTab: View {
    @ObservedObject var model: SettingsModel
    @AppStorage(AppDefaults.liveCameraIDKey) private var cameraID = ""

    var body: some View {
        Form {
            Section {
                Picker("Live camera", selection: $cameraID) {
                    Text("Automatic (built-in camera first)").tag("")
                    ForEach(model.cameras) { camera in
                        Text(camera.name).tag(camera.id)
                    }
                    if !cameraID.isEmpty, !model.cameras.contains(where: { $0.id == cameraID }) {
                        Text("Disconnected camera (automatic until it's back)").tag(cameraID)
                    }
                }
                Note("The physical camera OffSight passes through when you go live. A different camera size applies once no app is using OffSight Camera.")
            }
            Section {
                PlaceholderSettings()
            }
            Section {
                Button("Video Effects for Live Video…", action: model.openVideoEffects)
                Note("Portrait, Background and other macOS effects chosen here apply to your live video in every meeting app, never to the placeholder.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Approvals

private struct ApprovalsTab: View {
    @AppStorage(AppDefaults.promptExpiryKey) private var promptExpiry = PolicySettings.defaultPromptExpiry
    @AppStorage(AppDefaults.gracePeriodKey) private var gracePeriod = PolicySettings.defaultGracePeriod

    var body: some View {
        Form {
            Section {
                Slider(value: $promptExpiry, in: PolicySettings.promptExpiryRange, step: 5) {
                    Text("Prompt closes after \(Int(promptExpiry)) s")
                }
                Note("An unanswered prompt closes itself and the app keeps the placeholder. It never closes into live video.")
            }
            Section {
                Slider(value: $gracePeriod, in: PolicySettings.gracePeriodRange, step: 5) {
                    Text("Grace period \(Self.duration(gracePeriod))")
                }
                Note("If an app stops and restarts its camera within this time (switching cameras, a short reconnect), it keeps its approval and isn't asked again.")
            }
            Section {
                Note("Every app asks again in every new camera session. There is deliberately no \"always allow\".")
            }
        }
        .formStyle(.grouped)
    }

    private static func duration(_ seconds: Double) -> String {
        let total = Int(seconds)
        return total < 60 ? "\(total) s" : String(format: "%d:%02d min", total / 60, total % 60)
    }
}

// MARK: Shortcuts

private struct ShortcutsTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                ShortcutRecorder(title: "Close all shutters", key: AppDefaults.panicShortcutKey)
                Note("Works from any app: every meeting app goes back to the placeholder at once.")
                ShortcutRecorder(title: "Go live for the app asking now", key: AppDefaults.goLiveShortcutKey)
                Note("Approves only the app whose prompt is showing, for this session. Off unless you set it.")
            }
            if let problem = model.shortcutProblem {
                Section {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Click, then type a key combination with ⌃, ⌥ or ⌘. Esc cancels.
private struct ShortcutRecorder: View {
    let title: String
    @AppStorage private var stored: String
    @State private var recording = false
    @State private var monitor: Any?

    init(title: String, key: String) {
        self.title = title
        _stored = AppStorage(wrappedValue: "", key)
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Button(recording ? "Type the shortcut…" : (KeyboardShortcut(storageString: stored)?.displayString ?? "Not set")) {
                recording ? stopRecording() : startRecording()
            }
            .frame(minWidth: 120)
            Button("Clear") { stored = "" }
                .disabled(stored.isEmpty)
        }
        .onDisappear(perform: stopRecording)
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stopRecording()
                return nil
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard !flags.isDisjoint(with: [.command, .option, .control]) else { return nil } // needs ⌃, ⌥ or ⌘
            var modifiers = 0
            if flags.contains(.command) { modifiers |= cmdKey }
            if flags.contains(.option) { modifiers |= optionKey }
            if flags.contains(.control) { modifiers |= controlKey }
            if flags.contains(.shift) { modifiers |= shiftKey }
            let key = (event.charactersIgnoringModifiers ?? "?").uppercased()
            stored = KeyboardShortcut(keyCode: UInt32(event.keyCode), modifiers: UInt32(modifiers), key: key).storageString
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: Advanced

private struct AdvancedTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Camera extension", value: model.extensionStatus)
                HStack {
                    Button("Install / Update", action: model.installExtension)
                    Button("Approve in System Settings…", action: model.openExtensionApproval)
                    Button("Remove", action: model.removeExtension)
                }
                Note("Removing the extension takes OffSight Camera away from all meeting apps.")
            }
            Section {
                Button("Camera Privacy Settings…", action: model.openCameraPrivacySettings)
                Note("OffSight needs camera access for the prompt preview and for live video.")
            }
            Section {
                Button("Copy Diagnostics", action: model.copyDiagnostics)
                Note("Copies a plain-text report (no images, no personal content) for support.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Placeholder

/// Choose what meeting apps see until you go live: the OffSight artwork, your own image, or
/// your initials (UR-25, UR-26, UR-27).
private struct PlaceholderSettings: View {
    @State private var mode = PlaceholderImageStore.mode
    @State private var thumbnail: CGImage?
    @State private var imageName: String?
    @State private var errorMessage: String?
    @AppStorage(PlaceholderImageStore.initialsNameKey) private var initialsName = ""
    @AppStorage(PlaceholderImageStore.initialsColourKey) private var initialsColour = InitialsPlaceholder.colours[0].id

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Placeholder", selection: $mode) {
                ForEach(PlaceholderMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: mode) { newValue in
                if newValue == .image, !PlaceholderImageStore.isCustom {
                    chooseImage() // nothing to show yet: ask for one
                } else {
                    PlaceholderImageStore.mode = newValue
                }
            }

            HStack(alignment: .top, spacing: 12) {
                preview
                    .frame(width: 160, height: 90)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.4)))
                    .accessibilityLabel("Placeholder preview")
                VStack(alignment: .leading, spacing: 6) {
                    switch mode {
                    case .standard:
                        Text("The OffSight “Camera off” picture.")
                    case .image:
                        Text(imageName ?? "No image chosen")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        HStack {
                            Button("Choose Image…", action: chooseImage)
                            Button("Remove", action: removeImage)
                                .disabled(imageName == nil)
                        }
                    case .initials:
                        TextField("Your name or initials", text: $initialsName)
                            .textFieldStyle(.roundedBorder)
                        HStack(spacing: 6) {
                            ForEach(InitialsPlaceholder.colours) { colour in
                                Button {
                                    initialsColour = colour.id
                                } label: {
                                    Circle()
                                        .fill(Color(cgColor: colour.cgColor))
                                        .frame(width: 18, height: 18)
                                        .overlay(Circle().stroke(Color.accentColor, lineWidth: initialsColour == colour.id ? 2 : 0)
                                            .padding(-3))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(colour.name)
                                .accessibilityAddTraits(initialsColour == colour.id ? .isSelected : [])
                            }
                        }
                    }
                }
            }
            Note(mode == .image
                 ? "PNG, JPEG or HEIC. It fills the frame, so the edges of images with another shape are trimmed."
                 : "Shown to meeting apps until you go live.")
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
        switch mode {
        case .image where thumbnail != nil:
            Image(decorative: thumbnail!, scale: 1).resizable().aspectRatio(contentMode: .fill)
        case .initials:
            if let image = InitialsPlaceholder.render(name: initialsName, colour: InitialsPlaceholder.colour(id: initialsColour),
                                                      dimensions: Dimensions(width: 320, height: 180)) {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
            }
        default:
            Image(PlaceholderLayout.Artwork.wide16x9.assetName).resizable().aspectRatio(contentMode: .fill)
        }
    }

    private func reload() {
        mode = PlaceholderImageStore.mode
        imageName = PlaceholderImageStore.originalName
        thumbnail = PlaceholderImageStore.loadThumbnail()
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = PlaceholderImageStore.allowedTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose the image meeting apps see until you go live."
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try PlaceholderImageStore.importImage(from: url)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        reload()
    }

    private func removeImage() {
        PlaceholderImageStore.useDefault()
        errorMessage = nil
        reload()
    }
}
