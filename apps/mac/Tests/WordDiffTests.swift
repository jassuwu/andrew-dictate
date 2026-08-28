import XCTest

final class WordDiffTests: XCTestCase {
    func testIdenticalTextIsAllSame() {
        let tokens = WordDiff.diff("send the invoice", "send the invoice")
        XCTAssertEqual(tokens.map(\.change), [.same, .same, .same])
    }

    func testAnInsertedWordIsAdded() {
        let tokens = WordDiff.diff("send invoice", "send the invoice")
        XCTAssertEqual(
            tokens,
            [
                .init(text: "send", change: .same),
                .init(text: "the", change: .added),
                .init(text: "invoice", change: .same),
            ]
        )
    }

    func testADroppedWordIsRemoved() {
        let tokens = WordDiff.diff("um send it", "send it")
        XCTAssertEqual(tokens.first, .init(text: "um", change: .removed))
        XCTAssertEqual(tokens.dropFirst().map(\.change), [.same, .same])
    }

    /// a replacement reads as the old word going, then the new one coming —
    /// never the other way round, or the diff reads backwards.
    func testAReplacementRemovesThenAdds() {
        let tokens = WordDiff.diff("by friday", "by Friday.")
        XCTAssertEqual(
            tokens,
            [
                .init(text: "by", change: .same),
                .init(text: "friday", change: .removed),
                .init(text: "Friday.", change: .added),
            ]
        )
    }

    func testEmptySidesAreAllOneChange() {
        XCTAssertEqual(
            WordDiff.diff("", "hi there").map(\.change),
            [.added, .added]
        )
        XCTAssertEqual(
            WordDiff.diff("hi there", "").map(\.change),
            [.removed, .removed]
        )
    }

    func testNewlinesSplitWordsLikeSpaces() {
        XCTAssertEqual(WordDiff.words("a\nb  c"), ["a", "b", "c"])
    }
}
