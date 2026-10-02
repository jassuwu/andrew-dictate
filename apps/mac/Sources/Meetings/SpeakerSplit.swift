import Foundation
import os

/// One meeting's far side on its way to the speaker split. It is handed
/// over as it is spooled, cut into pieces (`SpeakerPieces`), and each piece
/// is heard off the main actor, at low priority, while the meeting records:
/// the stop has only the tail left to hear, and an hour of the far side is
/// never in memory at once.
///
/// Nothing here can hold up the recording. Handing audio over is an append;
/// a piece that throws gets its second try at the stop; and a stop that has
/// waited `patience` for the last pieces writes the file without them, their
/// turns plain `them`, rather than wait on a diarizer that has stopped
/// answering.
@MainActor
final class SpeakerSplit {
    /// What the split did at the stop, for the meeting's record.
    struct Report: Equatable, Sendable {
        /// From the stop to the last piece heard: the split's part of the
        /// wait for the file.
        var tail: Duration
        /// Pieces whose speakers are not in the file.
        var skipped: Int
    }

    /// How long a stop waits for the last pieces. They take a second or two
    /// (ticket 23's bench); this is for a diarizer that never answers.
    static let patience = Duration.seconds(10)

    private let hearing: (any SpeakerHearing)?
    private var pieces: SpeakerPieces
    /// Far side spooled since the last piece was cut: the next piece, as it
    /// fills.
    private var filling: [Float] = []
    /// The audio of the piece held for its second try at the stop.
    private var held: [Float]?
    /// The piece handed over last. Each waits for the one before it, so the
    /// diarizer hears the meeting in order, one piece at a time.
    private var last: Task<Void, Never>?
    private var outstanding = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var closedAt: ContinuousClock.Instant?
    private var allHeardAt: ContinuousClock.Instant?
    private let patience: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private let logger = Logger(subsystem: AppIdentity.loggingSubsystem, category: "diarizer")

    /// With no hearing — the diarizer's models are not on this mac — it
    /// keeps nothing and changes nothing.
    init(
        _ hearing: (any SpeakerHearing)?,
        pieces: SpeakerPieces = SpeakerPieces(),
        patience: Duration = SpeakerSplit.patience,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.hearing = hearing
        self.pieces = pieces
        self.patience = patience
        self.now = now
        if hearing != nil {
            filling.reserveCapacity(pieces.length)
        }
    }

    // MARK: - as the meeting records

    /// A chunk just written to the spool: its far side, as much of it as
    /// the spool kept — `SpoolAudioFile.append` writes as many frames as
    /// both sides have — so this clock and the spool's are one. An append,
    /// and every few minutes a piece sent off; it never waits.
    func hear(_ chunk: MeetingAudioChunk) {
        hear(chunk.them.prefix(min(chunk.you.count, chunk.them.count)))
    }

    private func hear(_ them: ArraySlice<Float>) {
        guard hearing != nil, !pieces.isClosed else { return }
        var rest = them
        while !rest.isEmpty {
            // a piece that ends inside this chunk is cut where it ends, and
            // the rest of the chunk begins the next.
            let take = rest.prefix(pieces.length - filling.count)
            filling.append(contentsOf: take)
            rest = rest.dropFirst(take.count)
            for piece in pieces.spool(take.count) {
                send(piece, filling, priority: .background)
                filling = []
                filling.reserveCapacity(pieces.length)
            }
        }
    }

    /// A whole spool nothing heard as it was recorded — one a crash left —
    /// read a piece at a time, each heard before the next is read: the disk
    /// is far quicker than the diarizer, and reading ahead would have the
    /// whole far side waiting in memory.
    func hear(spool url: URL) async {
        guard hearing != nil, !pieces.isClosed else { return }
        let length = pieces.length
        let reading = Task.detached(priority: .utility) { [self] in
            guard let farSide = try? SpoolAudioFile.FarSide(url) else { return }
            while let them = try? farSide.next(length), !them.isEmpty {
                await hear(them[...])
                await caughtUp()
            }
        }
        await reading.value
    }

    // MARK: - the stop

    /// No more audio is coming. The piece held for a second try and the
    /// tail go to the diarizer now, ahead of anyone waiting for the file,
    /// and the stop's clock starts.
    func close() {
        guard hearing != nil, closedAt == nil else { return }
        closedAt = now()
        for piece in pieces.close() {
            if piece.isRetry {
                send(piece, held ?? [], priority: .userInitiated)
                held = nil
            } else {
                send(piece, filling, priority: .userInitiated)
                filling = []
            }
        }
        if outstanding == 0 {
            allHeardAt = closedAt
        }
    }

    /// The turns, on the spool's clock, with the speakers heard: once every
    /// piece has been, or once the split has had its patience since the
    /// stop. A turn that starts in audio never heard keeps plain `them`, and
    /// the numbers are 1, 2, 3 by first appearance, with no holes.
    func split(_ turns: [MeetingTurn]) async -> (turns: [MeetingTurn], report: Report?) {
        guard let hearing else { return (turns, nil) }
        close()
        await allHeard()
        let closedAt = closedAt ?? now()
        let report = Report(tail: (allHeardAt ?? now()) - closedAt, skipped: pieces.skipped)
        let found = await hearing.split(turns)
        guard found.count == turns.count else { return (turns, report) }
        let heard = zip(turns, found).map { turn, found in
            guard case .them = turn.speaker,
                  !pieces.wasSkipped(at: StretchCutter.samples(in: turn.at))
            else { return turn }
            return turn.said(by: found.speaker)
        }
        return (SpeakerTurns.numbered(heard), report)
    }

    // MARK: - the pieces

    private func send(_ piece: SpeakerPieces.Piece, _ audio: [Float], priority: TaskPriority) {
        guard let hearing else { return }
        outstanding += 1
        allHeardAt = nil
        let before = last
        last = Task.detached(priority: priority) { [weak self] in
            await before?.value
            let at = StretchCutter.duration(of: piece.frames.lowerBound)
            var failure: (any Error)?
            do {
                try await hearing.hear(audio, at: at)
            } catch {
                failure = error
            }
            await self?.done(piece, audio: failure == nil ? nil : audio, failure: failure)
        }
    }

    private func done(_ piece: SpeakerPieces.Piece, audio: [Float]?, failure: (any Error)?) {
        outstanding -= 1
        if let failure {
            logger.error("a piece of the far side was not split: \(failure.localizedDescription, privacy: .public)")
            switch pieces.failed(piece) {
            case .now(let again):
                send(again, audio ?? [], priority: .userInitiated)
            case .atStop:
                held = audio
            case .never:
                break
            }
        } else {
            pieces.heard(piece)
        }
        if outstanding == 0 {
            allHeardAt = now()
            wake()
        }
    }

    /// Until nothing is out with the diarizer.
    private func caughtUp() async {
        guard outstanding > 0 else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Until nothing is out with the diarizer, or the patience since the
    /// stop has run out.
    private func allHeard() async {
        guard outstanding > 0 else { return }
        let left = patience - (now() - (closedAt ?? now()))
        let giveUp = Task { [weak self] in
            do {
                try await Task.sleep(for: left)
            } catch {
                return
            }
            self?.wake()
        }
        await withCheckedContinuation { waiting.append($0) }
        giveUp.cancel()
    }

    private func wake() {
        let woken = waiting
        waiting = []
        for continuation in woken {
            continuation.resume()
        }
    }
}
