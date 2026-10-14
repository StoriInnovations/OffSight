import AppKit
import Foundation
import OffSightCore

/// Guided checks for apps that can't be driven automatically (Zoom, Teams, Meet, Webex, Slack,
/// FaceTime, other browsers). The tool watches OffSight's state and asks the tester only what it
/// can't see itself: what the meeting app shows.
enum Manual {
    struct Target {
        let name: String
        let bundleID: String
        let howTo: String
    }

    static let targets: [Target] = [
        Target(name: "Zoom", bundleID: "us.zoom.xos", howTo: "Open Zoom › Settings › Video (or start a test meeting) with camera OffSight Camera."),
        Target(name: "Microsoft Teams", bundleID: "com.microsoft.teams2", howTo: "Open Teams › Settings › Devices with camera OffSight Camera, or start Meet now."),
        Target(name: "Google Meet in Chrome", bundleID: "com.google.Chrome", howTo: "In Chrome open https://meet.google.com, start a meeting, camera OffSight Camera."),
        Target(name: "Google Meet in Safari", bundleID: "com.apple.Safari", howTo: "In Safari open https://meet.google.com, start a meeting, camera OffSight Camera."),
        Target(name: "Google Meet in Edge", bundleID: "com.microsoft.edgemac", howTo: "In Edge open https://meet.google.com, start a meeting, camera OffSight Camera."),
        Target(name: "Google Meet in Arc", bundleID: "company.thebrowser.Browser", howTo: "In Arc open https://meet.google.com, start a meeting, camera OffSight Camera."),
        Target(name: "Google Meet in Firefox", bundleID: "org.mozilla.firefox", howTo: "In Firefox open https://meet.google.com, start a meeting, camera OffSight Camera."),
        Target(name: "Webex", bundleID: "Cisco-Systems.Spark", howTo: "Open Webex › Settings › Video with camera OffSight Camera, or start a meeting."),
        Target(name: "Slack huddle", bundleID: "com.tinyspeck.slackmacgap", howTo: "Start a huddle in Slack and turn on video with camera OffSight Camera."),
        Target(name: "FaceTime", bundleID: "com.apple.FaceTime", howTo: "Open FaceTime and choose Video › OffSight Camera."),
    ]

    static func run(only names: [String], context: TestContext, report: Report) {
        let chosen = names.isEmpty ? targets : targets.filter { target in
            names.contains { target.name.localizedCaseInsensitiveContains($0) || target.bundleID == $0 }
        }
        for target in chosen {
            let start = Date()
            let outcome = check(target, context: context)
            report.add(.init(id: "manual-\(target.bundleID)", title: target.name, requirements: "UR-32, UR-33",
                             outcome: outcome, seconds: Date().timeIntervalSince(start)))
        }
    }

    private static func check(_ target: Target, context: TestContext) -> Outcome {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.bundleID) != nil else {
            return .skip("Not installed")
        }
        print("\n── \(target.name) ──")
        guard ask("Test \(target.name) now? [y = yes, s = skip]", allowed: ["y", "s"]) == "y" else { return .skip("Skipped by tester") }
        guard context.waitForIdle() else { return .skip("Another app is using OffSight Camera; close it first") }
        print(target.howTo)
        print("Waiting up to 90 s for \(target.name) to use OffSight Camera…")
        guard let state = context.app.waitFor(90, { $0.sessions.contains { $0.app == target.bundleID } }) else {
            return .fail("\(target.name) did not start a session with OffSight Camera within 90 s")
        }
        var notes: [(String, String)] = []
        let prompted = context.app.waitFor(3, { $0.prompts.contains { $0.app == target.bundleID } }) != nil
        notes.append(("prompt", prompted ? "shown" : "missing"))
        if let name = state.sessions.first(where: { $0.app == target.bundleID })?.name { notes.append(("named as", name)) }
        guard prompted else { return .fail("No prompt for \(target.name)", notes) }

        guard ask("Does \(target.name) show the OffSight placeholder (not your face)? [y/n]") == "y" else {
            return .fail("Placeholder not shown", notes)
        }
        print("Click “Go live for this session” in the OffSight prompt.")
        guard context.app.waitFor(60, { $0.live }) != nil else { return .fail("Not approved within 60 s", notes) }
        guard ask("Does \(target.name) now show your live camera? [y/n]") == "y" else { return .fail("Live video not shown", notes) }
        let closedAt = Date()
        context.app.send(.closeAllShutters)
        guard context.app.waitFor(2, { !$0.live }) != nil else { return .fail("Shutter did not close", notes) }
        notes.append(("shutter closed after", String(format: "%.0f ms", Date().timeIntervalSince(closedAt) * 1000)))
        guard ask("Is \(target.name) back on the placeholder, with the call still connected? [y/n]") == "y" else {
            return .fail("Placeholder or call not right after closing", notes)
        }
        print("Now end the call or close the camera in \(target.name).")
        if context.app.waitFor(60, { !$0.sessions.contains { $0.app == target.bundleID } }) == nil {
            notes.append(("session end", "not seen within 60 s"))
        }
        return .pass("Placeholder, live on approval, placeholder on close", notes)
    }

    private static func ask(_ question: String, allowed: Set<String> = ["y", "n"]) -> String {
        while true {
            print("\(question) ", terminator: "")
            guard let line = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() else { return "n" }
            if let answer = line.first.map(String.init), allowed.contains(answer) { return answer }
        }
    }
}
