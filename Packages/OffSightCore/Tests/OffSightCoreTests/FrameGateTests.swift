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
        XCTAssertEqual(gate.evaluateSinkFrame(tag: liveTag(gate), sinkAuthenticated: true, dimensions: hd, now: 10), .forward(.live))
        XCTAssertFalse(gate.needsPlaceholderFrame(now: 10.05))
        XCTAssertTrue(gate.needsPlaceholderFrame(now: 10.2), "stale-frame watchdog")
    }

    func testUnauthenticatedSinkIsRejected() {
        var gate = FrameGate(epoch: 42, activeFormat: hd)
        XCTAssertEqual(gate.evaluateSinkFrame(tag: liveTag(gate), sinkAuthenticated: false, dimensions: hd, now: 0),
                       .reject(.unauthenticatedSink))
    }

    func testMissingOrMalformedTagIsRejected() {
        var gate = FrameGate(epoch: 42, activeFormat: hd)
        XCTAssertEqual(gate.evaluateSinkFrame(tag: nil, sinkAuthenticated: true, dimensions: hd, now: 0), .reject(.missingTag))
        XCTAssertEqual(gate.evaluateSinkFrame(tag: "live|x|1", sinkAuthenticated: true, dimensions: hd, now: 0), .reject(.missingTag))
        XCTAssertEqual(gate.stats.rejectedMissingTag, 2)
    }

    func testWrongEpochIsRejected() {
        var gate = FrameGate(epoch: 42, activeFormat: hd)
        let tag = FrameTag(epoch: 7, generation: gate.generation).encoded
        XCTAssertEqual(gate.evaluateSinkFrame(tag: tag, sinkAuthenticated: true, dimensions: hd, now: 0), .reject(.wrongEpoch))
    }

    func testGenerationFence() {
        var gate = FrameGate(epoch: 42, activeFormat: hd)
        let oldTag = liveTag(gate)
        XCTAssertEqual(gate.evaluateSinkFrame(tag: oldTag, sinkAuthenticated: true, dimensions: hd, now: 1), .forward(.live))
        gate.advanceGeneration() // a new client joined
        XCTAssertTrue(gate.needsPlaceholderFrame(now: 1.01), "client change drops to placeholder immediately")
        XCTAssertEqual(gate.evaluateSinkFrame(tag: oldTag, sinkAuthenticated: true, dimensions: hd, now: 1.02),
                       .reject(.staleGeneration))
        XCTAssertEqual(gate.evaluateSinkFrame(tag: liveTag(gate), sinkAuthenticated: true, dimensions: hd, now: 1.03), .forward(.live))
    }

    func testWrongDimensionsAreRejectedAndFormatChangeAdvancesGeneration() {
        var gate = FrameGate(epoch: 42, activeFormat: hd)
        let fullHD = Dimensions(width: 1920, height: 1080)
        XCTAssertEqual(gate.evaluateSinkFrame(tag: liveTag(gate), sinkAuthenticated: true, dimensions: fullHD, now: 0),
                       .reject(.wrongDimensions))
        let before = gate.generation
        gate.setActiveFormat(fullHD)
        XCTAssertEqual(gate.generation, before + 1)
        XCTAssertEqual(gate.evaluateSinkFrame(tag: liveTag(gate), sinkAuthenticated: true, dimensions: fullHD, now: 0), .forward(.live))
    }

    func testFrameTagRoundTrip() {
        let tag = FrameTag(epoch: UInt64.max, generation: 3)
        XCTAssertEqual(FrameTag(encoded: tag.encoded), tag)
        XCTAssertNil(FrameTag(encoded: "placeholder|1|2"))
        let ph = FrameTag(kind: .placeholder, epoch: 5, generation: 9)
        XCTAssertEqual(ph.encoded, "ph|5|9")
        XCTAssertEqual(FrameTag(encoded: "ph|5|9"), ph)
        XCTAssertNil(FrameTag(encoded: "live|1"))
    }

    func testAppPlaceholderIgnoresGenerationButNotEpochOrSize() {
        var gate = FrameGate(epoch: 42, activeFormat: hd)
        let ph = FrameTag(kind: .placeholder, epoch: 42, generation: 1).encoded
        gate.advanceGeneration()
        gate.advanceGeneration()
        XCTAssertEqual(gate.evaluateSinkFrame(tag: ph, sinkAuthenticated: true, dimensions: hd, now: 5), .forward(.placeholder))
        XCTAssertFalse(gate.needsPlaceholderFrame(now: 5.05), "the app's placeholder suppresses the extension's own")
        XCTAssertEqual(gate.stats.appPlaceholderFramesForwarded, 1)
        XCTAssertEqual(gate.evaluateSinkFrame(tag: FrameTag(kind: .placeholder, epoch: 7, generation: 1).encoded,
                                              sinkAuthenticated: true, dimensions: hd, now: 5), .reject(.wrongEpoch))
        XCTAssertEqual(gate.evaluateSinkFrame(tag: ph, sinkAuthenticated: false, dimensions: hd, now: 5),
                       .reject(.unauthenticatedSink))
        XCTAssertEqual(gate.evaluateSinkFrame(tag: ph, sinkAuthenticated: true, dimensions: Dimensions(width: 640, height: 480), now: 5),
                       .reject(.wrongDimensions))
    }

    func testStatsDecodeFromOlderExtensionJSON() throws {
        let old = #"{"liveFramesForwarded":3,"placeholderFramesSent":4,"rejectedUnauthenticated":0,"rejectedMissingTag":0,"rejectedWrongEpoch":0,"rejectedStaleGeneration":0,"rejectedWrongDimensions":0}"#
        let stats = try JSONDecoder().decode(GateStats.self, from: Data(old.utf8))
        XCTAssertEqual(stats.liveFramesForwarded, 3)
        XCTAssertEqual(stats.appPlaceholderFramesForwarded, 0)
    }

    func testFormatRequestIsAuthenticatedButNeverForwarded() {
        var gate = FrameGate(epoch: 42, activeFormat: hd)
        let uhd = Dimensions(width: 3840, height: 2160)
        let fmt = FrameTag(kind: .formatRequest, epoch: 42, generation: 0).encoded
        XCTAssertEqual(gate.evaluateSinkFrame(tag: fmt, sinkAuthenticated: true, dimensions: uhd, now: 1), .formatRequest(uhd))
        XCTAssertTrue(gate.needsPlaceholderFrame(now: 1.01), "a format request is not a frame for meeting apps")
        XCTAssertEqual(gate.evaluateSinkFrame(tag: fmt, sinkAuthenticated: false, dimensions: uhd, now: 1),
                       .reject(.unauthenticatedSink))
        XCTAssertEqual(gate.evaluateSinkFrame(tag: FrameTag(kind: .formatRequest, epoch: 1, generation: 0).encoded,
                                              sinkAuthenticated: true, dimensions: uhd, now: 1), .reject(.wrongEpoch))
    }

    func testAcceptableFormats() {
        XCTAssertTrue(OffSightConstants.isAcceptableFormat(Dimensions(width: 1920, height: 1080)))
        XCTAssertTrue(OffSightConstants.isAcceptableFormat(Dimensions(width: 1280, height: 960)))
        XCTAssertFalse(OffSightConstants.isAcceptableFormat(Dimensions(width: 1, height: 1)))
        XCTAssertFalse(OffSightConstants.isAcceptableFormat(Dimensions(width: 7680, height: 4320)))
        XCTAssertFalse(OffSightConstants.isAcceptableFormat(Dimensions(width: 1921, height: 1080)))
    }

    func testEffectsFreeFormat() {
        func free(_ width: Int, _ height: Int) -> Dimensions {
            OffSightConstants.effectsFreeFormat(for: Dimensions(width: width, height: height))
        }
        XCTAssertEqual(free(1920, 1080), Dimensions(width: 2560, height: 1440))
        XCTAssertEqual(free(1280, 720), Dimensions(width: 2560, height: 1440))
        XCTAssertEqual(free(1440, 1080), Dimensions(width: 1920, height: 1440))
        XCTAssertEqual(free(640, 480), Dimensions(width: 1920, height: 1440))
        XCTAssertEqual(free(1920, 1200), Dimensions(width: 2304, height: 1440))
        XCTAssertEqual(free(3840, 2160), Dimensions(width: 3840, height: 2160), "already large enough")
        XCTAssertEqual(free(2560, 1440), Dimensions(width: 2560, height: 1440))
        XCTAssertEqual(free(3840, 1080), Dimensions(width: 3840, height: 1080), "too wide to scale: unchanged")
        XCTAssertEqual(free(1, 1), OffSightConstants.defaultFormat)
        for native in [Dimensions(width: 1920, height: 1080), Dimensions(width: 1280, height: 960),
                       Dimensions(width: 1552, height: 1552), Dimensions(width: 1366, height: 768)] {
            let format = OffSightConstants.effectsFreeFormat(for: native)
            XCTAssertTrue(OffSightConstants.isAcceptableFormat(format), "\(native) -> \(format)")
            XCTAssertGreaterThanOrEqual(format.width, 1920)
            XCTAssertGreaterThanOrEqual(format.height, 1440)
            XCTAssertEqual(Double(format.width) / Double(format.height),
                           Double(native.width) / Double(native.height), accuracy: 0.01, "keeps its shape")
        }
        XCTAssertTrue(OffSightConstants.isAcceptableFormat(OffSightConstants.defaultFormat))
    }
}
