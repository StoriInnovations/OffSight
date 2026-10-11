import CoreGraphics
import Foundation

/// How the brand "Camera off" artwork is fitted to each output format (brand README, placeholder).
public enum PlaceholderLayout {
    public enum Artwork: Equatable, Sendable {
        /// `PlaceholderCameraOff`, 1920×1080.
        case wide16x9
        /// `PlaceholderCameraOff4x3`, 1440×1080.
        case standard4x3

        public var assetName: String {
            switch self {
            case .wide16x9: return "PlaceholderCameraOff"
            case .standard4x3: return "PlaceholderCameraOff4x3"
            }
        }
    }

    /// 4:3 formats use the 4:3 artwork; everything else uses the 16:9 frame.
    public static func artwork(for format: Dimensions) -> Artwork {
        guard format.height > 0 else { return .wide16x9 }
        let aspect = Double(format.width) / Double(format.height)
        return abs(aspect - 4.0 / 3.0) < 0.01 ? .standard4x3 : .wide16x9
    }

    /// Rectangle to draw an image of `source` size into so it fills `target` exactly,
    /// keeping its aspect ratio and centred (aspect-fill: overflow is cropped, never stretched).
    public static func aspectFillRect(source: CGSize, target: Dimensions) -> CGRect {
        let targetWidth = CGFloat(target.width)
        let targetHeight = CGFloat(target.height)
        guard source.width > 0, source.height > 0 else {
            return CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
        }
        let scale = max(targetWidth / source.width, targetHeight / source.height)
        let width = source.width * scale
        let height = source.height * scale
        return CGRect(x: (targetWidth - width) / 2, y: (targetHeight - height) / 2, width: width, height: height)
    }
}
