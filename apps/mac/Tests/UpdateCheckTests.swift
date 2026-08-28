import XCTest

final class UpdateCheckTests: XCTestCase {
    func testANewerTagIsNewer() {
        XCTAssertTrue(UpdateCheck.isNewer(tag: "v0.8.0", than: "0.7.1"))
        XCTAssertTrue(UpdateCheck.isNewer(tag: "1.0.0", than: "0.9.9"))
    }

    func testTheSameVersionIsNotNewer() {
        XCTAssertFalse(UpdateCheck.isNewer(tag: "v0.7.1", than: "0.7.1"))
    }

    func testAnOlderTagIsNotNewer() {
        XCTAssertFalse(UpdateCheck.isNewer(tag: "v0.7.0", than: "0.7.1"))
    }

    /// numeric, not lexicographic: "10" beats "9".
    func testDoubleDigitComponentsCompareNumerically() {
        XCTAssertTrue(UpdateCheck.isNewer(tag: "v0.7.10", than: "0.7.9"))
        XCTAssertTrue(UpdateCheck.isNewer(tag: "v0.10.0", than: "0.9.9"))
    }

    /// a missing component is a zero, not a mismatch.
    func testShorterTagsPadWithZeros() {
        XCTAssertTrue(UpdateCheck.isNewer(tag: "v0.8", than: "0.7.1"))
        XCTAssertFalse(UpdateCheck.isNewer(tag: "v0.7", than: "0.7.0"))
    }

    /// a garbage response must never produce an upgrade prompt.
    func testUnparseableTagsAreNeverNewer() {
        XCTAssertFalse(UpdateCheck.isNewer(tag: "latest", than: "0.7.1"))
        XCTAssertFalse(UpdateCheck.isNewer(tag: "v0.8.beta", than: "0.7.1"))
        XCTAssertFalse(UpdateCheck.isNewer(tag: "", than: "0.7.1"))
        XCTAssertFalse(
            UpdateCheck.isNewer(tag: "v0.8.0", than: "development")
        )
    }
}
