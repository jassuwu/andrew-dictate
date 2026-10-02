import Foundation

/// how one meeting ended, and what the capture and the engine did on the
/// way there: the evidence a lost meeting or a hollow transcript leaves.
///
/// never any of the words. not what was said, not a file name that took its
/// name from it — counts and times are all a record knows about the talk,
/// which is what makes it safe to send to jass.
struct MeetingRecord: Equatable, Sendable {
    /// every way a meeting ends. a recovery is not one of them: it ends in
    /// one of these like any other, and `recovered` says the rest.
    enum Outcome: Equatable, Sendable {
        /// the transcript is on disk.
        case saved
    }

    /// what one side of the call said, as counts.
    struct Side: Equatable, Sendable {
        var turns = 0
        var words = 0
    }

    var outcome: Outcome
    /// the app as shown to people: "zoom", "chrome".
    var app: String
    /// the meeting model, by the name the spool and the file use.
    var model: String
    /// wall-clock start, so a record can be matched to a report.
    var startedAt: Date
    /// seconds of the meeting, gaps included.
    var durationS: Double
    /// stretches the tap was lost for, and the seconds of the meeting they
    /// took between them.
    var gaps = 0
    var gapsLostS: Double = 0
    var you = Side()
    var them = Side()
    /// seconds from the stop to the transcript being on disk. nil when it
    /// never got there, and for a recovery, which has no stop of its own.
    var toDiskS: Double?
}

// MARK: - from a meeting

extension MeetingRecord {
    /// the record of a meeting that has ended, worked out from what it left
    /// behind. the turns are counted and let go: nothing of them is kept.
    init(
        _ outcome: Outcome,
        app: String,
        model: MeetingModel,
        startedAt: Date,
        duration: Duration,
        gaps: [MeetingSession.Gap] = [],
        turns: [MeetingTurn] = [],
        toDisk: Duration? = nil
    ) {
        self.init(
            outcome: outcome,
            app: app,
            model: model.rawValue,
            startedAt: startedAt,
            durationS: Self.seconds(duration),
            gaps: gaps.count,
            gapsLostS: Self.seconds(gaps.reduce(.zero) { $0 + $1.duration }),
            you: Self.side(.you, in: turns),
            them: Self.side(.them, in: turns),
            toDiskS: toDisk.map(Self.seconds)
        )
    }

    private enum Who {
        case you
        case them
    }

    /// whitespace-separated, the way the transcript's own `words:` counts,
    /// so the two numbers are the same number.
    private static func side(_ who: Who, in turns: [MeetingTurn]) -> Side {
        var side = Side()
        for turn in turns {
            switch (turn.speaker, who) {
            case (.you, .you), (.them, .them):
                side.turns += 1
                side.words += turn.text.split(whereSeparator: \.isWhitespace).count
            case (.you, .them), (.them, .you):
                break
            }
        }
        return side
    }

    /// to a tenth: a gap of four and a half seconds is not four, and a
    /// stored record is not the place for seventeen digits.
    private static func seconds(_ duration: Duration) -> Double {
        (duration.totalSeconds * 10).rounded() / 10
    }
}
