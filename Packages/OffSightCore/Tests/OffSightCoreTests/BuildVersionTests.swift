import XCTest
@testable import OffSightCore

final class BuildVersionTests: XCTestCase {
    private let bundled = BuildVersion(short: "0.1.0", build: "1760000000")

    func testReadsInfoDictionary() {
        let version = BuildVersion(infoDictionary: ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "42"])
        XCTAssertEqual(version, BuildVersion(short: "0.1.0", build: "42"))
        XCTAssertEqual(version?.display, "0.1.0 (42)")
        XCTAssertNil(BuildVersion(infoDictionary: ["CFBundleVersion": "42"]))
        XCTAssertNil(BuildVersion(infoDictionary: nil))
    }

    func testBuildDateOnlyForUnixTimes() {
        XCTAssertEqual(bundled.buildDate, Date(timeIntervalSince1970: 1_760_000_000))
        XCTAssertNil(BuildVersion(short: "1.0", build: "1").buildDate)
        XCTAssertNil(BuildVersion(short: "1.0", build: "1.2.3").buildDate)
    }

    func testStatus() {
        XCTAssertEqual(ExtensionVersionStatus.evaluate(connected: false, running: bundled, bundled: bundled), .notRunning)
        XCTAssertEqual(ExtensionVersionStatus.evaluate(connected: true, running: bundled, bundled: bundled), .current)
        let old = BuildVersion(short: "0.1.0", build: "1750000000")
        XCTAssertEqual(ExtensionVersionStatus.evaluate(connected: true, running: old, bundled: bundled), .different(running: old))
        XCTAssertEqual(ExtensionVersionStatus.evaluate(connected: true, running: nil, bundled: bundled), .different(running: nil))
        XCTAssertEqual(ExtensionVersionStatus.evaluate(connected: true, running: old, bundled: nil), .current)
    }

    func testSummaryNamesBothBuildsWhenTheyDiffer() {
        let old = BuildVersion(short: "0.1.0", build: "1750000000")
        let text = ExtensionVersionStatus.different(running: old).summary(bundled: bundled)
        XCTAssertTrue(text.contains("1750000000") && text.contains("1760000000") && text.contains("Restart"))
        XCTAssertEqual(ExtensionVersionStatus.current.summary(bundled: bundled), "0.1.0 (1760000000), up to date")
        XCTAssertTrue(ExtensionVersionStatus.different(running: nil).summary(bundled: bundled).contains("an older build"))
    }

    func testSnapshotCarriesVersionAndOlderSnapshotsStillDecode() throws {
        var snapshot = ClientSnapshot(epoch: 1, generation: 1, activeFormat: Dimensions(width: 2, height: 2), clients: [])
        snapshot.extensionVersion = bundled
        let decoded = try JSONDecoder().decode(ClientSnapshot.self, from: Data(snapshot.encodedJSON().utf8))
        XCTAssertEqual(decoded.extensionVersion, bundled)

        var older = snapshot
        older.extensionVersion = nil
        let json = older.encodedJSON()
        XCTAssertFalse(json.contains("extensionVersion"))
        XCTAssertNil(try JSONDecoder().decode(ClientSnapshot.self, from: Data(json.utf8)).extensionVersion)
    }
}
