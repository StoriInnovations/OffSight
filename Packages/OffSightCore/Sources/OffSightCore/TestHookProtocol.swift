import Foundation

/// Messages between Debug builds of OffSight.app and the on-device test tool (Tools/OffSightTest),
/// carried as distributed notifications. Only Debug builds of the app listen; Release and App Store
/// builds don't compile the listener, so no other process can approve a session there (NFR-04).
public enum TestHook {
    /// Tool → app. The notification's object is a command string (see `Command`).
    public static let commandNotification = "com.storiinnovations.offsight.test.command"
    /// App → tool. The notification's object is a JSON-encoded `TestHookState`.
    public static let stateNotification = "com.storiinnovations.offsight.test.state"

    public enum Command: Equatable, Sendable {
        case state
        case approve(app: String)          // "*" for every session
        case keepPlaceholder(app: String)  // "*" for every session
        case closeAllShutters
        case pause(minutes: Int)
        case resume
        case setPromptExpiry(seconds: Double)
        case setGracePeriod(seconds: Double)

        public var encoded: String {
            switch self {
            case .state: return "state"
            case .approve(let app): return "approve:\(app)"
            case .keepPlaceholder(let app): return "keep:\(app)"
            case .closeAllShutters: return "closeAll"
            case .pause(let minutes): return "pause:\(minutes)"
            case .resume: return "resume"
            case .setPromptExpiry(let seconds): return "setPromptExpiry:\(seconds)"
            case .setGracePeriod(let seconds): return "setGrace:\(seconds)"
            }
        }

        public init?(encoded: String) {
            let parts = encoded.split(separator: ":", maxSplits: 1).map(String.init)
            let argument = parts.count > 1 ? parts[1] : ""
            switch parts.first {
            case "state": self = .state
            case "approve" where !argument.isEmpty: self = .approve(app: argument)
            case "keep" where !argument.isEmpty: self = .keepPlaceholder(app: argument)
            case "closeAll": self = .closeAllShutters
            case "pause": guard let minutes = Int(argument), minutes > 0 else { return nil }; self = .pause(minutes: minutes)
            case "resume": self = .resume
            case "setPromptExpiry": guard let seconds = Double(argument) else { return nil }; self = .setPromptExpiry(seconds: seconds)
            case "setGrace": guard let seconds = Double(argument) else { return nil }; self = .setGracePeriod(seconds: seconds)
            default: return nil
            }
        }
    }
}

/// A snapshot of the app's state for the test tool. Times are seconds since 1970 (both processes
/// share the clock, so the tool can measure latencies against its own events).
public struct TestHookState: Codable, Equatable, Sendable {
    public struct SessionInfo: Codable, Equatable, Sendable {
        public var app: String
        public var name: String
        public var phase: String
        public var startedAt: Double
        public init(app: String, name: String, phase: String, startedAt: Double) {
            self.app = app; self.name = name; self.phase = phase; self.startedAt = startedAt
        }
    }

    public struct PromptInfo: Codable, Equatable, Sendable {
        public var app: String
        public var name: String
        public var shownAt: Double
        public init(app: String, name: String, shownAt: Double) {
            self.app = app; self.name = name; self.shownAt = shownAt
        }
    }

    public var time: Double
    public var live: Bool
    public var paused: Bool
    public var protectionState: String
    public var sessions: [SessionInfo]
    public var prompts: [PromptInfo]
    public var extensionConnected: Bool
    public var cameraFormat: String?
    public var promptExpiry: Double
    public var gracePeriod: Double
    public var liveFramesSent: UInt64
    public var placeholderFramesSent: UInt64
    public var recentEvents: [String]

    public init(time: Double, live: Bool, paused: Bool, protectionState: String, sessions: [SessionInfo],
                prompts: [PromptInfo], extensionConnected: Bool, cameraFormat: String?, promptExpiry: Double,
                gracePeriod: Double, liveFramesSent: UInt64, placeholderFramesSent: UInt64, recentEvents: [String]) {
        self.time = time; self.live = live; self.paused = paused; self.protectionState = protectionState
        self.sessions = sessions; self.prompts = prompts; self.extensionConnected = extensionConnected
        self.cameraFormat = cameraFormat; self.promptExpiry = promptExpiry; self.gracePeriod = gracePeriod
        self.liveFramesSent = liveFramesSent; self.placeholderFramesSent = placeholderFramesSent
        self.recentEvents = recentEvents
    }

    public var encodedJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    public static func decode(_ json: String) -> TestHookState? {
        try? JSONDecoder().decode(TestHookState.self, from: Data(json.utf8))
    }
}
