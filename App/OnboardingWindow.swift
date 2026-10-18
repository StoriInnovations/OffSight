import AppKit
import AVFoundation
import OffSightCore
import SwiftUI
import UserNotifications

/// State and actions for the first-run guide (UR-36, UR-37, UR-38). AppController keeps the
/// extension status current while the window is open.
final class OnboardingModel: ObservableObject {
    enum Step: Int, CaseIterable {
        case welcome, cameraExtension, cameraAccess, notifications, meetingApps, finish
    }

    @Published var step: Step = .welcome
    @Published var extensionStatus = ""
    @Published var extensionConnected = false
    @Published var extensionNeedsApproval = false
    @Published private(set) var cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @Published private(set) var notificationsAllowed: Bool?
    @Published var launchAtLogin = true
    @Published private(set) var meetingApps: [MeetingAppGuide] = []

    var installExtension: () -> Void = {}
    var openExtensionApproval: () -> Void = {}
    var finished: (_ launchAtLogin: Bool) -> Void = { _ in }

    func refresh() {
        cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        meetingApps = MeetingAppGuide.installed { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let allowed: Bool? = switch settings.authorizationStatus {
            case .authorized, .provisional: true
            case .denied: false
            default: nil
            }
            DispatchQueue.main.async { self.notificationsAllowed = allowed }
        }
    }

    func requestCameraAccess() {
        AVCaptureDevice.requestAccess(for: .video) { _ in
            DispatchQueue.main.async { self.refresh() }
        }
    }

    func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            DispatchQueue.main.async { self.refresh() }
        }
    }

    func openCameraPrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }

    func openApp(_ guide: MeetingAppGuide) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: guide.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func next() {
        refresh()
        if let following = Step(rawValue: step.rawValue + 1) { step = following }
    }

    func back() {
        if let previous = Step(rawValue: step.rawValue - 1) { step = previous }
    }

    var protectionActive: Bool { extensionConnected && cameraStatus == .authorized }
}

/// The first-run guide window. Shown on first launch and from Settings › General.
final class OnboardingWindowController {
    let model = OnboardingModel()
    private var window: NSWindow?

    func show() {
        model.step = .welcome
        model.refresh()
        if window == nil {
            let newWindow = NSWindow(contentViewController: NSHostingController(rootView: OnboardingView(model: model)))
            newWindow.title = "Welcome to OffSight"
            newWindow.styleMask = [.titled, .closable]
            newWindow.isReleasedWhenClosed = false
            newWindow.center()
            window = newWindow
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }
}

private struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProgressDots(current: model.step.rawValue, count: OnboardingModel.Step.allCases.count)
                .padding(.bottom, 16)
            Group {
                switch model.step {
                case .welcome: WelcomeStep()
                case .cameraExtension: ExtensionStep(model: model)
                case .cameraAccess: CameraStep(model: model)
                case .notifications: NotificationsStep(model: model)
                case .meetingApps: MeetingAppsStep(model: model)
                case .finish: FinishStep(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider().padding(.vertical, 12)
            HStack {
                if model.step != .welcome {
                    Button("Back", action: model.back)
                }
                Spacer()
                if model.step == .finish {
                    Button("Done") { model.finished(model.launchAtLogin) }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(model.step == .welcome ? "Get Started" : "Continue", action: model.next)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 560, height: 470)
    }
}

private struct ProgressDots: View {
    let current: Int
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index <= current ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: index == current ? 22 : 8, height: 8)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}

private struct StepHeader: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title2.weight(.semibold))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 12)
    }
}

private struct StatusLine: View {
    let ok: Bool
    let text: String

    var body: some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
            .foregroundStyle(ok ? Color.green : Color.orange)
    }
}

private struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(BrandAsset.lockupHorizontal)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 220)
                .accessibilityLabel("OffSight")
                .padding(.bottom, 8)
            StepHeader(title: "A camera shutter, in software",
                       text: "Meeting apps see a “Camera off” picture until you say Go live, for that app, for that call.")
            Label("OffSight adds a camera called OffSight Camera. You choose it once in each meeting app.", systemImage: "video")
            Label("When an app turns it on, OffSight asks you first, with a preview only you can see.", systemImage: "hand.raised")
            Label("Approval lasts one call. There is no “always allow”. If anything goes wrong, apps keep the placeholder.", systemImage: "lock")
            Label("Everything stays on your Mac. OffSight collects no data.", systemImage: "desktopcomputer")
        }
    }
}

private struct ExtensionStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepHeader(title: "Allow OffSight Camera",
                       text: "macOS asks you to approve the camera OffSight adds. Without it, meeting apps can't use OffSight Camera.")
            StatusLine(ok: model.extensionConnected,
                       text: model.extensionConnected ? "OffSight Camera is ready" : "Status: \(model.extensionStatus)")
            if !model.extensionConnected {
                Text("On macOS 15 or later: System Settings › General › Login Items & Extensions › Camera Extensions, then turn on OffSight. On macOS 13 or 14: System Settings › Privacy & Security, then Allow.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open System Settings", action: model.openExtensionApproval)
                    Button("Install Again", action: model.installExtension)
                }
                Text("If it says it's installed but not running, restart your Mac; you can finish this guide afterwards from Settings › General.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct CameraStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepHeader(title: "Allow camera access",
                       text: "OffSight uses your camera only for the private preview in its prompt, and for live video you approve. It never records or stores video.")
            switch model.cameraStatus {
            case .authorized:
                StatusLine(ok: true, text: "Camera access allowed")
            case .denied, .restricted:
                StatusLine(ok: false, text: "Camera access is off")
                Button("Open Camera Privacy Settings", action: model.openCameraPrivacy)
            default:
                Button("Allow Camera Access", action: model.requestCameraAccess)
            }
        }
    }
}

private struct NotificationsStep: View {
    @ObservedObject var model: OnboardingModel
    @AppStorage(AppDefaults.notificationsEnabledKey) private var notificationsEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepHeader(title: "Notifications (optional)",
                       text: "OffSight can tell you when an app goes live and when its session ends.")
            Toggle("Notify me when an app goes live and when its session ends", isOn: $notificationsEnabled)
            if notificationsEnabled {
                switch model.notificationsAllowed {
                case true?: StatusLine(ok: true, text: "Notifications allowed")
                case false?: StatusLine(ok: false, text: "Notifications are off in System Settings › Notifications › OffSight")
                case nil: Button("Allow Notifications", action: model.requestNotifications)
                }
            }
        }
    }
}

private struct MeetingAppsStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StepHeader(title: "Choose OffSight Camera in your meeting apps",
                       text: "Do this once per app; it remembers. Any app still set to your real camera bypasses OffSight, and the menu bar icon will warn you.")
            if model.meetingApps.isEmpty {
                Text("No supported meeting apps found. When you install one, choose OffSight Camera in its video settings.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(model.meetingApps, id: \.bundleID) { guide in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(guide.name).font(.headline)
                                    Text(guide.whereToChoose)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                Button("Open") { model.openApp(guide) }
                                    .accessibilityLabel("Open \(guide.name)")
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct FinishStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepHeader(title: model.protectionActive ? "Protection is active" : "Almost there",
                       text: model.protectionActive
                           ? "Meeting apps using OffSight Camera now see the placeholder until you approve them."
                           : "Some steps aren't finished yet. Meeting apps still get the placeholder, but you can't go live until they are.")
            StatusLine(ok: model.extensionConnected, text: model.extensionConnected ? "OffSight Camera ready" : "OffSight Camera not ready")
            StatusLine(ok: model.cameraStatus == .authorized,
                       text: model.cameraStatus == .authorized ? "Camera access allowed" : "Camera access not allowed")
            Toggle("Launch OffSight at login (recommended)", isOn: $model.launchAtLogin)
                .padding(.top, 8)
            Text("OffSight then also restarts itself if it ever quits unexpectedly. You can change this in Settings › General.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Look for the iris icon in the menu bar. Help is in its menu.")
                .padding(.top, 8)
        }
    }
}
