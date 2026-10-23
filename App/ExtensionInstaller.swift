import AppKit
import Foundation
import OffSightCore
import os
import SystemExtensions

/// Activates or removes the OffSight Camera system extension (UR-37, NFR-18).
final class ExtensionInstaller: NSObject, OSSystemExtensionRequestDelegate {
    enum State: Equatable {
        case unknown
        case activating
        case needsUserApproval
        case activated
        case willCompleteAfterReboot
        case deactivated
        case failed(String)

        var label: String {
            switch self {
            case .unknown: return "Checking…"
            case .activating: return "Installing…"
            case .needsUserApproval: return "Waiting for your approval in System Settings"
            case .activated: return "Installed"
            case .willCompleteAfterReboot: return "Restart required"
            case .deactivated: return "Removed"
            case .failed(let message): return "Failed: \(message)"
            }
        }
    }

    var onChange: (() -> Void)?
    private(set) var state: State = .unknown { didSet { onChange?() } }
    private let log = Logger(subsystem: OffSightConstants.logSubsystem, category: "installer")

    /// Version of the camera extension embedded in this app (what activation installs).
    private(set) lazy var bundledVersion: BuildVersion? = {
        let plist = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/SystemExtensions/\(extensionIdentifier).systemextension/Contents/Info.plist")
        return BuildVersion(infoDictionary: NSDictionary(contentsOf: plist) as? [String: Any])
    }()

    private var extensionIdentifier: String {
        Bundle.main.object(forInfoDictionaryKey: "OffSightExtensionBundleID") as? String
            ?? "com.storiinnovations.offsight.camera-extension"
    }

    private enum RequestKind { case activation, deactivation, properties }
    private var requestKinds: [ObjectIdentifier: RequestKind] = [:]

    /// What macOS reports about the installed extension (diagnostics).
    private(set) var installedDescription = "not queried"
    /// The extension builds macOS knows about; nil until it has answered.
    private(set) var installedExtensions: [InstalledExtension]?

    /// The last install request's error, while the state is failed.
    var installError: String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    /// The last install failed because the app isn't in /Applications.
    private(set) var failedOutsideApplications = false

    func activate() {
        failedOutsideApplications = false
        state = .activating
        submit(OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: extensionIdentifier, queue: .main),
               kind: .activation)
    }

    func deactivate() {
        submit(OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: extensionIdentifier, queue: .main),
               kind: .deactivation)
    }

    func refreshInstalledProperties() {
        submit(OSSystemExtensionRequest.propertiesRequest(forExtensionWithIdentifier: extensionIdentifier, queue: .main),
               kind: .properties)
    }

    private func submit(_ request: OSSystemExtensionRequest, kind: RequestKind) {
        requestKinds[ObjectIdentifier(request)] = kind
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    /// Opens the System Settings page where camera extensions are approved.
    func openApprovalSettings() {
        let urlString: String
        if #available(macOS 15.0, *) {
            urlString = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        } else {
            urlString = "x-apple.systempreferences:com.apple.preference.security?General"
        }
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: OSSystemExtensionRequestDelegate

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        log.info("Replacing extension \(existing.bundleShortVersion, privacy: .public) with \(ext.bundleShortVersion, privacy: .public)")
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        log.info("Extension needs user approval")
        state = .needsUserApproval
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        let kind = requestKinds.removeValue(forKey: ObjectIdentifier(request))
        guard kind != .properties else { return }
        switch result {
        case .completed:
            state = kind == .deactivation ? .deactivated : .activated
        case .willCompleteAfterReboot:
            state = .willCompleteAfterReboot
        @unknown default:
            state = .failed("unexpected result")
        }
        log.info("Extension request finished: \(String(describing: self.state), privacy: .public)")
        refreshInstalledProperties()
    }

    func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        let previousDescription = installedDescription
        requestKinds.removeValue(forKey: ObjectIdentifier(request))
        installedExtensions = properties.map { p in
            InstalledExtension(version: BuildVersion(short: p.bundleShortVersion, build: p.bundleVersion),
                               enabled: p.isEnabled, awaitingApproval: p.isAwaitingUserApproval,
                               uninstalling: p.isUninstalling)
        }
        installedDescription = properties.isEmpty ? "none installed" : properties.map { p in
            "v\(p.bundleShortVersion) (\(p.bundleVersion)) enabled=\(p.isEnabled) awaitingApproval=\(p.isAwaitingUserApproval) uninstalling=\(p.isUninstalling)"
        }.joined(separator: "; ")
        if installedDescription != previousDescription {
            log.info("Installed extension: \(self.installedDescription, privacy: .public)")
            onChange?()
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let kind = requestKinds.removeValue(forKey: ObjectIdentifier(request))
        if kind == .properties {
            installedDescription = "query failed: \(error.localizedDescription)"
            return
        }
        log.error("Extension request failed: \(error.localizedDescription, privacy: .public)")
        if kind == .activation {
            failedOutsideApplications = (error as? OSSystemExtensionError)?.code == .unsupportedParentBundleLocation
        }
        state = .failed(error.localizedDescription)
    }
}
