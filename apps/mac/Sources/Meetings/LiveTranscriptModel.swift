import Foundation

/// What the live transcript panel is looking at while a meeting runs.
///
/// The panel is a window onto the streaming pass, not a second copy of it:
/// this holds the lines the recogniser has emitted so far and nothing else —
/// no file, no diarisation, no history. SPEC §11: *the live pass is the
/// transcript*, so this must never invent or reorder anything; it only shows
/// what arrived, in the order it arrived.
///
/// Whisper streams a line twice — a tentative tail that keeps changing, then
/// the same line confirmed — which is why the only write is `upsert`. A line
/// keeps its `id` across revisions, so replacing in place is what keeps the
/// panel from growing a duplicate of every sentence.
@MainActor
final class LiveTranscriptModel: ObservableObject {
    @Published private(set) var lines: [LiveLine]
    /// The app being tapped, as the header says it: "zoom", "chrome".
    @Published var app: String
    /// How long this meeting has been running.
    @Published var elapsed: Duration

    init(
        app: String = "",
        elapsed: Duration = .zero,
        lines: [LiveLine] = []
    ) {
        self.app = app
        self.elapsed = elapsed
        self.lines = lines
    }

    /// Replaces the line with the same id, or appends it if this is the first
    /// time we have seen it. Position never changes on a revision — a tail
    /// that gets confirmed stays where it was said.
    func upsert(_ line: LiveLine) {
        if let index = lines.firstIndex(where: { $0.id == line.id }) {
            lines[index] = line
        } else {
            lines.append(line)
        }
    }

    func clear() {
        lines.removeAll()
    }
}

extension LiveTranscriptModel {
    /// The running clock in the header: `12:34`, and `1:02:03` once a meeting
    /// passes an hour. Hours are not padded — a leading zero would make an
    /// eleven-minute meeting look like it had been going all day.
    static func clockText(_ duration: Duration) -> String {
        let (hours, minutes, seconds) = parts(of: duration)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }

    /// The stamp in front of a line, always the same width so the text after
    /// it lines up: `00:07:12`.
    static func stampText(_ duration: Duration) -> String {
        let (hours, minutes, seconds) = parts(of: duration)
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    private static func parts(
        of duration: Duration
    ) -> (hours: Int, minutes: Int, seconds: Int) {
        let total = max(0, Int(duration.components.seconds))
        return (total / 3_600, (total % 3_600) / 60, total % 60)
    }
}
