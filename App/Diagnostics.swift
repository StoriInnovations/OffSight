import AppKit
import Foundation
import OffSightCore

/// Plain-text report for the spike runbook. Contains no video data and no personal content.
enum Diagnostics {
    static func report(snapshot: ClientSnapshot?, link: ExtensionLink, installer: ExtensionInstaller,
                       resolved: [ResolvedApp], engine: PolicyEngine, captureDevice: String?,
                       nativeFormat: Dimensions?, captureMode: String?, timeline: [String], feeder: SinkFeeder, bypass: BypassMonitor) -> String {
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
        lines.append("Snapshot listener callbacks: \(link.listenerCallbacks); device binds: \(link.rebinds)")
        lines.append("Capture device: \(captureDevice ?? "not configured"); native format \(nativeFormat?.description ?? "unknown"); OffSight Camera format wanted \(nativeFormat.map { OffSightConstants.effectsFreeFormat(for: $0).description } ?? "unknown")")
        lines.append("Capture mode: \(captureMode ?? "not configured")")
        lines.append("Feeder: live sent \(feeder.framesSent), dropped \(feeder.framesDropped); placeholder sent \(feeder.placeholderFramesSent)")
        lines.append("Placeholder: \(feeder.placeholderDescription)")
        lines.append("Placeholder choice: \(PlaceholderImageStore.mode.title) (\(PlaceholderImageStore.cacheKey))")
        lines.append("")
        if let snapshot {
            lines.append("Extension epoch \(snapshot.epoch), generation \(snapshot.generation), camera format \(snapshot.activeFormat)\(snapshot.pendingFormat.map { " (switching to \($0) when idle)" } ?? "")")
            lines.append("Sink connected: \(snapshot.sinkConnected), auth mode: \(snapshot.sinkAuthMode)")
            if let sink = snapshot.sink {
                lines.append("Sink consume: loops \(sink.consumeLoopsStarted), callbacks \(sink.consumeCallbacks), buffers \(sink.buffersReceived), without image \(sink.buffersWithoutImage), errors \(sink.consumeErrors)\(sink.lastError.map { " (last: \($0))" } ?? "")")
            } else {
                lines.append("Sink consume: not reported (older extension build)")
            }
            if let source = snapshot.source {
                lines.append("Source stream: streaming \(source.streaming), start calls \(source.startCalls), stop calls \(source.stopCalls); sent live \(source.sentLive), app placeholder \(source.sentAppPlaceholder), fallback \(source.sentFallback); dropped (not streaming) \(source.droppedNotStreaming)")
            } else {
                lines.append("Source stream: not reported (older extension build)")
            }
            let s = snapshot.stats
            lines.append("Gate: live forwarded \(s.liveFramesForwarded), app placeholder forwarded \(s.appPlaceholderFramesForwarded), extension fallback placeholder \(s.placeholderFramesSent)")
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
        let policy = engine.settings
        lines.append("Settings: prompt expiry \(Int(policy.promptExpiry)) s, grace \(Int(policy.gracePeriod)) s; live camera \(AppDefaults.liveCameraID ?? "automatic"); launch at login \(LaunchAtLogin.isEnabled); notifications \(AppDefaults.notificationsEnabled); close-all \(AppDefaults.shortcut(forKey: AppDefaults.panicShortcutKey)?.displayString ?? "none"), go-live \(AppDefaults.shortcut(forKey: AppDefaults.goLiveShortcutKey)?.displayString ?? "none")")
        lines.append("Bypass: \(bypass.camerasInUse.isEmpty ? "none" : bypass.camerasInUse.joined(separator: ", "))")
        for signal in bypass.lastSignals {
            lines.append("  - \(signal.name): avInUse=\(signal.avInUseByAnotherApp) cmioRunning=\(signal.cmioRunningSomewhere.map { String($0) } ?? "?") counted=\(signal.counted)")
        }
        lines.append("Physical cameras: \(BypassMonitor.physicalCameras().map(\.localizedName).joined(separator: ", "))")
        lines.append("")
        lines.append("Recent events (oldest first):")
        lines.append(contentsOf: timeline.map { "  \($0)" })
        return lines.joined(separator: "\n")
    }
}
