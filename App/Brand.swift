import AppKit
import OffSightCore
import SwiftUI

// Brand tokens from design_handoff_offsight_brand/README.md, backed by the colorsets in
// Assets.xcassets (light and dark variants are resolved by the asset catalog).

extension NSColor {
    static let brandSlate = NSColor(named: "BrandSlate") ?? NSColor(srgbRed: 0x1C / 255, green: 0x21 / 255, blue: 0x29 / 255, alpha: 1)
    static let brandForeground = NSColor(named: "BrandForeground") ?? NSColor(srgbRed: 0xD9 / 255, green: 0xDE / 255, blue: 0xE5 / 255, alpha: 1)
    static let brandTeal = NSColor(named: "BrandTeal") ?? NSColor(srgbRed: 0x2F / 255, green: 0x85 / 255, blue: 0x80 / 255, alpha: 1)
    static let statusLive = NSColor(named: "StatusLive") ?? NSColor(srgbRed: 0xE5 / 255, green: 0x35 / 255, blue: 0x2B / 255, alpha: 1)
    static let statusWarning = NSColor(named: "StatusWarning") ?? NSColor(srgbRed: 0xD9 / 255, green: 0x7A / 255, blue: 0x00 / 255, alpha: 1)
}

extension Color {
    static let brandSlate = Color("BrandSlate")
    static let brandForeground = Color("BrandForeground")
    static let brandTeal = Color("BrandTeal")
    static let statusLive = Color("StatusLive")
    static let statusWarning = Color("StatusWarning")
}

enum BrandAsset {
    static let lockupHorizontal = "LockupHorizontal"
}

extension ProtectionState {
    /// Template imageset (monochrome; macOS tints it).
    var menuBarAssetName: String {
        switch self {
        case .idle: return "MenuBarIdle"
        case .protected: return "MenuBarProtected"
        case .live: return "MenuBarLive"
        case .unprotected: return "MenuBarUnprotected"
        case .paused: return "MenuBarPaused"
        }
    }

    /// Optional coloured-badge imageset (light and dark variants).
    var menuBarColorAssetName: String { menuBarAssetName + "Color" }

    /// Accessibility description and tooltip, verbatim from the brand README.
    var accessibilityDescription: String {
        switch self {
        case .idle: return "OffSight: idle"
        case .protected: return "OffSight: camera protected"
        case .live: return "OffSight: camera live"
        case .unprotected: return "OffSight: camera unprotected"
        case .paused: return "OffSight: protection paused"
        }
    }
}
