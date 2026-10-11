// Verifies the brand assets as compiled into the built app, against the reference PNG exports in
// the design handoff. Run on macOS:
//   swift scripts/ci/verify-brand-assets.swift <OffSight.app> <design_handoff_offsight_brand> <output dir>
// Writes every rendering to <output dir> (uploaded as a CI artifact) and exits non-zero on a mismatch.
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    print("usage: verify-brand-assets.swift <app> <handoff dir> <output dir>")
    exit(2)
}
let appURL = URL(fileURLWithPath: arguments[1])
let handoffURL = URL(fileURLWithPath: arguments[2])
let outputURL = URL(fileURLWithPath: arguments[3])
try? FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

guard let app = Bundle(url: appURL) else { print("cannot open \(appURL.path)"); exit(2) }
let extensionURL = appURL.appendingPathComponent(
    "Contents/Library/SystemExtensions/com.storiinnovations.offsight.camera-extension.systemextension")
guard let cameraExtension = Bundle(url: extensionURL) else { print("cannot open \(extensionURL.path)"); exit(2) }

var failures: [String] = []
var warnings: [String] = []
let light = NSAppearance(named: .aqua)!
let dark = NSAppearance(named: .darkAqua)!

func render(_ image: NSImage, pixels: NSSize, appearance: NSAppearance) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = pixels
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    appearance.performAsCurrentDrawingAppearance {
        image.draw(in: NSRect(origin: .zero, size: pixels), from: .zero, operation: .copy, fraction: 1)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func save(_ rep: NSBitmapImageRep, _ name: String) {
    try? rep.representation(using: .png, properties: [:])?.write(to: outputURL.appendingPathComponent(name))
}

func rgba(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> [CGFloat] {
    guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return [0, 0, 0, 0] }
    // Premultiply so fully transparent pixels compare equal whatever their RGB.
    return [color.redComponent * color.alphaComponent, color.greenComponent * color.alphaComponent,
            color.blueComponent * color.alphaComponent, color.alphaComponent]
}

struct Comparison {
    var mean = 0.0          // mean absolute per-channel difference (informational)
    var shapeOverlap = 1.0  // intersection-over-union of the opaque (alpha > 0.5) areas
    var interiorColour = 0.0 // mean RGB difference where both are solid (alpha > 0.95)
    var map: [String] = []  // per-pixel difference, for diagnosing failures
}

/// Compares two equally sized renderings. Separate SVG renderers anti-alias edges differently,
/// so the shape (opaque area) and the colour of solid areas are judged instead of raw pixels.
func compareRenders(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Comparison {
    var result = Comparison()
    var total = 0.0, samples = 0.0, both = 0.0, either = 0.0, interior = 0.0, interiorCount = 0.0
    let shades = Array(" .:-=+*#%@")
    for y in 0..<a.pixelsHigh {
        var row = ""
        for x in 0..<a.pixelsWide {
            let p = rgba(a, x, y), q = rgba(b, x, y)
            var worst = 0.0
            for (u, v) in zip(p, q) {
                let d = Double(abs(u - v)); total += d; samples += 1; worst = max(worst, d)
            }
            let opaqueA = p[3] > 0.5, opaqueB = q[3] > 0.5
            if opaqueA && opaqueB { both += 1 }
            if opaqueA || opaqueB { either += 1 }
            if p[3] > 0.95 && q[3] > 0.95 {
                // Un-premultiplied RGB difference.
                let alphaA = Double(p[3]), alphaB = Double(q[3])
                var d = 0.0
                for channel in 0..<3 {
                    let ca = Double(p[channel]) / alphaA
                    let cb = Double(q[channel]) / alphaB
                    d += abs(ca - cb)
                }
                interior += d / 3
                interiorCount += 1
            }
            row.append(shades[min(shades.count - 1, Int(worst * Double(shades.count)))])
        }
        result.map.append(row)
    }
    result.mean = total / samples
    result.shapeOverlap = either == 0 ? 1 : both / either
    result.interiorColour = interiorCount == 0 ? 0 : interior / interiorCount
    return result
}

func reference(_ relativePath: String) -> NSImage? {
    NSImage(contentsOf: handoffURL.appendingPathComponent(relativePath))
}

func compare(asset: String, bundle: Bundle, referencePath: String, pixels: NSSize, appearance: NSAppearance,
             label: String, minOverlap: Double = 0.9, maxInteriorColour: Double = 0.03, image override: NSImage? = nil) {
    guard let image = override ?? bundle.image(forResource: asset) else {
        failures.append("\(label): asset \(asset) not found in compiled catalog"); return
    }
    guard let ref = reference(referencePath) else {
        failures.append("\(label): reference \(referencePath) missing"); return
    }
    let actual = render(image, pixels: pixels, appearance: appearance)
    let expected = render(ref, pixels: pixels, appearance: appearance)
    save(actual, "\(label).png")
    save(expected, "\(label)-reference.png")
    let c = compareRenders(actual, expected)
    let colourOK = c.interiorColour <= maxInteriorColour
    // Below minOverlap but above warnOverlap, with matching colour, is a renderer difference in fine
    // edges (e.g. thin mask seams): flagged for a human look, not failed.
    let warnOverlap = minOverlap - 0.1
    let verdict: String
    if colourOK && c.shapeOverlap >= minOverlap {
        verdict = "PASS"
    } else if colourOK && c.shapeOverlap >= warnOverlap {
        verdict = "WARN"
        warnings.append("\(label): shape overlap \(String(format: "%.3f", c.shapeOverlap)) (colour exact); check \(label).png against \(label)-reference.png")
    } else {
        verdict = "FAIL"
        failures.append("\(label): overlap \(c.shapeOverlap), solid colour diff \(c.interiorColour)")
    }
    print(String(format: "%@ %@  shape overlap %.3f  solid-colour diff %.4f  (mean pixel diff %.4f)",
                 verdict, label, c.shapeOverlap, c.interiorColour, c.mean))
    if verdict != "PASS" {
        print("     difference map (rows top to bottom, ' ' = identical, '@' = fully different):")
        for row in c.map { print("     |\(row)|") }
    }
}

// 1. Menu bar glyphs (template and coloured), rendered at 2x (36×36 px) vs the PNG exports.
let states = ["idle", "protected", "live", "unprotected", "paused"]
for state in states {
    let asset = "MenuBar" + state.prefix(1).uppercased() + state.dropFirst()
    compare(asset: asset, bundle: app, referencePath: "png/menubar/menubar-\(state)-2x.png",
            pixels: NSSize(width: 36, height: 36), appearance: light, label: "menubar-\(state)")
    compare(asset: asset + "Color", bundle: app, referencePath: "png/menubar-color/menubar-\(state)-color-light-2x.png",
            pixels: NSSize(width: 36, height: 36), appearance: light, label: "menubar-\(state)-color-light")
    compare(asset: asset + "Color", bundle: app, referencePath: "png/menubar-color/menubar-\(state)-color-dark-2x.png",
            pixels: NSSize(width: 36, height: 36), appearance: dark, label: "menubar-\(state)-color-dark")
    if let image = app.image(forResource: asset), image.isTemplate == false {
        failures.append("\(asset): expected template rendering intent")
    }
}

// 2. Placeholder frames: the plain PNG resources the camera extension ships (it reads them with
// ImageIO; AppKit is not usable in a camera extension).
for (resource, file, size) in [("placeholder-camera-off-16x9", "placeholder/placeholder-camera-off-16x9.png", NSSize(width: 480, height: 270)),
                               ("placeholder-camera-off-4x3", "placeholder/placeholder-camera-off-4x3.png", NSSize(width: 360, height: 270))] {
    guard let url = cameraExtension.url(forResource: resource, withExtension: "png"),
          let image = NSImage(contentsOf: url) else {
        failures.append("extension-\(resource): not bundled in the camera extension"); continue
    }
    compare(asset: resource, bundle: cameraExtension, referencePath: file, pixels: size, appearance: light,
            label: "extension-\(resource)", minOverlap: 0.99, maxInteriorColour: 0.01, image: image)
    let pixels = image.representations.map(\.pixelsWide).max() ?? 0
    print("     \(resource) pixel width in extension: \(pixels)")
}

// 3. App icon compiled into the bundle.
let iconPath = appURL.appendingPathComponent("Contents/Resources/AppIcon.icns").path
if FileManager.default.fileExists(atPath: iconPath), app.object(forInfoDictionaryKey: "CFBundleIconName") as? String == "AppIcon" {
    print("PASS app icon: AppIcon.icns present, CFBundleIconName = AppIcon")
    if let icon = NSImage(contentsOfFile: iconPath) {
        save(render(icon, pixels: NSSize(width: 256, height: 256), appearance: light), "appicon-256.png")
    }
} else {
    failures.append("app icon: AppIcon.icns or CFBundleIconName missing")
}

// 4. Colours.
let expectedColours: [String: (light: String, dark: String)] = [
    "BrandSlate": ("1C2129", "1C2129"), "BrandForeground": ("D9DEE5", "D9DEE5"), "BrandTeal": ("2F8580", "6FC7C2"),
    "StatusLive": ("E5352B", "FF5A4F"), "StatusWarning": ("D97A00", "FFB23F"),
]
func hex(_ color: NSColor?, _ appearance: NSAppearance) -> String {
    var result = "missing"
    appearance.performAsCurrentDrawingAppearance {
        if let c = color?.usingColorSpace(.sRGB) {
            result = String(format: "%02X%02X%02X", Int((c.redComponent * 255).rounded()),
                            Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
        }
    }
    return result
}
for (name, expected) in expectedColours.sorted(by: { $0.key < $1.key }) {
    let color = NSColor(named: name, bundle: app)
    let got = (hex(color, light), hex(color, dark))
    let ok = got.0 == expected.light && got.1 == expected.dark
    print("\(ok ? "PASS" : "FAIL") colour \(name): light \(got.0) dark \(got.1)")
    if !ok { failures.append("colour \(name): got \(got), expected \(expected)") }
}

// 5. Lockup: SVG <text> rendering is not guaranteed in asset catalogs, so measure ink in the
// wordmark area (right of the mark) and save both appearances for review.
if let lockup = app.image(forResource: "LockupHorizontal") {
    for (appearance, label) in [(light, "light"), (dark, "dark")] {
        let rep = render(lockup, pixels: NSSize(width: 645, height: 200), appearance: appearance)
        save(rep, "lockup-\(label).png")
        var ink = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 210, to: rep.pixelsWide, by: 2) where rgba(rep, x, y)[3] > 0.5 { ink += 1 }
        }
        let ok = ink > 500
        print("\(ok ? "PASS" : "FAIL") lockup-\(label): wordmark ink samples \(ink)")
        if !ok { failures.append("lockup-\(label): wordmark text did not render (ink \(ink))") }
    }
} else {
    failures.append("LockupHorizontal not found")
}

for warning in warnings {
    // Surfaces as an annotation on the GitHub Actions run.
    print("::warning title=Brand asset needs visual check::\(warning)")
}
if failures.isEmpty {
    print(warnings.isEmpty ? "All brand asset checks passed" : "Brand asset checks passed with \(warnings.count) warning(s)")
} else {
    print("\nFAILURES:\n- " + failures.joined(separator: "\n- "))
    exit(1)
}
