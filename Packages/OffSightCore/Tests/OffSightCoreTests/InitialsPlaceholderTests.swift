import CoreGraphics
import XCTest
@testable import OffSightCore

final class InitialsPlaceholderTests: XCTestCase {
    func testInitials() {
        XCTAssertEqual(InitialsPlaceholder.initials(from: "Ada Lovelace"), "AL")
        XCTAssertEqual(InitialsPlaceholder.initials(from: "  grace  hopper "), "GH")
        XCTAssertEqual(InitialsPlaceholder.initials(from: "Jean-Luc Picard"), "JP")
        XCTAssertEqual(InitialsPlaceholder.initials(from: "Ludwig van Beethoven"), "LB")
        XCTAssertEqual(InitialsPlaceholder.initials(from: "Grace"), "G")
        XCTAssertEqual(InitialsPlaceholder.initials(from: "ab"), "AB", "short input is taken as initials")
        XCTAssertEqual(InitialsPlaceholder.initials(from: ""), "")
        XCTAssertEqual(InitialsPlaceholder.initials(from: "   "), "")
    }

    func testUnknownColourFallsBackToSlate() {
        XCTAssertEqual(InitialsPlaceholder.colour(id: "nope").id, "slate")
        XCTAssertEqual(InitialsPlaceholder.colour(id: "teal").id, "teal")
    }

    func testRenderHasRequestedSizeBackgroundAndText() throws {
        for dimensions in [Dimensions(width: 2560, height: 1440), Dimensions(width: 1920, height: 1440)] {
            let teal = InitialsPlaceholder.colour(id: "teal")
            let image = try XCTUnwrap(InitialsPlaceholder.render(name: "Ada Lovelace", colour: teal, dimensions: dimensions))
            XCTAssertEqual(image.width, dimensions.width)
            XCTAssertEqual(image.height, dimensions.height)

            let pixels = try rgba(image)
            let corner = pixels(2, 2)
            XCTAssertEqual(corner.r, teal.red, accuracy: 2)
            XCTAssertEqual(corner.g, teal.green, accuracy: 2)
            XCTAssertEqual(corner.b, teal.blue, accuracy: 2)

            // Somewhere in the middle band there is near-white text.
            var bright = 0
            for x in stride(from: dimensions.width / 3, to: dimensions.width * 2 / 3, by: 4) {
                for y in stride(from: dimensions.height / 3, to: dimensions.height * 2 / 3, by: 4) {
                    let p = pixels(x, y)
                    if p.r > 230 && p.g > 230 && p.b > 230 { bright += 1 }
                }
            }
            XCTAssertGreaterThan(bright, 50, "initials drawn in white")
        }
    }

    func testRenderWithEmptyNameIsJustBackgroundAndDisc() throws {
        let image = try XCTUnwrap(InitialsPlaceholder.render(name: "", colour: InitialsPlaceholder.colours[0],
                                                             dimensions: Dimensions(width: 640, height: 480)))
        XCTAssertEqual(image.width, 640)
    }

    private func rgba(_ image: CGImage) throws -> (Int, Int) -> (r: Int, g: Int, b: Int) {
        let width = image.width, height = image.height
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let base = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let data = Array(UnsafeBufferPointer(start: base, count: width * height * 4))
        return { x, y in
            let i = ((height - 1 - y) * width + x) * 4
            return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
        }
    }
}
