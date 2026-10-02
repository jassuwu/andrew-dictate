import XCTest

/// The far side's turns given the voices the diarizer heard, piece by
/// piece: who said each, and the numbers the file gives them.
final class SpeakerTurnsTests: XCTestCase {
    /// The diarizer found three voices, but the second only ever spoke over
    /// a turn of someone else's, so no turn is its. The file says `them 1`
    /// and `them 2` — not `them 1` and `them 3`, as a real one did.
    func testSpeakersAreNumberedByFirstAppearanceAmongTheTurns() {
        let segments = [
            segment("7", 0, 10),
            segment("4", 10, 11),
            segment("9", 20, 30),
        ]
        let turns = [them(at: 2), them(at: 22), them(at: 5)]

        XCTAssertEqual(
            SpeakerTurns.assign(turns, to: segments).map(\.speaker.label),
            ["them 1", "them 2", "them 1"])
    }

    /// The pieces are heard by one diarizer, so a voice keeps its id from
    /// one piece to the next: whoever spoke in the first five minutes and
    /// again an hour on is one speaker in the file. Each turn keeps where it
    /// ended, which is where its paragraph breaks.
    func testAVoiceHeardInTwoPiecesIsOneSpeakerAndEveryTurnKeepsItsEnd() {
        let segments = [
            segment("1", 10, 40),
            segment("2", 50, 80),
            segment("1", 3_610, 3_640),
        ]
        let turns = [
            them(at: 12, end: 20),
            them(at: 55, end: 61.5),
            them(at: 3_615, end: 3_630),
        ]

        let split = SpeakerTurns.assign(turns, to: segments)

        XCTAssertEqual(split.map(\.speaker.label), ["them 1", "them 2", "them 1"])
        XCTAssertEqual(split.map(\.end), turns.map(\.end))
        XCTAssertEqual(split.map(\.at), turns.map(\.at))
    }

    /// One voice among the turns is no split: they stay plain `them`, as
    /// they were, ends and all — even when the diarizer heard a second
    /// voice somewhere nobody's turn began.
    func testOneVoiceAmongTheTurnsLeavesThemPlainAsTheyWere() {
        let segments = [segment("1", 0, 30), segment("2", 30, 31)]
        let turns = [them(at: 2, end: 9), them(at: 12, end: 14)]

        XCTAssertEqual(SpeakerTurns.assign(turns, to: segments), turns)
    }

    /// A turn no segment covers — the diarizer drops anything under a
    /// second — takes the voice that starts nearest it. Yours are yours.
    func testATurnNoSegmentCoversTakesTheNearestVoiceAndYoursAreLeftAlone() {
        let segments = [segment("a", 0, 10), segment("b", 20, 30)]
        let turns = [
            them(at: 1),
            MeetingTurn(speaker: .you, at: .seconds(5), text: "me"),
            them(at: 18),
        ]

        XCTAssertEqual(
            SpeakerTurns.assign(turns, to: segments).map(\.speaker.label),
            ["them 1", "you", "them 2"])
    }

    // MARK: - numbered

    /// Whatever numbered the turns, the file's numbers are 1, 2, 3 in order
    /// of first appearance: a split that used 3 and 1 comes out 1 and 2.
    /// Plain `them` and `you` are not numbers and stay as they are, and
    /// every turn keeps its times.
    func testNumbersAreClosedUpInOrderOfFirstAppearance() {
        let turns = [
            them(at: 1, end: 2, as: 3),
            MeetingTurn(speaker: .you, at: .seconds(2), text: "me"),
            them(at: 3, end: 4),
            them(at: 5, end: 6, as: 1),
            them(at: 7, end: 9, as: 3),
        ]

        let numbered = SpeakerTurns.numbered(turns)

        XCTAssertEqual(numbered.map(\.speaker.label), ["them 1", "you", "them", "them 2", "them 1"])
        XCTAssertEqual(numbered.map(\.at), turns.map(\.at))
        XCTAssertEqual(numbered.map(\.end), turns.map(\.end))
    }

    // MARK: -

    private func segment(_ speaker: String, _ from: Double, _ to: Double) -> SpeakerSegment {
        SpeakerSegment(speaker: speaker, from: .seconds(from), to: .seconds(to))
    }

    private func them(at seconds: Double, end: Double? = nil, as number: Int? = nil) -> MeetingTurn {
        MeetingTurn(
            speaker: .them(number), at: .seconds(seconds), text: "words",
            end: end.map { .seconds($0) })
    }
}
