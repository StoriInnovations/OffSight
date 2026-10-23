import XCTest
@testable import OffSightCore

final class SetupCheckTests: XCTestCase {
    private func build(_ number: String, enabled: Bool = true, awaiting: Bool = false,
                       uninstalling: Bool = false) -> InstalledExtension {
        InstalledExtension(version: BuildVersion(short: "0.1.0", build: number), enabled: enabled,
                           awaitingApproval: awaiting, uninstalling: uninstalling)
    }

    private func facts(_ status: ExtensionVersionStatus, _ change: (inout SetupFacts) -> Void = { _ in }) -> SetupFacts {
        var facts = SetupFacts(extensionStatus: status)
        facts.installed = [build("2")]
        facts.offSightCameras = 1
        change(&facts)
        return facts
    }

    private func kinds(_ facts: SetupFacts) -> [String] {
        SetupCheck.issues(for: facts).map { "\($0.kind.rawValue)\($0.required ? "" : "?")" }
    }

    func testWorkingSetupHasNoIssues() {
        XCTAssertEqual(kinds(facts(.current)), [])
    }

    func testStillCheckingOrInstallingIsNotAnIssue() {
        XCTAssertEqual(kinds(facts(.notRunning) { $0.installed = nil }), [])
        XCTAssertEqual(kinds(facts(.notInstalled(installedBuilds: [], error: nil)) { $0.installing = true; $0.installed = [] }), [])
    }

    func testExtensionSteps() {
        XCTAssertEqual(kinds(facts(.awaitingApproval)), ["allowExtension"])
        XCTAssertEqual(kinds(facts(.notRunning) { $0.awaitingApproval = true }), ["allowExtension"])
        XCTAssertEqual(kinds(facts(.disabled)), ["allowExtension"])
        XCTAssertEqual(SetupCheck.issues(for: facts(.disabled)).first?.actions, [.openExtensionSettings, .installAgain])
        XCTAssertEqual(kinds(facts(.notInstalled(installedBuilds: [], error: nil)) { $0.installed = [] }), ["installExtension"])
        let failed = SetupCheck.issues(for: facts(.notInstalled(installedBuilds: [], error: "denied")))
        XCTAssertEqual(failed.map(\.kind), [.installExtension])
        XCTAssertTrue(failed[0].detail.hasSuffix("denied"))
        XCTAssertEqual(failed[0].actions, [.installAgain])
    }

    func testOutsideApplicationsComesFirst() {
        let issues = SetupCheck.issues(for: facts(.notInstalled(installedBuilds: [], error: "unsupported location")) {
            $0.installFailedOutsideApplications = true
            $0.appPath = "/Users/me/Downloads/OffSight.app"
        })
        XCTAssertEqual(issues.map(\.kind), [.moveToApplications])
        XCTAssertEqual(issues[0].actions, [.showInFinder(path: "/Users/me/Downloads/OffSight.app")])
    }

    func testLiveVideoNeedsTheInstalledPath() {
        XCTAssertEqual(kinds(facts(.current) { $0.appPath = OffSightConstants.installedAppPath }), [])
        let elsewhere = SetupCheck.issues(for: facts(.current) { $0.appPath = "/Applications/OffSight 2.app" })
        XCTAssertEqual(elsewhere.map(\.kind), [.moveToApplications])
        XCTAssertEqual(elsewhere[0].required, true)
        XCTAssertTrue(elsewhere[0].detail.contains("/Applications/OffSight 2.app"))
        XCTAssertEqual(elsewhere[0].actions, [.showInFinder(path: "/Applications/OffSight 2.app")])
    }

    func testRefusedLiveVideo() {
        let refused = SetupCheck.issues(for: facts(.current) {
            $0.appPath = OffSightConstants.installedAppPath
            $0.sinkRefused = "codesign-unavailable(client=/x)"
        })
        XCTAssertEqual(refused.map(\.kind), [.liveVideoRefused])
        XCTAssertTrue(refused[0].detail.contains("client=/x"))
        // Only reported once the extension runs this app's build; before that, other steps come first.
        XCTAssertEqual(kinds(facts(.installedNotStarted) { $0.sinkRefused = "x" }), ["restart"])
    }

    func testRestartCases() {
        XCTAssertEqual(kinds(facts(.installedNotStarted)), ["restart"])
        XCTAssertEqual(kinds(facts(.different(running: BuildVersion(short: "0.1.0", build: "1")))), ["restart"])
        XCTAssertEqual(kinds(facts(.notInstalled(installedBuilds: ["1"], error: nil)) { $0.installCompletesAfterRestart = true }), ["restart"])
        XCTAssertEqual(kinds(facts(.notRunning) { $0.installCompletesAfterRestart = true }), ["restart"])
        XCTAssertTrue(SetupCheck.issues(for: facts(.installedNotStarted)).first!.detail.hasSuffix(SetupCheck.restartHow))
    }

    func testSeveralInstalledBuildsNeedARestart() {
        let replaced = facts(.installedNotStarted) { $0.installed = [self.build("1", uninstalling: true), self.build("2")] }
        let issue = SetupCheck.issues(for: replaced).first
        XCTAssertEqual(issue?.kind, .restart)
        XCTAssertEqual(issue?.required, true)
        XCTAssertTrue(issue?.detail.contains("2 builds of OffSight Camera") == true)

        // Working, with the old build only waiting to be removed: suggest, don't insist.
        XCTAssertEqual(kinds(facts(.current) { $0.installed = [self.build("1", uninstalling: true), self.build("2")] }), ["restart?"])
    }

    func testTwoOffSightCamerasNeedARestartEvenWhenWorking() {
        let issue = SetupCheck.issues(for: facts(.current) { $0.offSightCameras = 2 }).first
        XCTAssertEqual(issue?.kind, .restart)
        XCTAssertEqual(issue?.required, true)
        XCTAssertTrue(issue?.detail.contains("2 cameras named OffSight Camera") == true)
    }

    func testCameraAccess() {
        XCTAssertEqual(kinds(facts(.current) { $0.cameraAccess = .notAsked }), ["cameraAccess"])
        XCTAssertEqual(SetupCheck.issues(for: facts(.current) { $0.cameraAccess = .notAsked }).first?.actions, [.requestCameraAccess])
        XCTAssertEqual(SetupCheck.issues(for: facts(.current) { $0.cameraAccess = .denied }).first?.actions, [.openCameraPrivacy])
        let both = SetupCheck.issues(for: facts(.awaitingApproval) { $0.cameraAccess = .denied })
        XCTAssertEqual(both.map(\.kind), [.allowExtension, .cameraAccess])
        XCTAssertEqual(both.map(\.concernsCameraExtension), [true, false])
    }

    func testOtherCopiesAreOnlyRecommended() {
        let issues = SetupCheck.issues(for: facts(.current) { $0.otherCopies = ["/Users/me/Downloads/OffSight.app"] })
        XCTAssertEqual(issues.map(\.kind), [.otherCopies])
        XCTAssertEqual(issues[0].required, false)
        XCTAssertEqual(issues[0].actions, [.showInFinder(path: "/Users/me/Downloads/OffSight.app")])
        XCTAssertTrue(issues[0].actions[0].label.hasPrefix("Show "))
    }
}
