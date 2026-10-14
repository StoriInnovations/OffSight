import AVFoundation
import Foundation
import OffSightCore

// offsight-test: automated and guided on-device tests for OffSight. See README.md.

let usage = """
usage: offsight-test <command> [options]

commands:
  list                      List the automated checks.
  run [ids…]                Run automated checks (all, or the ids given).
  manual [apps…]            Guided checks for Zoom, Teams, Meet, Webex, Slack, FaceTime… (all, or names given).
  all                       Automated checks, then the guided checks.
  state                     Print OffSight's current state (Debug builds) and the camera's counters.

options:
  --report <path>           Where to write the Markdown report (default: offsight-test-report-<time>.md).
  --grace <seconds>         Grace period to use during the run (default 5, the minimum).

Needs: a Debug build of OffSight installed with scripts/dev-install.sh (only Debug builds accept test
commands), OffSight Camera enabled, and camera access for the terminal (macOS asks on first run).
"""

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    print(usage)
    exit(2)
}
arguments.removeFirst()

var options = TestContext.Options()
var reportPath: String?
var rest: [String] = []
var index = 0
while index < arguments.count {
    switch arguments[index] {
    case "--report":
        index += 1
        reportPath = index < arguments.count ? arguments[index] : nil
    case "--grace":
        index += 1
        if index < arguments.count, let seconds = Double(arguments[index]) { options.grace = seconds }
    default:
        rest.append(arguments[index])
    }
    index += 1
}

func ensureCameraAccess() -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
        return true
    case .notDetermined:
        var granted = false
        var answered = false
        AVCaptureDevice.requestAccess(for: .video) { ok in granted = ok; answered = true }
        Wait.until(120, { answered })
        return granted
    default:
        print("Camera access is off for this terminal. Allow it in System Settings › Privacy & Security › Camera, then rerun.")
        return false
    }
}

func defaultReportPath() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return "offsight-test-report-\(formatter.string(from: Date())).md"
}

func runAutomated(ids: [String], context: TestContext, report: Report) {
    let chosen = ids.isEmpty ? Scenarios.all : Scenarios.all.filter { ids.contains($0.id) }
    if chosen.isEmpty {
        print("No checks match \(ids.joined(separator: ", ")). See `offsight-test list`.")
        return
    }
    // The environment check always runs first; stop early if OffSight can't be tested.
    do {
        let start = Date()
        let outcome = Scenarios.environment.run(context)
        report.add(.init(id: Scenarios.environment.id, title: Scenarios.environment.title,
                         requirements: Scenarios.environment.requirements, outcome: outcome, seconds: Date().timeIntervalSince(start)))
        if outcome.status == .fail { return }
    }
    context.prepare()
    defer { context.finish() }
    for scenario in chosen where scenario.id != Scenarios.environment.id {
        print("\n▶ \(scenario.title)")
        let start = Date()
        let outcome = scenario.run(context)
        report.add(.init(id: scenario.id, title: scenario.title, requirements: scenario.requirements,
                         outcome: outcome, seconds: Date().timeIntervalSince(start)))
    }
}

switch command {
case "list":
    for scenario in Scenarios.all {
        print("\(scenario.id.padding(toLength: 22, withPad: " ", startingAt: 0)) \(scenario.title)  [\(scenario.requirements)]")
    }
    print("\nGuided (manual): " + Manual.targets.map(\.name).joined(separator: ", "))

case "state":
    let app = AppLink()
    if let state = app.state() {
        print(state.encodedJSON)
    } else {
        print("No answer from OffSight's test hook (not running, or not a Debug build).")
    }
    if let snapshot = Probe.snapshot() {
        print("camera: format \(snapshot.activeFormat), clients \(snapshot.clients.count), counters \(Probe.counters().map { "live \($0.live), app placeholder \($0.appPlaceholder), fallback \($0.fallback)" } ?? "n/a")")
    } else {
        print("camera: OffSight Camera not found")
    }

case "run", "manual", "all":
    guard ensureCameraAccess() else { exit(1) }
    let context = TestContext(options: options)
    let report = Report()
    if command == "run" || command == "all" {
        runAutomated(ids: command == "run" ? rest : [], context: context, report: report)
    }
    if command == "manual" || command == "all" {
        context.prepare()
        Manual.run(only: command == "manual" ? rest : [], context: context, report: report)
        context.finish()
    }
    let path = reportPath ?? defaultReportPath()
    do {
        try report.write(to: path)
        print("\nReport: \(path)")
    } catch {
        print("\nCould not write the report: \(error.localizedDescription)")
    }
    exit(report.failed ? 1 : 0)

default:
    print(usage)
    exit(2)
}
