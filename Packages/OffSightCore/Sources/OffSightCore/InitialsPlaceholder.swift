import CoreGraphics
import CoreText
import Foundation

/// A generated placeholder (UR-27): initials in a circle, with the name underneath, on a solid
/// background. Text reads correctly for other participants; a mirrored self-view shows it
/// reversed only to the user (like any text).
public enum InitialsPlaceholder {
    /// Background colours offered in Settings (sRGB, 0–255). White text is legible on all of them.
    public struct Colour: Equatable, Sendable, Identifiable {
        public let id: String
        public let name: String
        public let red: Int, green: Int, blue: Int

        public var cgColor: CGColor {
            CGColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
        }
    }

    public static let colours: [Colour] = [
        Colour(id: "slate", name: "Slate", red: 0x1C, green: 0x21, blue: 0x29),
        Colour(id: "teal", name: "Teal", red: 0x2F, green: 0x85, blue: 0x80),
        Colour(id: "navy", name: "Navy", red: 0x1F, green: 0x3A, blue: 0x5F),
        Colour(id: "plum", name: "Plum", red: 0x5B, green: 0x3A, blue: 0x6B),
        Colour(id: "forest", name: "Forest", red: 0x2E, green: 0x5D, blue: 0x4B),
        Colour(id: "graphite", name: "Graphite", red: 0x3A, green: 0x3F, blue: 0x47),
    ]

    public static func colour(id: String) -> Colour {
        colours.first { $0.id == id } ?? colours[0]
    }

    /// "Ada Lovelace" → "AL"; "Grace" → "G"; "ab" → "AB" (short input is taken as initials).
    public static func initials(from name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let words = trimmed.split(whereSeparator: { $0.isWhitespace || $0 == "-" }).map(String.init)
        if words.count == 1, trimmed.count <= 3 {
            return trimmed.uppercased()
        }
        let first = words.first?.first.map(String.init) ?? ""
        let last = words.count > 1 ? (words.last?.first.map(String.init) ?? "") : ""
        return (first + last).uppercased()
    }

    /// Renders the placeholder at exactly `dimensions`. Nil only if a bitmap can't be created.
    public static func render(name: String, colour: Colour, dimensions: Dimensions) -> CGImage? {
        let width = dimensions.width, height = dimensions.height
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.setFillColor(colour.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let unit = CGFloat(min(width, height))
        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let letters = initials(from: displayName)
        let hasName = displayName.count > 3 || displayName.contains(" ")
        let diameter = unit * 0.42
        let centre = CGPoint(x: CGFloat(width) / 2, y: CGFloat(height) / 2 + (hasName ? unit * 0.07 : 0))

        // A lighter disc behind the initials.
        context.setFillColor(CGColor(gray: 1, alpha: 0.14))
        context.fillEllipse(in: CGRect(x: centre.x - diameter / 2, y: centre.y - diameter / 2, width: diameter, height: diameter))

        if !letters.isEmpty {
            drawText(letters, in: context, size: diameter * 0.42, weight: 0.4, centre: centre, alpha: 1)
        }
        if hasName {
            let baseline = CGPoint(x: centre.x, y: centre.y - diameter / 2 - unit * 0.09)
            drawText(String(displayName.prefix(40)), in: context, size: unit * 0.055, weight: 0.23, centre: baseline, alpha: 0.85)
        }
        return context.makeImage()
    }

    private static func drawText(_ text: String, in context: CGContext, size: CGFloat, weight: CGFloat,
                                 centre: CGPoint, alpha: CGFloat) {
        let traits: [CFString: Any] = [kCTFontWeightTrait: weight]
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontFamilyNameAttribute: "Helvetica Neue",
            kCTFontTraitsAttribute: traits,
        ] as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: alpha),
        ]
        guard let attributed = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary) else { return }
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetImageBounds(line, context)
        context.textPosition = CGPoint(x: centre.x - bounds.width / 2 - bounds.minX,
                                       y: centre.y - bounds.height / 2 - bounds.minY)
        CTLineDraw(line, context)
    }
}
