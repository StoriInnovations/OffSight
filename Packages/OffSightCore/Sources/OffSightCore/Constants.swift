import Foundation

/// Identifiers shared by OffSight.app and the OffSight Camera extension.
/// Changing any of these breaks the app <-> extension contract.
public enum OffSightConstants {
    public static let logSubsystem = "com.storiinnovations.offsight"

    public static let deviceName = "OffSight Camera"
    public static let deviceModel = "OffSight Virtual Camera"
    public static let manufacturer = "Stori Innovations"

    public static let deviceUUID = UUID(uuidString: "6F2D3A51-8C4B-4E8B-9C2E-0FF5160C0A01")!
    public static let sourceStreamUUID = UUID(uuidString: "6F2D3A51-8C4B-4E8B-9C2E-0FF5160C0A02")!
    public static let sinkStreamUUID = UUID(uuidString: "6F2D3A51-8C4B-4E8B-9C2E-0FF5160C0A03")!

    public static let sourceStreamName = "OffSight.Source"
    public static let sinkStreamName = "OffSight.Sink"

    /// Read-only custom property on the source stream carrying a JSON `ClientSnapshot`.
    public static let snapshotPropertyFourCC = "osnp"
    public static var snapshotPropertyName: String { "4cc_\(snapshotPropertyFourCC)_glob_0000" }

    /// IOSurface value key carrying the `FrameTag` of a live frame sent through the sink.
    public static let frameTagSurfaceKey = "OffSightFrameTag"

    public static let frameRate: Int32 = 30

    /// OffSight Camera offers exactly one format, `effectsFreeFormat(for:)` of the physical camera
    /// used as the live source, reported by OffSight.app. This is used until the first report arrives.
    public static let defaultFormat = Dimensions(width: 2560, height: 1440)

    /// macOS applies the user's video effects (Portrait, Background, Studio Light…) per app to any
    /// camera, virtual ones included, but only to video smaller than 1920×1440 (Apple forum thread
    /// 805786). Those effects blank the placeholder. OffSight Camera therefore never advertises a
    /// size below that: a camera that is smaller is scaled up, keeping its shape (1920×1080 →
    /// 2560×1440, 4:3 → 1920×1440). Live video loses no detail; effects for live video are applied
    /// on OffSight's own capture of the physical camera instead.
    public static let effectsMinimum = Dimensions(width: 1920, height: 1440)

    public static func effectsFreeFormat(for native: Dimensions) -> Dimensions {
        guard isAcceptableFormat(native) else { return defaultFormat }
        let scale = max(1, Double(effectsMinimum.width) / Double(native.width),
                        Double(effectsMinimum.height) / Double(native.height))
        func scaled(_ value: Int, minimum: Int) -> Int {
            let result = max(minimum, Int((Double(value) * scale).rounded()))
            return result % 2 == 0 ? result : result + 1
        }
        let format = Dimensions(width: scaled(native.width, minimum: effectsMinimum.width),
                                height: scaled(native.height, minimum: effectsMinimum.height))
        // A camera so wide that scaling it up exceeds the limits keeps its own size.
        return isAcceptableFormat(format) ? format : native
    }

    /// Sanity limits for a reported camera format.
    public static func isAcceptableFormat(_ format: Dimensions) -> Bool {
        (320...3840).contains(format.width) && (240...2160).contains(format.height)
            && format.width % 2 == 0 && format.height % 2 == 0
    }
}

public struct Dimensions: Hashable, Codable, Sendable, CustomStringConvertible {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var description: String { "\(width)x\(height)" }
}

/// Packs a four-character string into a CoreMediaIO selector value, e.g. "osnp".
public func fourCharCode(_ string: String) -> UInt32 {
    precondition(string.utf8.count == 4, "FourCC must be exactly 4 ASCII characters")
    return string.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
}
