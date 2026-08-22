import XCTest

final class TranscriptCorrectionTests: XCTestCase {
    private let raw = "send the jason to cypher d and cc darsh"

    func testEveryWordIsSomethingYouCanPointAt() {
        let correction = TranscriptCorrection(transcript: raw)

        XCTAssertEqual(
            correction.spans.map(\.text),
            ["send", "the", "jason", "to", "cypher", "d", "and", "cc", "darsh"]
        )
    }

    func testPunctuationIsNotPartOfAnythingYouCanPick() {
        let correction = TranscriptCorrection(
            transcript: "hello, jason. bye"
        )

        XCTAssertEqual(correction.spans.map(\.text), ["hello", "jason", "bye"])
    }

    func testAContiguousRunPicksUpTheRealTextBetweenTheWords() {
        let correction = TranscriptCorrection(transcript: raw)

        XCTAssertEqual(correction.phrase(from: 4, through: 5), "cypher d")
    }

    func testASingleWordIsJustThatWord() {
        let correction = TranscriptCorrection(transcript: raw)

        XCTAssertEqual(correction.phrase(from: 2, through: 2), "jason")
    }

    func testAnOutOfOrderOrOutOfRangeSelectionIsRefused() {
        let correction = TranscriptCorrection(transcript: raw)

        XCTAssertNil(correction.phrase(from: 5, through: 4))
        XCTAssertNil(correction.phrase(from: 0, through: 99))
    }

    func testAnEntryNeedsAReplacementToBeWorthMaking() {
        let correction = TranscriptCorrection(transcript: raw)

        XCTAssertNil(correction.entry(from: 2, through: 2, right: "   "))
        XCTAssertNotNil(correction.entry(from: 2, through: 2, right: "JSON"))
    }

    // MARK: - the guarantee hand-typing cannot give you

    /// The whole point of building the entry from the transcript rather than
    /// from memory: it cannot fail to match. Ticket 011 found the current flow
    /// asks the user to reproduce a misspelling they saw once, and an entry
    /// whose `wrong` side is off by a character silently never fires — a
    /// failure that looks exactly like success.
    func testAnEntryBuiltFromASpanAlwaysFiresOnThatTranscript() {
        let correction = TranscriptCorrection(transcript: raw)

        for index in correction.spans.indices {
            let entry = try! XCTUnwrap(
                correction.entry(from: index, through: index, right: "MARKER")
            )
            let cleaned = DeterministicCleaner(entries: [entry]).clean(raw)

            XCTAssertTrue(
                cleaned.contains("MARKER"),
                "span '\(correction.spans[index].text)' produced an entry that never fired"
            )
        }
    }

    func testAMultiWordEntryAlsoFires() {
        let correction = TranscriptCorrection(transcript: raw)
        let entry = try! XCTUnwrap(
            correction.entry(from: 4, through: 5, right: "CypherD")
        )

        XCTAssertEqual(
            DeterministicCleaner(entries: [entry]).clean(raw),
            "Send the jason to CypherD and cc darsh."
        )
    }

    func testFixingSeveralWordsFromOneTranscriptWorksTogether() {
        let correction = TranscriptCorrection(transcript: raw)
        let entries = [
            correction.entry(from: 2, through: 2, right: "JSON"),
            correction.entry(from: 4, through: 5, right: "CypherD"),
            correction.entry(from: 8, through: 8, right: "Darsh"),
        ].compactMap { $0 }

        XCTAssertEqual(
            DeterministicCleaner(entries: entries).clean(raw),
            "Send the JSON to CypherD and cc Darsh."
        )
    }

    func testAWordWithAnApostropheSurvivesIntact() {
        let correction = TranscriptCorrection(transcript: "call jass's api")
        XCTAssertEqual(correction.spans.map(\.text), ["call", "jass's", "api"])

        let entry = try! XCTUnwrap(
            correction.entry(from: 1, through: 1, right: "Jass's")
        )
        XCTAssertEqual(entry.wrong, "jass's")
    }
}
