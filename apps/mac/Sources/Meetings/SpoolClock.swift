import Foundation

/// A meeting has two clocks. Its own runs through a gap; the spool's runs
/// only while audio is written to it. A turn is stamped on the meeting's
/// clock, and anything that hears the spool — the speaker split, a reading
/// again, a recovery — is on the spool's.
///
/// A gap is not always a hole in the spool. The old tap goes on delivering
/// through the settle, and while the call cannot be heard the mic alone
/// goes on delivering your side, and all of it is spooled; a sleep spools
/// nothing. So each gap carries how much audio the spool held where it
/// began and where it ended, noted as it happened, and only what the spool
/// did not get is skipped. Inside a gap, what was spooled is taken to be its
/// last part: the outage comes first, at the settle or the sleep, and the
/// audio after it runs up to where the gap closed.
struct SpoolClock: Equatable, Sendable {
    /// A gap on both clocks.
    struct Gap: Equatable, Sendable {
        /// Where it began and ended on the meeting's clock.
        let began: Duration
        let ended: Duration
        /// How much audio the spool held at each.
        let spooledAtBegan: Duration
        let spooledAtEnded: Duration

        /// The gap as the file and the record say it.
        var onTheMeetingsClock: MeetingSession.Gap {
            MeetingSession.Gap(began: began, ended: ended)
        }
    }

    /// In order, as the meeting had them.
    let gaps: [Gap]

    init(_ gaps: [Gap] = []) {
        self.gaps = gaps
    }

    /// Gaps known only on the meeting's clock — a transcript's front
    /// matter says no more — taken as holes: nothing spooled in any of them.
    init(nothingSpooledDuring gaps: [MeetingSession.Gap]) {
        var lost = Duration.zero
        self.gaps = gaps.map { gap in
            let spooled = max(.zero, gap.began - lost)
            lost += gap.duration
            return Gap(
                began: gap.began, ended: gap.ended,
                spooledAtBegan: spooled, spooledAtEnded: spooled)
        }
    }

    /// The gaps as the file and the record say them.
    var meetingGaps: [MeetingSession.Gap] {
        gaps.map(\.onTheMeetingsClock)
    }

    /// Where a moment of the meeting is on the spool. One in a hole is where
    /// the hole is.
    func onTheSpool(_ at: Duration) -> Duration {
        var lastEnded = Duration.zero
        var lastSpooled = Duration.zero
        for gap in gaps {
            if at < gap.began {
                return max(.zero, min(lastSpooled + (at - lastEnded), gap.spooledAtBegan))
            }
            if at < gap.ended {
                let spooled = gap.spooledAtEnded - (gap.ended - at)
                return min(gap.spooledAtEnded, max(gap.spooledAtBegan, spooled))
            }
            lastEnded = gap.ended
            lastSpooled = gap.spooledAtEnded
        }
        return max(.zero, lastSpooled + (at - lastEnded))
    }

    /// Where a moment of the spool is in the meeting: the reverse.
    func onTheMeetingsClock(_ at: Duration) -> Duration {
        var lastEnded = Duration.zero
        var lastSpooled = Duration.zero
        for gap in gaps {
            if at < gap.spooledAtBegan {
                return lastEnded + (at - lastSpooled)
            }
            if at < gap.spooledAtEnded {
                return gap.ended - (gap.spooledAtEnded - at)
            }
            lastEnded = gap.ended
            lastSpooled = gap.spooledAtEnded
        }
        return lastEnded + (at - lastSpooled)
    }

    /// Turns moved onto the spool, where their audio is: after a hole, a
    /// turn stamped on the meeting's clock would sit past its audio, and
    /// every speaker after it would be guessed from the wrong voice. Its end
    /// moves with it.
    func onTheSpool(_ turns: [MeetingTurn]) -> [MeetingTurn] {
        guard !gaps.isEmpty else { return turns }
        return turns.map { $0.moved(to: onTheSpool($0.at)) }
    }

    /// Turns read from the spool, back onto the meeting's clock: the
    /// reverse of `onTheSpool`.
    func onTheMeetingsClock(_ turns: [MeetingTurn]) -> [MeetingTurn] {
        guard !gaps.isEmpty else { return turns }
        return turns.map { $0.moved(to: onTheMeetingsClock($0.at)) }
    }

    /// The speakers a split found, onto the turns as the meeting stamped
    /// them: the file keeps the times the meeting actually had.
    static func speakers(of split: [MeetingTurn], onto turns: [MeetingTurn]) -> [MeetingTurn] {
        guard split.count == turns.count else { return turns }
        return zip(turns, split).map { $0.said(by: $1.speaker) }
    }
}

extension MeetingTurn {
    /// The same turn at another time on another clock: its end moves by as
    /// much as its start.
    func moved(to at: Duration) -> MeetingTurn {
        MeetingTurn(speaker: speaker, at: at, text: text, end: end.map { $0 + (at - self.at) })
    }
}
