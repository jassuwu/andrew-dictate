import Foundation

/// One line of the live transcript as the panel shows it while a meeting
/// runs. Whisper streams confirmed text and a tentative tail that keeps
/// changing; `isConfirmed` is what lets the panel draw one in ink and the
/// other dimmed, rather than pretending both are final.
struct LiveLine: Identifiable, Equatable, Sendable {
    enum Speaker: Equatable, Sendable {
        case you
        case them
    }

    let id: UUID
    let speaker: Speaker
    /// Offset from the start of the meeting.
    let at: Duration
    var text: String
    var isConfirmed: Bool

    init(
        id: UUID = UUID(),
        speaker: Speaker,
        at: Duration,
        text: String,
        isConfirmed: Bool
    ) {
        self.id = id
        self.speaker = speaker
        self.at = at
        self.text = text
        self.isConfirmed = isConfirmed
    }
}
