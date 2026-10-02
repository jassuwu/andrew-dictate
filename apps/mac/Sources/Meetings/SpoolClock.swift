import Foundation

/// A meeting has two clocks. Its own runs through a gap; the spool's does
/// not, because nothing was written to it while the tap was lost. A turn is
/// stamped on the meeting's clock, and anything that hears the spool — the
/// speaker split, a reading again — is on the spool's.
enum SpoolClock {
    /// Turns moved back over the gaps before them, onto the spool, where
    /// their audio is: after a gap, a turn stamped on the meeting's clock
    /// would sit past the end of the audio, and every speaker after it would
    /// be guessed from the last segment. Its end moves with it.
    static func onTheSpool(_ turns: [MeetingTurn], gaps: [MeetingSession.Gap]) -> [MeetingTurn] {
        guard !gaps.isEmpty else { return turns }
        return turns.map { turn in
            let at = max(.zero, turn.at - lost(before: turn.at, in: gaps))
            return turn.moved(to: at)
        }
    }

    /// The speakers a split found, onto the turns as the meeting stamped
    /// them: the file keeps the times the meeting actually had.
    static func speakers(of split: [MeetingTurn], onto turns: [MeetingTurn]) -> [MeetingTurn] {
        guard split.count == turns.count else { return turns }
        return zip(turns, split).map { $0.said(by: $1.speaker) }
    }

    /// Turns read from the spool, moved on over every gap that began before
    /// them, back onto the meeting's clock: the reverse of `onTheSpool`.
    static func onTheMeetingsClock(_ turns: [MeetingTurn], gaps: [MeetingSession.Gap]) -> [MeetingTurn] {
        guard !gaps.isEmpty else { return turns }
        return turns.map { turn in
            var at = turn.at
            for gap in gaps where at >= gap.began {
                at += gap.duration
            }
            return turn.moved(to: at)
        }
    }

    private static func lost(before at: Duration, in gaps: [MeetingSession.Gap]) -> Duration {
        gaps.reduce(.zero) { total, gap in
            guard at > gap.began else { return total }
            return total + (min(at, gap.ended) - gap.began)
        }
    }
}

extension MeetingTurn {
    /// The same turn at another time on another clock: its end moves by as
    /// much as its start.
    func moved(to at: Duration) -> MeetingTurn {
        MeetingTurn(speaker: speaker, at: at, text: text, end: end.map { $0 + (at - self.at) })
    }
}
