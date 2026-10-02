import Foundation

/// what the follower may ask of the field it follows, and nothing wider:
/// no "the whole value", only a range at a time.
@MainActor
protocol SpanReader: AnyObject {
    /// where the caret is, in utf-16 units.
    func caretLocation() -> Int?
    /// how long the field is, in utf-16 units.
    func characterCount() -> Int?
    /// the text in one range.
    func text(in range: NSRange) -> String?
}

/// our words in one field, followed from read to read: has the paste
/// landed, where are they now, and what do they read as. pure — the reads
/// come from whatever `SpanReader` it is handed; `AXSpanWatcher` decides
/// when to ask.
///
/// every read is our span and a margin either side, and is dropped once
/// our words are found in it (`SpanLocator`). nothing outside them is kept
/// from one read to the next — only where they start.
struct SpanFollower {
    /// enough to find our words again after a correction or a few words typed in
    /// front of them; too little to read the document around them.
    static let margin = 40

    let inserted: String

    /// where our text starts in the field, once it has landed.
    private(set) var start: Int?

    /// our text from its first word to its last, and where that begins in
    /// it: the shape every later read comes back in.
    private let core: SpanLocator.Located
    private let length: Int

    enum Reading: Equatable, Sendable {
        /// the ⌘V hasn't reached the field yet, or the field changed it.
        case notLanded
        /// our words, first to last, as they read now.
        case reads(String)
        /// our words aren't there any more.
        case gone
    }

    init(inserted: String) {
        self.inserted = inserted
        length = (inserted as NSString).length
        core = SpanLocator.locate(
            inserted,
            in: inserted,
            expectedStart: 0,
            reachesFieldEnd: true
        ) ?? .init(text: inserted, start: 0)
    }

    @MainActor
    mutating func read(_ reader: some SpanReader) -> Reading {
        guard let start else {
            return land(reader)
        }

        guard let count = reader.characterCount() else {
            return .gone
        }
        let lower = max(0, start - Self.margin)
        let upper = min(count, start + length + Self.margin)
        guard upper > lower,
              let window = reader.text(
                in: NSRange(location: lower, length: upper - lower)
              ),
              let located = SpanLocator.locate(
                inserted,
                in: window,
                expectedStart: start - lower,
                reachesFieldEnd: upper == count
              ) else {
            return .gone
        }
        // words typed in front of ours move them; the next read is bounded
        // around where they are now, not where they were.
        self.start = lower + located.start - core.start
        return .reads(located.text)
    }

    /// the paste has landed when the text just behind the caret is ours —
    /// checked by reading exactly that much and no more. read after the
    /// paste rather than before it, so the ⌘V's path pays no AX round trip.
    @MainActor
    private mutating func land(_ reader: some SpanReader) -> Reading {
        guard let caret = reader.caretLocation(),
              caret >= length,
              reader.text(
                in: NSRange(location: caret - length, length: length)
              ) == inserted else {
            return .notLanded
        }
        start = caret - length
        return .reads(core.text)
    }
}
