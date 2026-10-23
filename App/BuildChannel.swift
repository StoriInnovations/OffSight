import Foundation

/// Where this copy of OffSight comes from, decided at compile time by the build configuration
/// (project.yml): Debug is a local development install, AppStore the Mac App Store build (also
/// what TestFlight installs), Release the Developer ID build distributed through Homebrew.
enum BuildChannel {
    case development
    case appStore
    case homebrew

    static var current: BuildChannel {
        #if DEBUG
        return .development
        #elseif APPSTORE
        return .appStore
        #else
        return .homebrew
        #endif
    }

    /// For the About window and diagnostics.
    var label: String {
        switch self {
        case .development: return "Development build (local install)"
        case .appStore: return "Mac App Store (or TestFlight)"
        case .homebrew: return "Homebrew (Developer ID)"
        }
    }
}
