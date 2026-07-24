import XCTest

final class TranscriptPolisherTests: XCTestCase {
    func testSanityGuardRejectsEmptyOutput() {
        XCTAssertEqual(
            TranscriptPolishSanityGuard.acceptedOutput(
                input: "Keep this transcript",
                candidate: " \n ",
                protectedTerms: []
            ),
            "Keep this transcript"
        )
    }

    func testSanityGuardRejectsOutputBelowLengthRatio() {
        XCTAssertEqual(
            TranscriptPolishSanityGuard.acceptedOutput(
                input: "0123456789",
                candidate: "123",
                protectedTerms: []
            ),
            "0123456789"
        )
    }

    func testSanityGuardRejectsOutputAboveLengthRatio() {
        XCTAssertEqual(
            TranscriptPolishSanityGuard.acceptedOutput(
                input: "12345",
                candidate: "123456789",
                protectedTerms: []
            ),
            "12345"
        )
    }

    func testSanityGuardAcceptsInclusiveLengthRatioBounds() {
        XCTAssertEqual(
            TranscriptPolishSanityGuard.acceptedOutput(
                input: "1234567890",
                candidate: "1234",
                protectedTerms: []
            ),
            "1234"
        )
        XCTAssertEqual(
            TranscriptPolishSanityGuard.acceptedOutput(
                input: "12345",
                candidate: "12345678",
                protectedTerms: []
            ),
            "12345678"
        )
    }

    func testSanityGuardRejectsMissingProtectedTermPresentInInput() {
        let input = "Deploy with Swift_STRICT_CONCURRENCY complete"

        XCTAssertEqual(
            TranscriptPolishSanityGuard.acceptedOutput(
                input: input,
                candidate: "Deploy with strict concurrency complete.",
                protectedTerms: ["Swift_STRICT_CONCURRENCY"]
            ),
            input
        )
    }

    func testSanityGuardIgnoresProtectedTermAbsentFromInput() {
        XCTAssertEqual(
            TranscriptPolishSanityGuard.acceptedOutput(
                input: "Deploy this build",
                candidate: "Deploy this build.",
                protectedTerms: ["FoundationModels"]
            ),
            "Deploy this build."
        )
    }

    func testPasteChoiceUsesPolishOnlyWhenSuccessfulAndInBudget() {
        XCTAssertEqual(
            cleanupPasteChoice(
                raw: "raw",
                polishResult: .success("polished"),
                deadline: .met
            ),
            .polished("polished")
        )
        XCTAssertEqual(
            cleanupPasteChoice(
                raw: "raw",
                polishResult: .success("polished"),
                deadline: .exceeded
            ),
            .raw("raw")
        )
        XCTAssertEqual(
            cleanupPasteChoice(
                raw: "raw",
                polishResult: .failure,
                deadline: .met
            ),
            .raw("raw")
        )
    }

    func testPasteChoiceTreatsUnchangedPolishAsRawFallback() {
        XCTAssertEqual(
            cleanupPasteChoice(
                raw: "unchanged",
                polishResult: .success("unchanged"),
                deadline: .met
            ),
            .raw("unchanged")
        )
    }

    func testMockPolisherIsSanityGuardedByDeadlinePipeline() async {
        let polisher = MockPolisher(output: "")
        let result = await polishWithinDeadline(
            "raw transcript",
            protectedTerms: [],
            using: polisher,
            deadline: ContinuousClock.now.advanced(
                by: .seconds(1)
            )
        )

        XCTAssertEqual(
            result,
            TimedPolishResult(
                result: .success("raw transcript"),
                deadline: .met
            )
        )
    }
}

private struct MockPolisher: TranscriptPolisher {
    let output: String

    var isAvailable: Bool {
        true
    }

    func polish(
        _ text: String,
        protectedTerms: [String]
    ) async throws -> String {
        output
    }
}
