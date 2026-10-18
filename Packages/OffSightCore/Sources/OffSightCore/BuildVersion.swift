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

/// Whether the camera extension macOS is running is the one this app carries.
public enum ExtensionVersionStatus: Equatable, Sendable {
    /// No running extension is connected.
    case notRunning
    /// Running, and it is the build inside this app.
    case current
    /// Running a different build; `running` is nil for builds made before version reporting.
    case different(running: BuildVersion?)

    public static func evaluate(connected: Bool, running: BuildVersion?, bundled: BuildVersion?) -> Self {
        guard connected else { return .notRunning }
        guard let running, let bundled else {
            // Nothing to compare against (no embedded extension found): trust what runs.
            return running == nil ? .different(running: nil) : .current
        }
        return running.build == bundled.build ? .current : .different(running: running)
    }

    /// One line for About, Settings and diagnostics.
    public func summary(bundled: BuildVersion?) -> String {
        let carried = bundled.map { "build \($0.build)" } ?? "an unknown build"
        switch self {
        case .notRunning:
            return "Not running. This app carries \(carried)."
        case .current:
            return bundled.map { "\($0.display), up to date" } ?? "Running"
        case .different(let running):
            let what = running.map { "build \($0.build)" } ?? "an older build"
            return "Running \(what); this app carries \(carried). Restart the Mac to load it."
        }
    }
}
