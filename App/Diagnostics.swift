import AppKit
import Foundation
import OffSightCore

/// Plain-text report for the spike runbook. Contains no video data and no personal content.
enum Diagnostics {
    static func report(snapshot: ClientSnapshot?, link: ExtensionLink, installer: ExtensionInstaller,
                       resolved: [ResolvedApp], engine: PolicyEngine, captureDevice: String?,
                       feeder: SinkFeeder, bypass: BypassMonitor) -> String {
        var lines: [String] = []
        let info = Bundle.main.infoDictionary ?? [:]
        lines.append("OffSight diagnostics — \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("App version: \(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))")
        lines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        #if arch(arm64)
        lines.append("Architecture: arm64")
        #else
        lines.append("Architecture: x86_64")
        #endif
        lines.append("")
        lines.append("Extension install state: \(installer.state.label)")
        lines.append("Extension reported by macOS: \(installer.installedDescription)")
        lines.append("CoreMediaIO devices:")
        for device in CMIO.devices() {
            lines.append("  - \(CMIO.name(of: device) ?? "?") uid=\(CMIO.deviceUID(of: device) ?? "?") runningSomewhere=\(CMIO.isRunningSomewhere(device).map { String($0) } ?? "?")")
        }
        lines.append("AVFoundation cameras:")
        for device in BypassMonitor.allCameras() {
            lines.append("  - \(device.localizedName) uid=\(device.uniqueID) physical=\(BypassMonitor.isPhysical(device)) inUseByAnotherApp=\(device.isInUseByAnotherApplication)")
        }
        lines.append("Device found: \(link.deviceID.map { String($0) } ?? "no"); source stream \(link.sourceStreamID.map { String($0) } ?? "-"); sink stream \(link.sinkStreamID.map { String($0) } ?? "-")")
        lines.append("Sink start status: \(link.sinkStartStatus.map { String($0) } ?? "not attempted") after \(link.sinkStartAttempts) attempt(s)")
        lines.append("Snapshot listener callbacks: \(link.listenerCallbacks)")
        lines.append("Capture device: \(captureDevice ?? "not configured")")
        lines.append("Feeder: sent \(feeder.framesSent), dropped \(feeder.framesDropped)")
        lines.append("")
        if let snapshot {
            lines.append("Extension epoch \(snapshot.epoch), generation \(snapshot.generation), active format \(snapshot.activeFormat)")
            lines.append("Sink connected: \(snapshot.sinkConnected), auth mode: \(snapshot.sinkAuthMode)")
            let s = snapshot.stats
            lines.append("Gate: live forwarded \(s.liveFramesForwarded), placeholder sent \(s.placeholderFramesSent)")
            lines.append("Gate rejects: unauthenticated \(s.rejectedUnauthenticated), missing tag \(s.rejectedMissingTag), wrong epoch \(s.rejectedWrongEpoch), stale generation \(s.rejectedStaleGeneration), wrong size \(s.rejectedWrongDimensions)")
            lines.append("Clients:")
            for client in snapshot.clients {
                lines.append("  - pid \(client.pid) signingID \(client.signingID ?? "nil") streaming \(client.streaming) seq \(client.startSequence) restartGap \(client.restartGap.map { String(format: "%.2f", $0) } ?? "-")")
            }
        } else {
            lines.append("No snapshot read from the extension")
        }
        lines.append("")
        lines.append("Resolved apps:")
        for app in resolved.sorted(by: { $0.key < $1.key }) {
            lines.append("  - \(app.key.id) → \(app.displayName) via \(app.method)")
        }
        lines.append("")
        lines.append("Policy: outputLive \(engine.outputLive), paused \(engine.isPaused)")
        for session in engine.activeSessions {
            lines.append("  - \(session.app.id): \(session.phase.rawValue)")
        }
        lines.append("Bypass: \(bypass.camerasInUse.isEmpty ? "none" : bypass.camerasInUse.joined(separator: ", "))")
        for signal in bypass.lastSignals {
            lines.append("  - \(signal.name): avInUse=\(signal.avInUseByAnotherApp) cmioRunning=\(signal.cmioRunningSomewhere.map { String($0) } ?? "?") counted=\(signal.counted)")
        }
        lines.append("Physical cameras: \(BypassMonitor.physicalCameras().map(\.localizedName).joined(separator: ", "))")
        return lines.joined(separator: "\n")
    }
}
