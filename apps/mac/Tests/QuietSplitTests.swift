import XCTest

/// A take too long for the model, cut at its quietest moment before the
/// limit, every sample kept.
final class QuietSplitTests: XCTestCase {
    private let rate = QuietSplit.sampleRate

    private func tone(_ seconds: Double) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { Float(sin(Double($0) * 0.1)) * 0.5 }
    }

    private func silence(_ seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * Double(rate)))
    }

    func testATakeThatFitsIsOnePieceUntouched() {
        let take = tone(12)

        XCTAssertEqual(QuietSplit.pieces(of: take, longest: .seconds(25)), [take])
    }

    func testALongTakeIsCutInTheGapBeforeTheLimit() {
        // talk, a 0.4 s pause at 21 s, more talk past the 25 s limit.
        let take = tone(21) + silence(0.4) + tone(10)

        let pieces = QuietSplit.pieces(of: take, longest: .seconds(25))

        XCTAssertEqual(pieces.count, 2)
        let cut = Double(pieces[0].count) / Double(rate)
        XCTAssertGreaterThan(cut, 21.0)
        XCTAssertLessThan(cut, 21.4)
    }

    func testEverySampleIsKeptInOrder() {
        let take = tone(21) + silence(0.4) + tone(30) + silence(0.3) + tone(8)

        let pieces = QuietSplit.pieces(of: take, longest: .seconds(25))

        XCTAssertEqual(Array(pieces.joined()), take)
        XCTAssertTrue(pieces.allSatisfy { $0.count <= 25 * rate })
    }

    /// no quiet anywhere: the cut goes at the limit rather than anywhere
    /// shorter, and nothing is longer than the model reads.
    func testTalkWithNoPauseIsCutNoLaterThanTheLimit() {
        let take = tone(60)

        let pieces = QuietSplit.pieces(of: take, longest: .seconds(25))

        XCTAssertTrue(pieces.allSatisfy { $0.count <= 25 * rate })
        XCTAssertEqual(pieces.map(\.count).reduce(0, +), take.count)
    }
}
