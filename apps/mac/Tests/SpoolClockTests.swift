import XCTest

/// The spool has no audio for a gap, so a turn stamped on the meeting's
/// clock is somewhere else on the spool's, and the speaker split hears the
/// spool. Moved over, looked up, moved back.
final class SpoolClockTests: XCTestCase {
    /// The tap was lost from 30 s to 60 s. A turn said at 70 s is at 40 s
    /// on the spool, in the second voice's segment there; it comes back to
    /// the file with the meeting's 70 s and the end it had.
    func testAfterAGapATurnIsLookedUpWhereItsAudioIsAndKeepsTheMeetingsTimes() {
        let gaps = [MeetingSession.Gap(began: .seconds(30), ended: .seconds(60))]
        let turns = [them(at: 10, end: 12), them(at: 70, end: 75)]

        let onTheSpool = SpoolClock.onTheSpool(turns, gaps: gaps)
        XCTAssertEqual(onTheSpool.map(\.at), [.seconds(10), .seconds(40)])
        XCTAssertEqual(onTheSpool.map(\.end), [.seconds(12), .seconds(45)])

        let split = SpeakerTurns.assign(onTheSpool, to: [
            SpeakerSegment(speaker: "a", from: .zero, to: .seconds(20)),
            SpeakerSegment(speaker: "b", from: .seconds(35), to: .seconds(50)),
        ])
        let back = SpoolClock.speakers(of: split, onto: turns)

        XCTAssertEqual(back.map(\.speaker.label), ["them 1", "them 2"])
        XCTAssertEqual(back.map(\.at), turns.map(\.at))
        XCTAssertEqual(back.map(\.end), turns.map(\.end))
    }

    /// A thin meeting read again from its spool is read on the spool's
    /// clock. Each turn goes back over the gaps before it — and its end
    /// with it, or the file would think it ended before it began.
    func testATurnReadFromTheSpoolGoesBackOnTheMeetingsClockEndAndAll() {
        let gaps = [
            MeetingSession.Gap(began: .seconds(30), ended: .seconds(60)),
            MeetingSession.Gap(began: .seconds(100), ended: .seconds(110)),
        ]
        let read = [them(at: 10, end: 12), them(at: 40, end: 45), them(at: 80, end: 81)]

        let onTheMeetings = SpoolClock.onTheMeetingsClock(read, gaps: gaps)

        XCTAssertEqual(onTheMeetings.map(\.at), [.seconds(10), .seconds(70), .seconds(120)])
        XCTAssertEqual(onTheMeetings.map(\.end), [.seconds(12), .seconds(75), .seconds(121)])
    }

    // MARK: -

    private func them(at seconds: Double, end: Double? = nil) -> MeetingTurn {
        MeetingTurn(
            speaker: .them(nil), at: .seconds(seconds), text: "words",
            end: end.map { .seconds($0) })
    }
}
