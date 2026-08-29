import Foundation
import UserNotifications

/// "still recording?" — asked through a notification, because it is the one
/// surface with buttons that does not steal focus and reaches you inside the
/// meeting app (ADR 0040, Q14). It asks; it never acts: no answer means keep
/// going, and only `stop` stops.
@MainActor
final class MeetingNudgeNotifier: NSObject, UNUserNotificationCenterDelegate {
    var onKeepGoing: (@MainActor () -> Void)?
    var onStop: (@MainActor () -> Void)?

    private static let category = "gg.jass.dictate.meeting-nudge"
    private static let keepGoing = "keep-going"
    private static let stop = "stop"
    private static let identifier = "meeting-nudge"

    private let center: UNUserNotificationCenter?

    override init() {
        // A bare test binary has no bundle, and the notification centre
        // refuses to exist without one. The app always has it.
        center = Bundle.main.bundleIdentifier == nil ? nil : .current()
        super.init()
        guard let center else { return }
        center.delegate = self
        let keep = UNNotificationAction(
            identifier: Self.keepGoing, title: "keep going", options: [])
        let stop = UNNotificationAction(
            identifier: Self.stop, title: "stop", options: [.destructive])
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.category, actions: [keep, stop],
                intentIdentifiers: [], options: [])
        ])
    }

    /// Asked lazily, the first time a meeting starts — not at onboarding,
    /// where a prompt for a nudge you have not met yet is noise.
    func requestPermissionIfNeeded() async {
        guard let center else { return }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func ask(app: String, quietFor: Duration) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = "still recording \(app)?"
        content.body = "nothing has been heard for \(MeetingEvent.clock(quietFor)). it keeps going unless you stop it."
        content.categoryIdentifier = Self.category
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(
            identifier: Self.identifier, content: content, trigger: nil)
        center.add(request)
    }

    func withdraw() {
        center?.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
        center?.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        await MainActor.run {
            switch action {
            case Self.stop:
                onStop?()
            default:
                // "keep going", tapping the banner, or dismissing it: all
                // mean the meeting is still on.
                onKeepGoing?()
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
