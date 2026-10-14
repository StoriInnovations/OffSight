import AppKit
import Foundation

/// Collects results and writes them as a Markdown report.
final class Report {
    struct Entry {
        let id: String
        let title: String
        let requirements: String
        let outcome: Outcome
        let seconds: Double
    }

    private(set) var entries: [Entry] = []
    private let started = Date()

    func add(_ entry: Entry) {
        entries.append(entry)
        let mark: String
        switch entry.outcome.status {
        case .pass: mark = "✅ PASS"
        case .fail: mark = "❌ FAIL"
        case .skip: mark = "⏭  SKIP"
        }
        print("\(mark)  \(entry.title) — \(entry.outcome.detail)")
        for (key, value) in entry.outcome.metrics {
            print("         \(key): \(value)")
        }
    }

    var failed: Bool { entries.contains { $0.outcome.status == .fail } }

    func write(to path: String) throws {
        var lines: [String] = []
        let formatter = ISO8601DateFormatter()
        lines.append("# OffSight test report")
        lines.append("")
        lines.append("- Date: \(formatter.string(from: started))")
        lines.append("- Mac: \(Self.sysctl("hw.model") ?? "?"), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        if let info = Self.appInfo {
            lines.append("- OffSight: \(info)")
        }
        let counts = Dictionary(grouping: entries, by: { $0.outcome.status }).mapValues(\.count)
        lines.append("- Results: \(counts[.pass] ?? 0) passed, \(counts[.fail] ?? 0) failed, \(counts[.skip] ?? 0) skipped")
        lines.append("")
        lines.append("| Result | Check | Requirements | Details | Time |")
        lines.append("|---|---|---|---|---|")
        for entry in entries {
            var details = entry.outcome.detail
            if !entry.outcome.metrics.isEmpty {
                details += "<br>" + entry.outcome.metrics.map { "\($0): \($1)" }.joined(separator: "<br>")
            }
            lines.append("| \(entry.outcome.status.rawValue) | \(entry.title) | \(entry.requirements) | \(details.replacingOccurrences(of: "|", with: "\\|")) | \(String(format: "%.1f s", entry.seconds)) |")
        }
        lines.append("")
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    private static var appInfo: String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.storiinnovations.offsight"),
              let bundle = Bundle(url: url) else { return nil }
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build)) at \(url.path)"
    }

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
