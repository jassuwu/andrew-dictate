import Foundation

/// Where a meeting's far side is cut for the speaker split, in samples on
/// the spool's clock: a piece every `length` of it, cut the moment the whole
/// piece has been spooled, and at the stop whatever came after the last one,
/// the tail. It keeps the diarizer's word on each piece too, and gives one
/// that failed its second try. Counts only: the audio is `SpeakerSplit`'s.
struct SpeakerPieces: Equatable, Sendable {
    struct Piece: Equatable, Sendable {
        let frames: Range<Int>
        /// Its second try: one that fails again is let go.
        var isRetry = false
    }

    /// What becomes of a piece the diarizer threw on.
    enum Retry: Equatable, Sendable {
        /// The meeting has stopped and there is no later, so: again, now.
        case now(Piece)
        /// Held for the stop, and handed back by `close`.
        case atStop
        /// Let go. Its turns stay plain `them`.
        case never
    }

    /// Five minutes. The diarizer hears that in about a second on an M4
    /// (ticket 23's bench), so a stop has at most about two seconds of it
    /// left: the piece being heard and the tail. A whole number of the
    /// diarizer's own ten-second windows, so the pieces are cut where a
    /// one-pass split would have cut its windows, and hear the same thing.
    static let length = 30 * 160_000

    let length: Int
    /// Far side handed over so far, and how much of it is in pieces.
    private(set) var spooled = 0
    private(set) var cut = 0
    private(set) var isClosed = false
    /// The one failed piece waiting for its second try at the stop.
    private(set) var held: Piece?
    /// Every piece cut, the tail included; a second try is not another.
    private var count = 0
    private var heardPieces: [Range<Int>] = []

    init(length: Int = Self.length) {
        self.length = length
    }

    /// `frames` more of the far side have been spooled. Returns the pieces
    /// that are now whole, in order: usually none, one every few minutes.
    mutating func spool(_ frames: Int) -> [Piece] {
        guard !isClosed else { return [] }
        spooled += frames
        var due: [Piece] = []
        while spooled - cut >= length {
            due.append(Piece(frames: cut..<cut + length))
            cut += length
            count += 1
        }
        return due
    }

    /// The meeting has stopped. Returns what is left to hear, in the order
    /// the meeting had it: the piece held for a second try, then the tail.
    mutating func close() -> [Piece] {
        guard !isClosed else { return [] }
        isClosed = true
        var last: [Piece] = []
        if let held {
            last.append(held)
            self.held = nil
        }
        if spooled > cut {
            last.append(Piece(frames: cut..<spooled))
            cut = spooled
            count += 1
        }
        return last
    }

    /// The diarizer threw on `piece`. A throw is often a hiccup and not the
    /// audio, so a piece gets two tries — the second at the stop, where a
    /// meeting still running cannot be held up by it. One piece waits for
    /// the stop at most: a diarizer that throws on everything must not pile
    /// the meeting up in memory waiting for second tries.
    mutating func failed(_ piece: Piece) -> Retry {
        guard !piece.isRetry else { return .never }
        let again = Piece(frames: piece.frames, isRetry: true)
        if isClosed {
            return .now(again)
        }
        guard held == nil else { return .never }
        held = again
        return .atStop
    }

    mutating func heard(_ piece: Piece) {
        heardPieces.append(piece.frames)
    }

    /// Pieces whose speakers are not in the file: let go after failing, or
    /// still being heard when the stop stopped waiting.
    var skipped: Int {
        count - heardPieces.count
    }

    /// Whether the audio at `frame` was cut into a piece the diarizer never
    /// heard. A turn that starts there keeps plain `them`: no number is
    /// better than a neighbour's.
    func wasSkipped(at frame: Int) -> Bool {
        (0..<cut).contains(frame) && !heardPieces.contains { $0.contains(frame) }
    }
}
