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

/// Mean and max absolute per-channel difference (0…1) between two equally sized renderings.
func difference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> (mean: Double, max: Double) {
    var total = 0.0, worst = 0.0, count = 0.0
    for y in 0..<a.pixelsHigh {
        for x in 0..<a.pixelsWide {
            for (p, q) in zip(rgba(a, x, y), rgba(b, x, y)) {
                let d = Double(abs(p - q))
                total += d; worst = max(worst, d); count += 1
            }
        }
    }
    return (total / count, worst)
}

func reference(_ relativePath: String) -> NSImage? {
    NSImage(contentsOf: handoffURL.appendingPathComponent(relativePath))
}

func compare(asset: String, bundle: Bundle, referencePath: String, pixels: NSSize, appearance: NSAppearance,
             label: String, tolerance: Double = 0.02) {
    guard let image = bundle.image(forResource: asset) else {
        failures.append("\(label): asset \(asset) not found in compiled catalog"); return
    }
    guard let ref = reference(referencePath) else {
        failures.append("\(label): reference \(referencePath) missing"); return
    }
    let actual = render(image, pixels: pixels, appearance: appearance)
    let expected = render(ref, pixels: pixels, appearance: appearance)
    save(actual, "\(label).png")
    let diff = difference(actual, expected)
    let ok = diff.mean <= tolerance
    print(String(format: "%@ %@  mean diff %.4f  max %.3f", ok ? "PASS" : "FAIL", label, diff.mean, diff.max))
    if !ok { failures.append("\(label): mean difference \(diff.mean) > \(tolerance)") }
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

// 2. Placeholder frames from the camera extension's own catalog.
for (asset, file, size) in [("PlaceholderCameraOff", "placeholder/placeholder-camera-off-16x9.png", NSSize(width: 480, height: 270)),
                            ("PlaceholderCameraOff4x3", "placeholder/placeholder-camera-off-4x3.png", NSSize(width: 360, height: 270))] {
    compare(asset: asset, bundle: cameraExtension, referencePath: file, pixels: size, appearance: light,
            label: "extension-\(asset)", tolerance: 0.01)
    if let image = cameraExtension.image(forResource: asset),
       let pixels = image.representations.map({ max($0.pixelsWide, 0) }).max() {
        print("     \(asset) pixel width in extension catalog: \(pixels)")
    }
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

if failures.isEmpty {
    print("All brand asset checks passed")
} else {
    print("\nFAILURES:\n- " + failures.joined(separator: "\n- "))
    exit(1)
}
