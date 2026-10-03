import XCTest

/// One meeting's far side on its way to the diarizer: handed over as it is
/// spooled, heard a piece at a time while the meeting records, and only the
/// tail left for the stop. The diarizer here is a fake that says what it was
/// handed and when, and can throw or take its time.
@MainActor
final class SpeakerSplitTests: XCTestCase {
    /// Pieces of 1 000 samples: the far side is handed over in 300-sample
    /// chunks, and each piece goes to the diarizer once all of it has been
    /// spooled, stamped where it starts on the spool — the stop has not come.
    func testTheFarSideIsHeardAPieceAtATimeAsItIsSpooled() async {
        let hearing = FakeHearing()
        let split = SpeakerSplit(hearing, pieces: SpeakerPieces(length: 1_000))

        spool(2_700, into: split)
        await hearing.heard(2)

        XCTAssertEqual(hearing.pieces, [
            .init(at: StretchCutter.duration(of: 0), samples: 0..<1_000),
            .init(at: StretchCutter.duration(of: 1_000), samples: 1_000..<2_000),
        ])
    }

    /// At the stop only the tail is left: the diarizer is handed what came
    /// after the last piece, and nothing it heard before. Then the turns get
    /// their speakers, numbered from 1.
    func testTheStopHearsOnlyTheTail() async {
        let hearing = FakeHearing()
        hearing.speak([(from: .zero, number: 4), (from: at(1_200), number: 2)])
        let split = SpeakerSplit(hearing, pieces: SpeakerPieces(length: 1_000))
        spool(2_700, into: split)
        await hearing.heard(2)

        let (turns, report) = await split.split([them(500), them(1_500), them(2_600)])

        XCTAssertEqual(hearing.pieces.dropFirst(2), [.init(at: at(2_000), samples: 2_000..<2_700)])
        XCTAssertEqual(turns.map(\.speaker.label), ["them 1", "them 2", "them 2"])
        XCTAssertEqual(report?.skipped, 0)
    }

    /// The diarizer throws on the first piece while the meeting runs. The
    /// meeting goes on; the piece is tried again at the stop, before the
    /// tail, and its turns get their speakers like any other.
    func testAPieceThatFailsIsTriedAgainAtTheStop() async {
        let hearing = FakeHearing()
        hearing.fail(at: at(0))
        hearing.speak([(from: .zero, number: 1), (from: at(1_200), number: 2)])
        let split = SpeakerSplit(hearing, pieces: SpeakerPieces(length: 1_000))
        spool(2_500, into: split)
        await hearing.heard(2)

        let (turns, report) = await split.split([them(500), them(1_500)])

        XCTAssertEqual(hearing.pieces.map(\.samples), [0..<1_000, 1_000..<2_000, 0..<1_000, 2_000..<2_500])
        XCTAssertEqual(turns.map(\.speaker.label), ["them 1", "them 2"])
        XCTAssertEqual(report?.skipped, 0)
    }

    /// It throws on the first piece twice. Its turns are plain `them` — a
    /// neighbour's number would be a guess — and the voices that are left
    /// are numbered from 1, with no hole where the lost piece's was.
    func testAPieceThatFailsTwiceLeavesItsTurnsPlainAndNoHoleInTheNumbers() async {
        let hearing = FakeHearing()
        hearing.fail(at: at(0), times: 2)
        hearing.speak([(from: .zero, number: 1), (from: at(1_200), number: 2), (from: at(2_200), number: 3)])
        let split = SpeakerSplit(hearing, pieces: SpeakerPieces(length: 1_000))
        spool(2_500, into: split)
        await hearing.heard(2)

        let (turns, report) = await split.split([them(500), them(1_500), them(2_300)])

        XCTAssertEqual(turns.map(\.speaker.label), ["them", "them 1", "them 2"])
        XCTAssertEqual(report?.skipped, 1)
    }

    /// The diarizer never comes back from the tail. The stop waits its
    /// patience and no longer: the turns in what was heard get speakers, the
    /// tail's stay plain, and the tail counts as skipped.
    func testAStopWaitsItsPatienceAndNoLonger() async {
        let hearing = FakeHearing()
        hearing.hold(at: at(1_000))
        hearing.speak([(from: .zero, number: 1), (from: at(1_000), number: 2)])
        let split = SpeakerSplit(
            hearing, pieces: SpeakerPieces(length: 1_000), patience: .milliseconds(200))
        spool(1_400, into: split)
        await hearing.heard(1)

        let started = ContinuousClock.now
        let (turns, report) = await split.split([them(500), them(1_200)])

        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
        XCTAssertEqual(turns.map(\.speaker.label), ["them 1", "them"])
        XCTAssertEqual(report?.skipped, 1)
        hearing.release()
    }

    /// The diarizer is stuck on the first piece while the meeting goes on.
    /// `mostWaiting` pieces wait behind it and no more: the next ones are
    /// let go, so a diarizer that cannot keep up costs their turns a number
    /// and not the meeting its memory, nor the stop a backlog.
    func testWhileTheDiarizerIsStuckOnlySoManyPiecesWaitAndTheRestAreLetGo() async {
        let waiting = SpeakerSplit.mostWaiting
        let hearing = FakeHearing()
        hearing.hold(at: at(0))
        hearing.speak([(from: .zero, number: 1), (from: at(waiting * 1_000), number: 2)])
        let split = SpeakerSplit(hearing, pieces: SpeakerPieces(length: 1_000))
        spool((waiting + 3) * 1_000, into: split)
        await hearing.heard(1)
        hearing.release()

        let (turns, report) = await split.split([
            them(500),
            them(waiting * 1_000 + 500),
            them((waiting + 1) * 1_000 + 500),
            them((waiting + 2) * 1_000 + 500),
        ])

        XCTAssertEqual(hearing.pieces.map(\.samples), (0...waiting).map { $0 * 1_000..<($0 + 1) * 1_000 })
        XCTAssertEqual(turns.map(\.speaker.label), ["them 1", "them 2", "them", "them"])
        XCTAssertEqual(report?.skipped, 2)
    }

