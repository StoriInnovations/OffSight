import XCTest
@testable import OffSightCore

final class ClientTrackerTests: XCTestCase {
    func testStartAndStopMarksClientsStopped() {
        var tracker = ClientTracker()
        let a = UUID()
        tracker.clientStarting(clientID: a, pid: 100, signingID: "us.zoom.xos", now: 0)
        tracker.streamStarted()
        XCTAssertEqual(tracker.records[a]?.streaming, true)
        XCTAssertNil(tracker.records[a]?.restartGap)
        tracker.streamStopped(now: 5)
        XCTAssertEqual(tracker.records[a]?.streaming, false)
    }

    func testRestartGapMeasuredFromLastStop() {
        var tracker = ClientTracker()
        let a = UUID()
        tracker.clientStarting(clientID: a, pid: 100, signingID: nil, now: 0)
        tracker.streamStarted()
        tracker.streamStopped(now: 10)
        tracker.clientStarting(clientID: a, pid: 100, signingID: nil, now: 12)
        tracker.streamStarted()
        XCTAssertEqual(tracker.records[a]?.restartGap ?? -1, 2, accuracy: 0.0001)
        XCTAssertEqual(tracker.records[a]?.startSequence, 2)
    }

    func testRestartWithoutObservedStopUsesTimeSincePreviousStart() {
        var tracker = ClientTracker()
        let a = UUID()
        tracker.clientStarting(clientID: a, pid: 100, signingID: nil, now: 0)
        tracker.clientStarting(clientID: a, pid: 100, signingID: nil, now: 3600)
        XCTAssertEqual(tracker.records[a]?.restartGap ?? -1, 3600, accuracy: 0.0001)
    }

    func testStopsOnlyClearWhenCountReachesZero() {
        var tracker = ClientTracker()
        let a = UUID(), b = UUID()
        tracker.clientStarting(clientID: a, pid: 1, signingID: nil, now: 0)
        tracker.streamStarted()
        tracker.clientStarting(clientID: b, pid: 2, signingID: nil, now: 1)
        tracker.streamStarted()
        tracker.streamStopped(now: 2)
        XCTAssertEqual(tracker.records[a]?.streaming, true)
        XCTAssertEqual(tracker.records[b]?.streaming, true)
        tracker.streamStopped(now: 3)
        XCTAssertEqual(tracker.records[a]?.streaming, false)
        XCTAssertEqual(tracker.records[b]?.streaming, false)
    }

    func testDisconnectAndProcessExitRemoveClients() {
        var tracker = ClientTracker()
        let a = UUID(), b = UUID(), c = UUID()
        tracker.clientStarting(clientID: a, pid: 1, signingID: nil, now: 0)
        tracker.clientStarting(clientID: b, pid: 2, signingID: nil, now: 0)
        tracker.clientStarting(clientID: c, pid: 2, signingID: nil, now: 0)
        tracker.clientDisconnected(clientID: a)
        XCTAssertNil(tracker.records[a])
        tracker.processExited(pid: 2)
        XCTAssertTrue(tracker.records.isEmpty)
    }
}

final class ProtocolTests: XCTestCase {
    func testSnapshotJSONRoundTrip() {
        var stats = GateStats()
        stats.liveFramesForwarded = 9
        let snapshot = ClientSnapshot(
            epoch: 123, generation: 4, activeFormat: Dimensions(width: 1280, height: 720),
            clients: [ClientRecord(clientID: UUID(), pid: 42, signingID: "us.zoom.xos", streaming: true,
                                   startSequence: 1, restartGap: nil)],
            stats: stats, sinkConnected: true, sinkAuthMode: "codesign")
        let decoded = ClientSnapshot.decode(json: snapshot.encodedJSON())
        XCTAssertEqual(decoded, snapshot)
    }

    func testRoutingIgnoresStats() {
        let base = ClientSnapshot(epoch: 1, generation: 1, activeFormat: Dimensions(width: 1, height: 1), clients: [])
        var other = base
        other.stats.placeholderFramesSent = 100
        XCTAssertTrue(base.hasSameRouting(as: other))
        other.generation = 2
        XCTAssertFalse(base.hasSameRouting(as: other))
    }

    func testFourCharCode() {
        XCTAssertEqual(fourCharCode("osnp"), 0x6F73_6E70)
        XCTAssertEqual(OffSightConstants.snapshotPropertyName, "4cc_osnp_glob_0000")
    }
}

final class KnownClientsTests: XCTestCase {
    func testHelpersMapToHostApp() {
        XCTAssertEqual(KnownClients.match(signingID: "com.google.Chrome.helper")?.hostBundleID, "com.google.Chrome")
        XCTAssertEqual(KnownClients.match(signingID: "com.google.Chrome")?.isBrowser, true)
        XCTAssertEqual(KnownClients.match(signingID: "us.zoom.xos")?.displayName, "Zoom")
        XCTAssertEqual(KnownClients.match(signingID: "com.microsoft.teams2")?.hostBundleID, "com.microsoft.teams2")
        XCTAssertEqual(KnownClients.match(signingID: "com.microsoft.teams2.helper")?.hostBundleID, "com.microsoft.teams2")
        XCTAssertEqual(KnownClients.match(signingID: "com.microsoft.teams")?.hostBundleID, "com.microsoft.teams")
        XCTAssertEqual(KnownClients.match(signingID: "com.apple.WebKit.GPU")?.hostBundleID, "com.apple.Safari")
        XCTAssertEqual(KnownClients.match(signingID: "Cisco-Systems.Spark")?.displayName, "Webex")
    }

    func testPrefixMustEndAtComponentBoundary() {
        XCTAssertNil(KnownClients.match(signingID: "com.google.Chromeish"))
        XCTAssertNil(KnownClients.match(signingID: "com.example.unknown"))
    }
}
