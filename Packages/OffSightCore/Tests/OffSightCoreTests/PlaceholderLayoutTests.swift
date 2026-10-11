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
