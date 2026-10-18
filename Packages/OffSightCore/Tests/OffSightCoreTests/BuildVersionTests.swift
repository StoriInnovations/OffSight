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

    private func installed(_ build: String, enabled: Bool = true, awaiting: Bool = false,
                           uninstalling: Bool = false) -> InstalledExtension {
        InstalledExtension(version: BuildVersion(short: "0.1.0", build: build), enabled: enabled,
                           awaitingApproval: awaiting, uninstalling: uninstalling)
    }

    func testNotRunningExplainsWhatMacOSHas() {
        func status(_ list: [InstalledExtension]?, error: String? = nil) -> ExtensionVersionStatus {
            .evaluate(connected: false, running: nil, bundled: bundled, installed: list, installError: error)
        }
        XCTAssertEqual(status(nil), .notRunning)
        XCTAssertEqual(status(nil, error: "denied"), .notInstalled(installedBuilds: [], error: "denied"))
        XCTAssertEqual(status([installed("1760000000")]), .installedNotStarted)
        XCTAssertEqual(status([installed("1750000000", uninstalling: true), installed("1760000000")]), .installedNotStarted)
        XCTAssertEqual(status([installed("1760000000", enabled: false, awaiting: true)]), .awaitingApproval)
        XCTAssertEqual(status([installed("1750000000")]), .notInstalled(installedBuilds: ["1750000000"], error: nil))
        XCTAssertEqual(status([installed("1760000000", uninstalling: true)]), .notInstalled(installedBuilds: [], error: nil))
        XCTAssertEqual(status([]), .notInstalled(installedBuilds: [], error: nil))

        XCTAssertTrue(ExtensionVersionStatus.installedNotStarted.summary(bundled: bundled).hasPrefix("Build 1760000000 is installed"))
        let pending = ExtensionVersionStatus.notInstalled(installedBuilds: ["1750000000"], error: nil).summary(bundled: bundled)
        XCTAssertTrue(pending.contains("macOS has build 1750000000") && pending.contains("asking macOS to install"))
        XCTAssertTrue(ExtensionVersionStatus.notInstalled(installedBuilds: [], error: "denied").summary(bundled: bundled).hasSuffix("failed: denied"))
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
