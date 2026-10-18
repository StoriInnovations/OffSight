import XCTest
@testable import OffSightCore

final class MeetingAppGuideTests: XCTestCase {
    func testEveryRequiredMeetingAppHasAGuide() {
        // UR-32 and UR-33: Zoom, Teams, Meet (Chrome, Safari, Edge, Arc, Firefox), Webex, Slack, FaceTime.
        let ids = Set(MeetingAppGuide.all.map(\.bundleID))
        for required in ["us.zoom.xos", "com.microsoft.teams2", "Cisco-Systems.Spark", "com.tinyspeck.slackmacgap",
                         "com.apple.FaceTime", "com.google.Chrome", "com.apple.Safari", "com.microsoft.edgemac",
                         "company.thebrowser.Browser", "org.mozilla.firefox"] {
            XCTAssertTrue(ids.contains(required), "missing guide for \(required)")
        }
    }

    func testGuidesMatchKnownClientNames() {
        for guide in MeetingAppGuide.all where guide.bundleID != "com.apple.PhotoBooth" {
            XCTAssertNotNil(KnownClients.displayName(forHostBundleID: guide.bundleID), "\(guide.bundleID) not a known client")
            XCTAssertEqual(KnownClients.match(signingID: guide.bundleID)?.isBrowser, guide.isBrowser, guide.bundleID)
        }
    }

    func testInstalledFiltersAndKeepsOrder() {
        let installed = MeetingAppGuide.installed { ["com.apple.FaceTime", "us.zoom.xos"].contains($0) }
        XCTAssertEqual(installed.map(\.name), ["Zoom", "FaceTime"])
    }

    func testEveryGuideSaysWhereToChoose() {
        for guide in MeetingAppGuide.all {
            XCTAssertFalse(guide.whereToChoose.isEmpty, guide.name)
        }
    }
}
