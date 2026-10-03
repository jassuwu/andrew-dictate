import XCTest

/// Where the far side is cut for the speaker split while a meeting records,
/// what is left for the stop, and what becomes of a piece the diarizer threw
/// on. Counts of samples on the spool's clock; no audio, no diarizer.
final class SpeakerPiecesTests: XCTestCase {
    /// A piece is cut the moment its whole length has been spooled, and not
    /// a sample sooner.
    func testAPieceIsDueOnceItsLengthHasBeenSpooled() {
        var pieces = SpeakerPieces(length: 1_000)

        XCTAssertEqual(pieces.spool(600), [])
        XCTAssertEqual(pieces.spool(399), [])
        XCTAssertEqual(pieces.spool(1), [.init(frames: 0..<1_000)])
    }

    /// At the stop, what was spooled after the last piece is the tail, the
    /// one piece the stop has to wait for. A meeting that ended on a piece's
    /// edge has none.
    func testTheTailIsWhatWasSpooledAfterTheLastPiece() {
        var pieces = SpeakerPieces(length: 1_000)
        _ = pieces.spool(2_300)

        XCTAssertEqual(pieces.close(), [.init(frames: 2_000..<2_300)])

        var even = SpeakerPieces(length: 1_000)
        _ = even.spool(2_000)
        XCTAssertEqual(even.close(), [])
    }

    /// Once the meeting has stopped nothing more is cut: a chunk that comes
    /// after is not the meeting's, and a second stop finds nothing to do.
    func testNothingIsCutAfterTheStop() {
        var pieces = SpeakerPieces(length: 1_000)
        _ = pieces.spool(500)
        _ = pieces.close()

        XCTAssertEqual(pieces.spool(2_000), [])
        XCTAssertEqual(pieces.close(), [])
    }

    /// A piece the diarizer threw on while the meeting ran gets its second
    /// try at the stop, before the tail: a throw is often a hiccup, and the
    /// meeting is no place to keep trying.
    func testAPieceThatFailsInTheMeetingIsTriedAgainAtTheStop() {
        var pieces = SpeakerPieces(length: 1_000)
        let first = pieces.spool(1_000)[0]

        XCTAssertEqual(pieces.failed(first), .atStop)
        _ = pieces.spool(1_400)

        XCTAssertEqual(pieces.close(), [
            .init(frames: 0..<1_000, isRetry: true),
            .init(frames: 2_000..<2_400),
        ])
    }

    /// One failed piece waits for the stop, and no more: a diarizer that
    /// throws on everything must not pile the meeting up in memory waiting
    /// for a second try. The next one to fail is let go.
    func testOnlyOneFailedPieceWaitsForTheStop() {
        var pieces = SpeakerPieces(length: 1_000)
        let due = pieces.spool(2_000)

        XCTAssertEqual(pieces.failed(due[0]), .atStop)
        XCTAssertEqual(pieces.failed(due[1]), .never)
        XCTAssertEqual(pieces.close(), [.init(frames: 0..<1_000, isRetry: true)])
    }

    /// At the stop there is no later: a piece that fails there is tried
    /// again at once. A second try that fails is let go, wherever it ran.
    func testAtTheStopAFailedPieceIsTriedAgainAtOnceAndASecondTryIsTheLast() {
        var pieces = SpeakerPieces(length: 1_000)
        _ = pieces.spool(500)
        let tail = pieces.close()[0]

        XCTAssertEqual(pieces.failed(tail), .now(.init(frames: 0..<500, isRetry: true)))
        XCTAssertEqual(pieces.failed(.init(frames: 0..<500, isRetry: true)), .never)
    }

    /// Audio in a piece the diarizer heard has speakers. Audio in one it
    /// never did — let go after failing, or still out when the stop gave up
    /// waiting — was skipped, and so was the piece.
    func testAPieceNeverHeardIsSkippedAndSoIsItsAudio() {
        var pieces = SpeakerPieces(length: 1_000)
        let due = pieces.spool(3_000)
        pieces.heard(due[0])
        _ = pieces.failed(due[1])
        _ = pieces.failed(due[2])
        _ = pieces.spool(200)
        let last = pieces.close()
        pieces.heard(last[0])

        XCTAssertEqual(pieces.skipped, 2)
        XCTAssertFalse(pieces.wasSkipped(at: 0))
        XCTAssertFalse(pieces.wasSkipped(at: 1_999))
        XCTAssertTrue(pieces.wasSkipped(at: 2_000))
        XCTAssertTrue(pieces.wasSkipped(at: 3_100))
    }

    /// A turn can start where the spool has no audio at all — its last
    /// sample, or past it. That is not audio the diarizer missed: nothing
    /// was skipped there.
    func testPastTheEndOfTheSpoolNothingWasSkipped() {
        var pieces = SpeakerPieces(length: 1_000)
        _ = pieces.spool(1_500)
        let last = pieces.close()
        pieces.heard(last[0])

        XCTAssertFalse(pieces.wasSkipped(at: 1_500))
        XCTAssertFalse(pieces.wasSkipped(at: 9_000))
    }
}
