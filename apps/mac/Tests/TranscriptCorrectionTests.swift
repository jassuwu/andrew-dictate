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
    ///
    /// The guarantee only holds because the dictionary reads what the engine
    /// heard. A transcript carrying a number word, a spoken email or spoken
    /// punctuation used to have those parsed away before the dictionary
    /// looked at it, so an entry pointing at "seven" silently never fired
    /// again — and cleanup off and cleanup on disagreed about which entries
    /// worked.
    func testAnEntryBuiltFromASpanAlwaysFiresOnThatTranscript() {
        let transcripts = [
            raw,
            "call seven about the deploy",
            "the total is twenty five percent comma email jason at gmail dot com",
        ]

        for transcript in transcripts {
            let correction = TranscriptCorrection(transcript: transcript)
            // every word, and every adjacent pair — the two things a click
            // and a second click can produce.
            var selections = correction.spans.indices.map { ($0, $0) }
            selections += correction.spans.indices
                .dropLast()
                .map { ($0, $0 + 1) }

            for (first, last) in selections {
                let entry = try! XCTUnwrap(
                    correction.entry(from: first, through: last, right: "MARKER")
                )

                for fullCleanup in [true, false] {
                    let cleaned = DeterministicCleaner(
                        entries: [entry],
                        fullCleanup: fullCleanup
                    ).clean(transcript)

                    XCTAssertTrue(
                        cleaned.contains("MARKER"),
                        """
                        \"\(entry.wrong)\" produced an entry that never \
                        fired with cleanup \(fullCleanup ? "on" : "off"): \
                        \(cleaned)
                        """
                    )
                }
            }
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
