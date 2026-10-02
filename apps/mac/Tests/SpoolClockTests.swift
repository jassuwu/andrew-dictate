import XCTest

/// A turn is stamped on the meeting's clock, and the speaker split, a
/// reading again and a recovery hear the spool. Where the spool has a hole
/// the two clocks part; where audio went on being spooled through a gap they
/// do not. Moved over, looked up, moved back.
final class SpoolClockTests: XCTestCase {
    /// The tap was lost from 30 s to 60 s and nothing was spooled. A turn
    /// said at 70 s is at 40 s on the spool, in the second voice's segment
    /// there; it comes back to the file with the meeting's 70 s and the end
    /// it had.
    func testAfterAGapATurnIsLookedUpWhereItsAudioIsAndKeepsTheMeetingsTimes() {
        let clock = SpoolClock(nothingSpooledDuring: [
            MeetingSession.Gap(began: .seconds(30), ended: .seconds(60)),
        ])
        let turns = [them(at: 10, end: 12), them(at: 70, end: 75)]

        let onTheSpool = clock.onTheSpool(turns)
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
    /// clock. Each turn goes back over the holes before it — and its end
    /// with it, or the file would think it ended before it began.
    func testATurnReadFromTheSpoolGoesBackOnTheMeetingsClockEndAndAll() {
        let clock = SpoolClock(nothingSpooledDuring: [
            MeetingSession.Gap(began: .seconds(30), ended: .seconds(60)),
            MeetingSession.Gap(began: .seconds(100), ended: .seconds(110)),
        ])
        let read = [them(at: 10, end: 12), them(at: 40, end: 45), them(at: 80, end: 81)]

        let onTheMeetings = clock.onTheMeetingsClock(read)

        XCTAssertEqual(onTheMeetings.map(\.at), [.seconds(10), .seconds(70), .seconds(120)])
        XCTAssertEqual(onTheMeetings.map(\.end), [.seconds(12), .seconds(75), .seconds(121)])
    }

    /// A tap that kept calling back with silence from 22:00 to 32:00: every
    /// chunk of it was spooled, the far side as nothing, so the gap is no
    /// hole in the spool and moves nothing. A turn at 33:00 is at 33:00 on
    /// the spool too, and one read there comes back at 33:00.
    func testAGapTheSpoolKeptRecordingThroughMovesNothing() {
        let clock = SpoolClock([
            .init(
                began: .seconds(1_320), ended: .seconds(1_920),
                spooledAtBegan: .seconds(1_320), spooledAtEnded: .seconds(1_920)),
        ])
        let turns = [them(at: 1_000, end: 1_002), you(at: 1_500), them(at: 1_980, end: 1_985)]

        XCTAssertEqual(clock.onTheSpool(turns), turns)
        XCTAssertEqual(clock.onTheMeetingsClock(turns), turns)
    }

    /// A sleep from 18:03 to 58:18: nothing came while the lid was shut, and
    /// the rebuilt tap's first second was spooled before the gap closed at
    /// 58:19. Forty minutes and fifteen seconds were skipped, and only those
    /// are taken off — the second the spool did get is not.
    func testAnOutageMovesTurnsByWhatTheSpoolSkippedAndNoMore() {
        let clock = SpoolClock([
            .init(
                began: .seconds(1_083), ended: .seconds(3_499),
                spooledAtBegan: .seconds(1_083), spooledAtEnded: .seconds(1_084)),
        ])
        let skipped = Duration.seconds(3_499 - 1_083 - 1)
        let after = [them(at: 3_600, end: 3_610)]

        let onTheSpool = clock.onTheSpool(after)
        XCTAssertEqual(onTheSpool.map(\.at), [.seconds(3_600) - skipped])
        XCTAssertEqual(onTheSpool.map(\.end), [.seconds(3_610) - skipped])
        XCTAssertEqual(clock.onTheMeetingsClock(onTheSpool), after)

        // the second spooled inside the gap is its last: the rebuilt tap,
        // heard just before it closed.
        XCTAssertEqual(clock.onTheMeetingsClock(.seconds(1_083.5)), .seconds(3_498.5))
        XCTAssertEqual(clock.onTheSpool(.seconds(3_498.5)), .seconds(1_083.5))
        // and the lid shut is no audio at all: it sits where the gap began.
        XCTAssertEqual(clock.onTheSpool(.seconds(2_000)), .seconds(1_083))
    }

    /// Two gaps, one kept recording through and one a hole: only the hole
    /// counts, before and after the other.
    func testOnlyTheHolesBeforeATurnCount() {
        let clock = SpoolClock([
            .init(
                began: .seconds(10), ended: .seconds(20),
                spooledAtBegan: .seconds(10), spooledAtEnded: .seconds(10)),
            .init(
                began: .seconds(50), ended: .seconds(80),
                spooledAtBegan: .seconds(40), spooledAtEnded: .seconds(70)),
        ])

        XCTAssertEqual(clock.onTheSpool(.seconds(5)), .seconds(5))
        XCTAssertEqual(clock.onTheSpool(.seconds(30)), .seconds(20))
        XCTAssertEqual(clock.onTheSpool(.seconds(60)), .seconds(50))
        XCTAssertEqual(clock.onTheSpool(.seconds(90)), .seconds(80))
        for at in [5, 20, 50, 80] {
            XCTAssertEqual(
                clock.onTheMeetingsClock(clock.onTheSpool(.seconds(at))), .seconds(at),
                "\(at)")
        }
    }

    // MARK: -

    private func them(at seconds: Double, end: Double? = nil) -> MeetingTurn {
        MeetingTurn(
            speaker: .them(nil), at: .seconds(seconds), text: "words",
            end: end.map { .seconds($0) })
    }

    private func you(at seconds: Double) -> MeetingTurn {
        MeetingTurn(speaker: .you, at: .seconds(seconds), text: "words")
    }
}
