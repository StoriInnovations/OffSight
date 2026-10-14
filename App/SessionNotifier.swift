import Foundation
import OffSightCore
import os
import UserNotifications

/// Notifications when an app goes live and when its camera session ends (UR-23).
/// Fed the current state on every update; it works out what changed itself.
final class SessionNotifier {
    private var liveApps: Set<AppKey> = []
    /// Apps that went live during their current session, so its end is worth announcing.
    private var wentLive: Set<AppKey> = []
    private var authorisationRequested = false
    private let log = Logger(subsystem: OffSightConstants.logSubsystem, category: "notifications")

    /// `live`: apps currently receiving live video. `active`: apps with a camera session.
    func update(live: Set<AppKey>, active: Set<AppKey>, name: (AppKey) -> String) {
        let enabled = AppDefaults.notificationsEnabled
        if enabled { requestAuthorisationIfNeeded() }
        for app in live.subtracting(liveApps) where enabled {
            post(title: "\(name(app)) is live", body: "\(name(app)) is receiving your camera video for this session.")
        }
        wentLive.formUnion(live)
        for app in wentLive.subtracting(active) {
            if enabled {
                post(title: "\(name(app)) camera session ended", body: "The shutter is closed again. Next time it will ask first.")
            }
            wentLive.remove(app)
        }
        liveApps = live
    }

    /// A one-off notice that matters for safety or setup (camera unplugged, restart needed).
    /// Shown whenever macOS allows notifications, whatever the live/ended setting.
    func notice(title: String, body: String) {
        requestAuthorisationIfNeeded()
        post(title: title, body: body)
    }

    private func requestAuthorisationIfNeeded() {
        guard !authorisationRequested else { return }
        authorisationRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [log] granted, error in
            if let error {
                log.error("Notification authorisation failed: \(error.localizedDescription, privacy: .public)")
            } else if !granted {
                log.info("Notifications not allowed by the user")
            }
        }
    }

    private func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
