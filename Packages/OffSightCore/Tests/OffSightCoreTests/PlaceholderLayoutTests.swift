import CoreGraphics
import XCTest
@testable import OffSightCore

final class PlaceholderLayoutTests: XCTestCase {
    private let wide = CGSize(width: 1920, height: 1080)
    private let standard = CGSize(width: 1440, height: 1080)

    func testArtworkChoice() {
        XCTAssertEqual(PlaceholderLayout.artwork(for: Dimensions(width: 1920, height: 1080)), .wide16x9)
        XCTAssertEqual(PlaceholderLayout.artwork(for: Dimensions(width: 1280, height: 720)), .wide16x9)
        XCTAssertEqual(PlaceholderLayout.artwork(for: Dimensions(width: 640, height: 480)), .standard4x3)
        XCTAssertEqual(PlaceholderLayout.artwork(for: Dimensions(width: 1440, height: 1080)), .standard4x3)
        XCTAssertEqual(PlaceholderLayout.artwork(for: Dimensions(width: 1000, height: 1000)), .wide16x9)
        XCTAssertEqual(PlaceholderLayout.Artwork.wide16x9.assetName, "PlaceholderCameraOff")
        XCTAssertEqual(PlaceholderLayout.Artwork.standard4x3.assetName, "PlaceholderCameraOff4x3")
        XCTAssertEqual(PlaceholderLayout.Artwork.wide16x9.resourceName, "placeholder-camera-off-16x9")
        XCTAssertEqual(PlaceholderLayout.Artwork.standard4x3.resourceName, "placeholder-camera-off-4x3")
    }

    func testExactAspectScalesToFill() {
        XCTAssertEqual(PlaceholderLayout.aspectFillRect(source: wide, target: Dimensions(width: 1920, height: 1080)),
                       CGRect(x: 0, y: 0, width: 1920, height: 1080))
        XCTAssertEqual(PlaceholderLayout.aspectFillRect(source: wide, target: Dimensions(width: 1280, height: 720)),
                       CGRect(x: 0, y: 0, width: 1280, height: 720))
        XCTAssertEqual(PlaceholderLayout.aspectFillRect(source: standard, target: Dimensions(width: 640, height: 480)),
                       CGRect(x: 0, y: 0, width: 640, height: 480))
    }

    func testOtherAspectsAreCentredAndCroppedNeverStretched() {
        // Square output from the 16:9 frame: height fills, width overflows equally on both sides.
        let square = PlaceholderLayout.aspectFillRect(source: wide, target: Dimensions(width: 1080, height: 1080))
        XCTAssertEqual(square.height, 1080, accuracy: 0.001)
        XCTAssertEqual(square.width, 1920, accuracy: 0.001)
        XCTAssertEqual(square.midX, 540, accuracy: 0.001)
        XCTAssertEqual(square.width / square.height, wide.width / wide.height, accuracy: 0.0001)

        // Ultra-wide output: width fills, height overflows.
        let ultraWide = PlaceholderLayout.aspectFillRect(source: wide, target: Dimensions(width: 2560, height: 1080))
        XCTAssertEqual(ultraWide.width, 2560, accuracy: 0.001)
        XCTAssertGreaterThan(ultraWide.height, 1080)
        XCTAssertEqual(ultraWide.midY, 540, accuracy: 0.001)
        XCTAssertEqual(ultraWide.width / ultraWide.height, wide.width / wide.height, accuracy: 0.0001)
    }
}

final class PlaceholderRenderingTests: XCTestCase {
    private func image(width: Int, height: Int, white: Bool) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(white ? CGColor(red: 1, green: 1, blue: 1, alpha: 1) : CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    func testRendersEveryFormatWithContent() {
        for format in [Dimensions(width: 1920, height: 1080), Dimensions(width: 1280, height: 720),
                       Dimensions(width: 640, height: 480), Dimensions(width: 3840, height: 2160)] {
            let buffer = PlaceholderRendering.render(image(width: 192, height: 108, white: true), dimensions: format)
            XCTAssertNotNil(buffer, "\(format)")
            XCTAssertEqual(buffer.map(CVPixelBufferGetWidth), format.width)
            XCTAssertEqual(buffer.map(CVPixelBufferGetHeight), format.height)
            XCTAssertEqual(buffer.map(PlaceholderRendering.brightSamples), 4096, "\(format) should be fully covered")
        }
    }

    func testNilImageGivesPlainSlate() {
        let buffer = PlaceholderRendering.render(nil, dimensions: Dimensions(width: 1280, height: 720))
        XCTAssertEqual(buffer.map(PlaceholderRendering.brightSamples), 0)
    }

    func testCopyPixels() {
        let format = Dimensions(width: 640, height: 480)
        let source = PlaceholderRendering.render(image(width: 64, height: 48, white: true), dimensions: format)!
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, PlaceholderRendering.bufferAttributes(format) as CFDictionary, &pool)
        var destination: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool!, &destination)
        XCTAssertTrue(PlaceholderRendering.copyPixels(from: source, to: destination!))
        XCTAssertEqual(PlaceholderRendering.brightSamples(destination!), 4096)
    }
}
