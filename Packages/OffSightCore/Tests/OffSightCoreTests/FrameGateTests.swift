import XCTest
@testable import OffSightCore

final class FrameGateTests: XCTestCase {
    private let hd = Dimensions(width: 1280, height: 720)

    private func liveTag(_ gate: FrameGate, generation: UInt64? = nil) -> String {
        FrameTag(epoch: gate.epoch, generation: generation ?? gate.generation).encoded
    }

    func testPlaceholderByDefault() {
        var gate = FrameGate(epoch: 42, activeFormat: hd)
        XCTAssertTrue(gate.needsPlaceholderFrame(now: 0))
        XCTAssertEqual(gate.stats.placeholderFramesSent, 1)
    }

    func testValidLiveFrameIsForwardedAndSuppressesPlaceholder() {
        var gate = FrameGate(epoch: 42, activeFormat: hd)
        XCTAssertEqual(gate.evaluateLiveFrame(tag: liveTag(gate), sinkAuthenticated: true, dimensions: hd, now: 10), .forward)
        XCTAssertFalse(gate.needsPlaceholderFrame(now: 10.05))
        XCTAssertTrue(gate.needsPlaceholderFrame(now: 10.2), "stale-frame watchdog")
    }

    func testUnauthenticatedSinkIsRejected() {
        var gate = FrameGate(epoch: 42, activeFormat: hd)
        XCTAssertEqual(gate.evaluateLiveFrame(tag: liveTag(gate), sinkAuthenticated: false, dimensions: hd, now: 0),
                       .reject(.unauthenticatedSink))
    }

    func testMissingOrMalformedTagIsRejected() {
        var gate = FrameGate(epoch: 42, activeFormat: hd)
        XCTAssertEqual(gate.evaluateLiveFrame(tag: nil, sinkAuthenticated: true, dimensions: hd, now: 0), .reject(.missingTag))
        XCTAssertEqual(gate.evaluateLiveFrame(tag: "live|x|1", sinkAuthenticated: true, dimensions: hd, now: 0), .reject(.missingTag))
        XCTAssertEqual(gate.stats.rejectedMissingTag, 2)
    }

    func testWrongEpochIsRejected() {
        var gate = FrameGate(epoch: 42, activeFormat: hd)
        let tag = FrameTag(epoch: 7, generation: gate.generation).encoded
        XCTAssertEqual(gate.evaluateLiveFrame(tag: tag, sinkAuthenticated: true, dimensions: hd, now: 0), .reject(.wrongEpoch))
    }

    func testGenerationFence() {
        var gate = FrameGate(epoch: 42, activeFormat: hd)
        let oldTag = liveTag(gate)
        XCTAssertEqual(gate.evaluateLiveFrame(tag: oldTag, sinkAuthenticated: true, dimensions: hd, now: 1), .forward)
        gate.advanceGeneration() // a new client joined
        XCTAssertTrue(gate.needsPlaceholderFrame(now: 1.01), "client change drops to placeholder immediately")
        XCTAssertEqual(gate.evaluateLiveFrame(tag: oldTag, sinkAuthenticated: true, dimensions: hd, now: 1.02),
                       .reject(.staleGeneration))
        XCTAssertEqual(gate.evaluateLiveFrame(tag: liveTag(gate), sinkAuthenticated: true, dimensions: hd, now: 1.03), .forward)
    }

    func testWrongDimensionsAreRejectedAndFormatChangeAdvancesGeneration() {
        var gate = FrameGate(epoch: 42, activeFormat: hd)
        let fullHD = Dimensions(width: 1920, height: 1080)
        XCTAssertEqual(gate.evaluateLiveFrame(tag: liveTag(gate), sinkAuthenticated: true, dimensions: fullHD, now: 0),
                       .reject(.wrongDimensions))
        let before = gate.generation
        gate.setActiveFormat(fullHD)
        XCTAssertEqual(gate.generation, before + 1)
        XCTAssertEqual(gate.evaluateLiveFrame(tag: liveTag(gate), sinkAuthenticated: true, dimensions: fullHD, now: 0), .forward)
    }

    func testFrameTagRoundTrip() {
        let tag = FrameTag(epoch: UInt64.max, generation: 3)
        XCTAssertEqual(FrameTag(encoded: tag.encoded), tag)
        XCTAssertNil(FrameTag(encoded: "placeholder|1|2"))
        XCTAssertNil(FrameTag(encoded: "live|1"))
    }
}