    /// No hearing — the diarizer's models are not on this mac: nothing is
    /// kept, nothing is handed over, the turns are as they were and there is
    /// nothing for the record.
    func testWithNoHearingNothingIsKeptAndTheTurnsAreAsTheyWere() async {
        let split = SpeakerSplit(nil, pieces: SpeakerPieces(length: 1_000))
        spool(2_500, into: split)
        let turns = [them(500), them(1_500)]

        let (after, report) = await split.split(turns)

        XCTAssertEqual(after, turns)
        XCTAssertNil(report)
    }

    /// A spool nothing heard as it was recorded — one a crash left — is
    /// read a piece at a time and heard in order, each piece the spool's own
    /// far side at its own place on the spool's clock.
    func testASpoolNothingHeardIsHeardAPieceAtATime() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("speaker-split-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("audio.caf")
        let file = try SpoolAudioFile(url: url)
        try await file.append(MeetingAudioChunk(
            you: Array(repeating: 0.5, count: 2_500),
            them: (0..<2_500).map(Float.init),
            at: .zero))
        let hearing = FakeHearing()
        let split = SpeakerSplit(hearing, pieces: SpeakerPieces(length: 1_000))

        await split.hear(spool: url)
        _ = await split.split([])

        XCTAssertEqual(hearing.pieces, [
            .init(at: at(0), samples: 0..<1_000),
            .init(at: at(1_000), samples: 1_000..<2_000),
            .init(at: at(2_000), samples: 2_000..<2_500),
        ])
    }

    // MARK: -

    private func at(_ sample: Int) -> Duration {
        StretchCutter.duration(of: sample)
    }

    private func them(_ sample: Int) -> MeetingTurn {
        MeetingTurn(speaker: .them(nil), at: at(sample), text: "words")
    }

    /// `count` samples of far side, each sample its own index, in chunks of
    /// 300: whatever a piece holds says where it came from.
    private func spool(_ count: Int, from start: Int = 0, into split: SpeakerSplit) {
        var at = start
        while at < start + count {
            let end = min(at + 300, start + count)
            let them = (at..<end).map(Float.init)
            split.hear(MeetingAudioChunk(you: them, them: them, at: StretchCutter.duration(of: at)))
            at = end
        }
    }
}

// MARK: - fakes

/// A diarizer's hearing that keeps what it was handed: where each piece
/// started and which samples were in it. Told to, it throws on a piece, or
/// holds one until released. Its split numbers a turn by whichever of
/// `voices` covers it, heard or not — the split around it decides what
/// keeps a number.
private final class FakeHearing: SpeakerHearing, @unchecked Sendable {
    struct Piece: Equatable {
        let at: Duration
        let samples: Range<Int>
    }

    private let lock = NSLock()
    private var _pieces: [Piece] = []
    private var failures: [Duration: Int] = [:]
    private var voices: [(from: Duration, number: Int)] = []
    private var holding: Duration?
    private var held: CheckedContinuation<Void, Never>?

    var pieces: [Piece] {
        lock.withLock { _pieces }
    }

    /// From each `from` on, a turn is that voice's.
    func speak(_ voices: [(from: Duration, number: Int)]) {
        lock.withLock { self.voices = voices }
    }

    /// The piece at `at` throws, `times` times.
    func fail(at: Duration, times: Int = 1) {
        lock.withLock { failures[at] = times }
    }

    /// The piece at `at` is not answered until `release`.
    func hold(at: Duration) {
        lock.withLock { holding = at }
    }

    func release() {
        lock.withLock {
            holding = nil
            defer { held = nil }
            return held
        }?.resume()
    }

    func hear(_ piece: [Float], at: Duration) async throws {
        let first = piece.first.map(Int.init) ?? 0
        let (thrown, holds) = lock.withLock { () -> (Bool, Bool) in
            _pieces.append(Piece(at: at, samples: first..<first + piece.count))
            guard let left = failures[at], left > 0 else { return (false, holding == at) }
            failures[at] = left - 1
            return (true, false)
        }
        if holds {
            // the hold is checked in the same lock that registers the
            // wait, so a release cannot slip in between.
            await withCheckedContinuation { continuation in
                let goNow = lock.withLock { () -> Bool in
                    guard holding == at else { return true }
                    held = continuation
                    return false
                }
                if goNow {
                    continuation.resume()
                }
            }
        }
        if thrown {
            throw Garbled()
        }
    }

    func split(_ turns: [MeetingTurn]) async -> [MeetingTurn] {
        let voices = lock.withLock { self.voices }
        return turns.map { turn in
            guard case .them = turn.speaker,
                  let voice = voices.last(where: { $0.from <= turn.at })
            else { return turn }
            return turn.said(by: .them(voice.number))
        }
    }

    /// Until `count` pieces have been handed over, or two seconds.
    func heard(_ count: Int) async {
        for _ in 0..<200 {
            if pieces.count >= count { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private struct Garbled: Error {}
}
