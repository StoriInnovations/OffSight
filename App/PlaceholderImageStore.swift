import CoreGraphics
import Foundation
import ImageIO
import OffSightCore
import os
import UniformTypeIdentifiers

/// What meeting apps see until the user goes live: the OffSight artwork (UR-25), the user's own
/// image (UR-26) or generated initials (UR-27).
enum PlaceholderMode: String, CaseIterable, Identifiable {
    case standard = "default"
    case image
    case initials

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "OffSight"
        case .image: return "My Image"
        case .initials: return "Initials"
        }
    }
}

extension PlaceholderImageStore {
    static let modeKey = "placeholderMode"
    static let initialsNameKey = "placeholderInitialsName"
    static let initialsColourKey = "placeholderInitialsColour"

    /// The chosen mode. Before modes existed, a stored image meant "my image".
    static var mode: PlaceholderMode {
        get {
            if let raw = UserDefaults.standard.string(forKey: modeKey), let mode = PlaceholderMode(rawValue: raw) {
                return mode == .image && !isCustom ? .standard : mode
            }
            return isCustom ? .image : .standard
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: modeKey) }
    }

    static var initialsName: String { UserDefaults.standard.string(forKey: initialsNameKey) ?? "" }
    static var initialsColour: InitialsPlaceholder.Colour {
        InitialsPlaceholder.colour(id: UserDefaults.standard.string(forKey: initialsColourKey) ?? "")
    }

    /// Changes whenever what the placeholder looks like changes, so renderings can be cached.
    static var cacheKey: String {
        switch mode {
        case .standard: return "default"
        case .image: return "image|\(revision)"
        case .initials: return "initials|\(initialsName)|\(initialsColour.id)"
        }
    }

    /// The placeholder content for `dimensions`: nil means the built-in artwork.
    static func content(for dimensions: Dimensions) -> (image: CGImage, source: String)? {
        switch mode {
        case .standard:
            return nil
        case .image:
            return loadImage().map { ($0, "custom image \($0.width)x\($0.height)") }
        case .initials:
            return InitialsPlaceholder.render(name: initialsName, colour: initialsColour, dimensions: dimensions)
                .map { ($0, "initials (\(initialsColour.name))") }
        }
    }
}

/// The user's own placeholder image (UR-26): a PNG, JPEG or HEIC the user picks in Settings.
///
/// The chosen file is copied into the app's container, so it keeps working if the original is
/// moved or deleted, and no security-scoped bookmark is needed. Meeting apps get it aspect-filled
/// over the slate, never mirrored (UR-28). The camera extension's own fallback (used only while
/// the app is not running) keeps the built-in artwork.
enum PlaceholderImageStore {
    static let allowedTypes: [UTType] = [.png, .jpeg, .heic]

    /// File name of the stored copy, or nil for the built-in artwork.
    private static let fileKey = "customPlaceholderFile"
    /// The name the user's file had, for display.
    private static let originalNameKey = "customPlaceholderOriginalName"
    /// Bumped on every change; the feeder re-renders its placeholder when it moves.
    private static let revisionKey = "customPlaceholderRevision"
    /// Large enough for 4K output; bigger photos are downscaled while decoding.
    private static let maxPixelSize = 3840

    private static let log = Logger(subsystem: OffSightConstants.logSubsystem, category: "placeholder")

    enum ImportError: LocalizedError {
        case unreadable

        var errorDescription: String? {
            "This file can't be used as a placeholder. Choose a PNG, JPEG or HEIC image."
        }
    }

    static var isCustom: Bool { storedFileURL != nil }

    static var originalName: String? {
        isCustom ? UserDefaults.standard.string(forKey: originalNameKey) : nil
    }

    static var revision: Int { UserDefaults.standard.integer(forKey: revisionKey) }

    /// Validates the image, copies it into the container and makes it the placeholder.
    static func importImage(from source: URL) throws {
        guard decode(source, maxPixelSize: 64) != nil else { throw ImportError.unreadable }
        let directory = try storageDirectory()
        let ext = source.pathExtension.isEmpty ? "img" : source.pathExtension.lowercased()
        let name = "custom-placeholder-\(UUID().uuidString).\(ext)"
        let destination = directory.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: destination)
        let previous = storedFileURL
        UserDefaults.standard.set(name, forKey: fileKey)
        UserDefaults.standard.set(source.lastPathComponent, forKey: originalNameKey)
        if let previous { try? FileManager.default.removeItem(at: previous) }
        mode = .image
        changed()
        log.notice("Custom placeholder set (\(ext, privacy: .public))")
    }

    /// Removes the stored image; the built-in artwork is used unless initials are chosen.
    static func useDefault() {
        if mode == .image { mode = .standard }
        if let previous = storedFileURL { try? FileManager.default.removeItem(at: previous) }
        UserDefaults.standard.removeObject(forKey: fileKey)
        UserDefaults.standard.removeObject(forKey: originalNameKey)
        changed()
        log.notice("Placeholder reset to the built-in artwork")
    }

    /// The custom image, upright (EXIF orientation applied) and at most 3840 px on its long side.
    /// Nil when none is set or the stored copy can't be read.
    static func loadImage() -> CGImage? {
        guard let url = storedFileURL else { return nil }
        let image = decode(url, maxPixelSize: maxPixelSize)
        if image == nil { log.error("Custom placeholder could not be decoded; using the built-in artwork") }
        return image
    }

    /// A small preview for Settings.
    static func loadThumbnail() -> CGImage? {
        storedFileURL.flatMap { decode($0, maxPixelSize: 320) }
    }

    // MARK: Private

    private static var storedFileURL: URL? {
        guard let name = UserDefaults.standard.string(forKey: fileKey),
              let directory = try? storageDirectory() else { return nil }
        let url = directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func storageDirectory() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let directory = support.appendingPathComponent("Placeholder", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func decode(_ url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func changed() {
        UserDefaults.standard.set(revision &+ 1, forKey: revisionKey)
    }
}
