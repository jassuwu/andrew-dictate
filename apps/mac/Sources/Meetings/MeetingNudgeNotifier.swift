import Foundation
import UserNotifications

/// "still recording?" — asked through a notification, because it is the one
/// surface with buttons that does not steal focus and reaches you inside the
/// meeting app (ADR 0040, Q14). It asks; it never acts: no answer means keep
/// going, and only `stop` stops.
///
/// The same channel delivers the finished transcript. A meeting has no
/// visible result — the two-second pill is gone before you are back at the
/// mac — so the one banner that waits is how the file reaches you.
@MainActor
final class MeetingNudgeNotifier: NSObject, UNUserNotificationCenterDelegate {
    var onKeepGoing: (@MainActor () -> Void)?
    var onStop: (@MainActor () -> Void)?
    var onShowFile: (@MainActor (URL) -> Void)?

    private static let category = "gg.jass.dictate.meeting-nudge"
    private static let keepGoing = "keep-going"
    private static let stop = "stop"
    private static let identifier = "meeting-nudge"

    private static let savedCategory = "gg.jass.dictate.meeting-saved"
    private static let showInFinder = "show-in-finder"
    /// Its own identifier: `withdraw()` pulls the nudge at every stop, and
    /// the saved banner is meant to stay until it is read.
    private static let savedIdentifier = "meeting-saved"

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
        let show = UNNotificationAction(
            identifier: Self.showInFinder, title: "show in finder", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.category, actions: [keep, stop],
                intentIdentifiers: [], options: []),
            UNNotificationCategory(
                identifier: Self.savedCategory, actions: [show],
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
        content.body = "nothing has been heard for \(quietFor.spoken). it keeps going unless you stop it."
        content.categoryIdentifier = Self.category
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(
            identifier: Self.identifier, content: content, trigger: nil)
        center.add(request)
    }

    /// `zoom · 1h 42m · 2 gaps · 2026-09-05-1402-zoom.md` — the file is the
    /// feature, so it is named. Pure, so the copy can be read in a test that
    /// has no bundle to post from.
    static func savedBody(_ summary: MeetingSummary) -> String {
        var parts = [summary.app, summary.duration.spoken]
        if summary.gapCount > 0 {
            parts.append("\(summary.gapCount) \(summary.gapCount == 1 ? "gap" : "gaps")")
        } else if summary.recovered {
            parts.append("recovered")
        }
        parts.append(summary.fileURL.lastPathComponent)
        return parts.joined(separator: " · ")
    }

    /// The meeting is written out. Nothing here is urgent — it waits on the
    /// lock screen until you come back, which is exactly what the pill
    /// cannot do.
    func saved(_ summary: MeetingSummary) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = "meeting saved"
        content.body = Self.savedBody(summary)
        content.categoryIdentifier = Self.savedCategory
        content.interruptionLevel = .active
        content.userInfo = ["file": summary.fileURL.path(percentEncoded: false)]
        center.add(UNNotificationRequest(
            identifier: Self.savedIdentifier, content: content, trigger: nil))
    }

    /// No file exists yet, so no finder button: the spool is being kept and
    /// the next launch writes it out.
    func saveFailed() {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = "the transcript is not saved yet"
        content.body = "it is kept — the next launch writes it out."
        content.interruptionLevel = .active
        center.add(UNNotificationRequest(
            identifier: Self.savedIdentifier, content: content, trigger: nil))
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
        let category = response.notification.request.content.categoryIdentifier
        let file = response.notification.request.content
            .userInfo["file"] as? String
        await MainActor.run {
            switch action {
            case Self.showInFinder:
                if let file {
                    onShowFile?(URL(fileURLWithPath: file))
                }
            case Self.stop:
                onStop?()
            default:
                // "keep going", tapping the banner, or dismissing it: all
                // mean the meeting is still on — but only the nudge asked
                // anything, so the saved banner answers nothing.
                guard category == Self.category else { return }
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
