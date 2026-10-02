import Foundation

/// How long a meeting's audio waits after its transcript is written, before
/// it is deleted without asking (ADR 0048). A transcript the coverage check
/// found thin keeps its audio until you delete it, whatever this says. Read
/// once when a meeting starts, like the folder and the model.
enum KeepMeetingAudio: String, CaseIterable, Identifiable, Sendable {
    case deleteAtOnce = "delete-at-once"
    case oneDay = "one-day"
    case sevenDays = "seven-days"

    static let `default` = oneDay

    var id: Self { self }

    /// The words the settings row offers.
    var label: String {
        switch self {
        case .deleteAtOnce: "delete at once"
        case .oneDay: "one day"
        case .sevenDays: "seven days"
        }
    }

    /// How long after the file it is kept, or nil for not at all.
    var keptFor: TimeInterval? {
        switch self {
        case .deleteAtOnce: nil
        case .oneDay: 86_400
        case .sevenDays: 7 * 86_400
        }
    }
}
