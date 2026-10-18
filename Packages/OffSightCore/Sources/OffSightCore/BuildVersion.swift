import Foundation

/// A bundle's version and build number, as shown in About and diagnostics. The camera extension
/// reports its own in the snapshot, so the app can tell which extension build macOS is running.
public struct BuildVersion: Codable, Equatable, Sendable {
    /// `CFBundleShortVersionString`, e.g. "0.1.0".
    public var short: String
    /// `CFBundleVersion`. Development and release builds use the Unix time of the build.
    public var build: String

    public init(short: String, build: String) {
        self.short = short
        self.build = build
    }

    public init?(infoDictionary info: [String: Any]?) {
        guard let info, let short = info["CFBundleShortVersionString"] as? String,
              let build = info["CFBundleVersion"] as? String else { return nil }
        self.init(short: short, build: build)
    }

    /// "0.1.0 (1760000000)".
    public var display: String { "\(short) (\(build))" }

    /// When the build was made, if the build number is a Unix time (after 2020).
    public var buildDate: Date? {
        guard let seconds = TimeInterval(build), seconds > 1_577_836_800, seconds < 4_102_444_800 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

/// One camera extension build macOS knows about (`OSSystemExtensionProperties`).
public struct InstalledExtension: Equatable, Sendable {
    public var version: BuildVersion
    public var enabled: Bool
    public var awaitingApproval: Bool
    public var uninstalling: Bool

    public init(version: BuildVersion, enabled: Bool, awaitingApproval: Bool, uninstalling: Bool) {
        self.version = version
        self.enabled = enabled
        self.awaitingApproval = awaitingApproval
        self.uninstalling = uninstalling
    }
}

/// Whether the camera extension macOS is running is the one this app carries, and if not, why.
public enum ExtensionVersionStatus: Equatable, Sendable {
    /// Running, and it is the build inside this app.
    case current
    /// Running a different build; `running` is nil for builds made before version reporting.
    case different(running: BuildVersion?)
    /// The app's build is installed but waits for the user to allow it in System Settings.
    case awaitingApproval
    /// The app's build is installed and allowed but macOS hasn't started it (usually until a restart).
    case installedNotStarted
    /// macOS doesn't have the app's build: the install request is pending or failed.
    case notInstalled(installedBuilds: [String], error: String?)
    /// Not running and nothing more is known yet.
    case notRunning

    /// - Parameters:
    ///   - installed: what macOS reports, or nil before it has answered.
    ///   - installError: the last install request's error, if it failed.
    public static func evaluate(connected: Bool, running: BuildVersion?, bundled: BuildVersion?,
                                installed: [InstalledExtension]? = nil, installError: String? = nil) -> Self {
        if connected {
            guard let running, let bundled else {
                // Nothing to compare against (no embedded extension found): trust what runs.
                return running == nil ? .different(running: nil) : .current
            }
            return running.build == bundled.build ? .current : .different(running: running)
        }
        guard let bundled, let installed else {
            return installError.map { .notInstalled(installedBuilds: [], error: $0) } ?? .notRunning
        }
        if let mine = installed.first(where: { $0.version.build == bundled.build && !$0.uninstalling }) {
            if mine.awaitingApproval { return .awaitingApproval }
            if mine.enabled { return .installedNotStarted }
        }
        return .notInstalled(installedBuilds: installed.filter { !$0.uninstalling }.map(\.version.build), error: installError)
    }

    /// One line for About, Settings and diagnostics.
    public func summary(bundled: BuildVersion?) -> String {
        let carried = bundled.map { "build \($0.build)" } ?? "an unknown build"
        switch self {
        case .current:
            return bundled.map { "\($0.display), up to date" } ?? "Running"
        case .different(let running):
            let what = running.map { "build \($0.build)" } ?? "an older build"
            return "Running \(what); this app carries \(carried). Restart the Mac to load it."
        case .awaitingApproval:
            return "\(carried.capitalizedFirst) is installed and waiting for you to allow it in System Settings › General › Login Items & Extensions."
        case .installedNotStarted:
            return "\(carried.capitalizedFirst) is installed but macOS hasn't started it yet. Restart the Mac."
        case .notInstalled(let builds, let error):
            let has = builds.isEmpty ? "macOS has no OffSight Camera installed" : "macOS has build \(builds.joined(separator: ", "))"
            if let error { return "Not running. \(has); installing \(carried) failed: \(error)" }
            return "Not running. \(has); this app carries \(carried) and is asking macOS to install it."
        case .notRunning:
            return "Not running. This app carries \(carried)."
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
