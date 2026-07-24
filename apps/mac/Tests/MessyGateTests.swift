import XCTest

final class MessyGateTests: XCTestCase {
    private let gate = MessyGate()

    func testCleanShortUtteranceSkipsPolish() {
        XCTAssertFalse(
            gate.shouldPolish(
                "Ship this today.",
                rawHadCorrections: false,
                rawHadDuplicates: false
            )
        )
    }

    func testRawCorrectionEvidenceRequestsPolish() {
        XCTAssertTrue(
            gate.shouldPolish(
                "Ship it Monday.",
                rawHadCorrections: true,
                rawHadDuplicates: false
            )
        )
    }

    func testRawDuplicateEvidenceRequestsPolish() {
        XCTAssertTrue(
            gate.shouldPolish(
                "We should ship.",
                rawHadCorrections: false,
                rawHadDuplicates: true
            )
        )
    }

    func testUtteranceAboveLengthThresholdRequestsPolish() {
        let text = (1...25).map { "word\($0)" }.joined(separator: " ")
        XCTAssertTrue(
            gate.shouldPolish(
                text,
                rawHadCorrections: false,
                rawHadDuplicates: false
            )
        )
    }

    func testUtteranceAtLengthThresholdSkipsPolish() {
        let text = Array(
            repeating: "ordinary",
            count: MessyGate.lengthThreshold
        ).joined(separator: " ")
        XCTAssertFalse(
            gate.shouldPolish(
                text,
                rawHadCorrections: false,
                rawHadDuplicates: false
            )
        )
    }

    func testHighUnknownTokenDensityRequestsPolish() {
        XCTAssertTrue(
            gate.shouldPolish(
                "zxqv blrrt qqq ship today.",
                rawHadCorrections: false,
                rawHadDuplicates: false
            )
        )
    }

    func testLowUnknownTokenDensitySkipsPolish() {
        XCTAssertFalse(
            gate.shouldPolish(
                "zxqv please ship this ordinary report today.",
                rawHadCorrections: false,
                rawHadDuplicates: false
            )
        )
    }

    func testDictionaryTermsDoNotCountAsUnknown() {
        XCTAssertFalse(
            gate.shouldPolish(
                "zxqv blrrt qqq works.",
                rawHadCorrections: false,
                rawHadDuplicates: false,
                dictionaryTerms: ["zxqv", "blrrt", "qqq"]
            )
        )
    }

    func testStructuredTokensDoNotCountAsUnknown() {
        XCTAssertFalse(
            gate.shouldPolish(
                "Email john@cypher.io about 500 today.",
                rawHadCorrections: false,
                rawHadDuplicates: false
            )
        )
    }

    func testTinyUtteranceDoesNotTripDensityHeuristic() {
        XCTAssertFalse(
            gate.shouldPolish(
                "zxqv now.",
                rawHadCorrections: false,
                rawHadDuplicates: false
            )
        )
    }

    func testCorrectionMarkerDetectionTable() {
        let cases = [
            "actually",
            "sorry",
            "i mean",
            "no wait",
            "rather",
            "make that",
            "scratch that",
        ]
        for marker in cases {
            XCTAssertTrue(
                SelfCorrections.containsMarker(
                    in: "send friday \(marker) monday"
                ),
                "marker: \(marker)"
            )
        }
        XCTAssertFalse(
            SelfCorrections.containsMarker(in: "send friday")
        )
    }

    func testDuplicateDetectionTable() {
        let duplicates = [
            "we should we should ship",
            "go go",
            "please send please send",
            "THIS this",
        ]
        for input in duplicates {
            XCTAssertTrue(
                RepetitionCollapse.containsImmediateDuplicate(
                    in: input
                ),
                "input: \(input)"
            )
        }

        let clean = [
            "we should ship",
            "very, very",
            "go. go",
            "words differ",
        ]
        for input in clean {
            XCTAssertFalse(
                RepetitionCollapse.containsImmediateDuplicate(
                    in: input
                ),
                "input: \(input)"
            )
        }
    }
}
