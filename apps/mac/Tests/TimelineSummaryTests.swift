import XCTest

final class TimelineSummaryTests: XCTestCase {
    /// Every timeline here lands on `keyUp` at t+0 so the durations under
    /// test read directly off the millisecond offsets.
    private func timeline(
        keyUpToCompletion ms: Int,
        transcription: Int = 0,
        cleanup: Int = 0,
        stage: UtteranceTimeline.CompletionStage = .pasteVerified
    ) -> UtteranceTimeline {
        let keyUp = ContinuousClock.now
        return UtteranceTimeline(
            keyDown: keyUp,
            micFirstBuffer: keyUp,
            keyUp: keyUp,
            transcriptReady: keyUp.advanced(by: .milliseconds(transcription)),
            cleaned: keyUp.advanced(by: .milliseconds(transcription + cleanup)),
            completionStage: stage,
            completed: keyUp.advanced(by: .milliseconds(ms))
        )
    }

    // MARK: - the population

    func testOnlyVerifiedPastesCountTowardsTheNumbers() {
        let summary = TimelineSummary(timelines: [
            timeline(keyUpToCompletion: 100),
            timeline(keyUpToCompletion: 900, stage: .cancelled),
            timeline(keyUpToCompletion: 900, stage: .leftOnPasteboard),
        ])

        XCTAssertEqual(summary.sampleSize, 1)
        XCTAssertEqual(summary.keyUpToCompletion?.p50, .milliseconds(100))
    }

    func testExcludedUtterancesAreCountedByReasonRatherThanDiscarded() {
        let summary = TimelineSummary(timelines: [
            timeline(keyUpToCompletion: 100),
            timeline(keyUpToCompletion: 900, stage: .cancelled),
            timeline(keyUpToCompletion: 800, stage: .leftOnPasteboard),
            timeline(keyUpToCompletion: 700, stage: .leftOnPasteboard),
        ])

        XCTAssertEqual(summary.excluded[.cancelled], 1)
        XCTAssertEqual(summary.excluded[.leftOnPasteboard], 2)
        XCTAssertNil(summary.excluded[.pasteVerified])
    }

    func testAnEmptySampleReportsNothingRatherThanZero() {
        let summary = TimelineSummary(timelines: [])

        XCTAssertEqual(summary.sampleSize, 0)
        XCTAssertNil(summary.keyUpToCompletion)
        XCTAssertNil(summary.transcription)
    }

    func testASampleOfOnlyCancelledUtterancesIsAnEmptySample() {
        let summary = TimelineSummary(timelines: [
            timeline(keyUpToCompletion: 100, stage: .cancelled)
        ])

        XCTAssertEqual(summary.sampleSize, 0)
        XCTAssertNil(summary.keyUpToCompletion)
    }

    // MARK: - the percentiles

    /// Nearest-rank: the p-th percentile is the `ceil(p/100 * n)`-th smallest
    /// observation. No interpolation, so every number printed is a number that
    /// was actually measured.
    func testPercentilesAreNearestRankAndNeverInterpolate() {
        let summary = TimelineSummary(
            timelines: (1...10).map {
                timeline(keyUpToCompletion: $0 * 100)
            }
        )

        XCTAssertEqual(summary.sampleSize, 10)
        // ceil(0.50 * 10) = 5th smallest = 500ms
        XCTAssertEqual(summary.keyUpToCompletion?.p50, .milliseconds(500))
        // ceil(0.95 * 10) = 10th smallest = 1000ms
        XCTAssertEqual(summary.keyUpToCompletion?.p95, .milliseconds(1_000))
    }

    func testPercentilesDoNotDependOnArrivalOrder() {
        let ascending = TimelineSummary(
            timelines: (1...10).map { timeline(keyUpToCompletion: $0 * 100) }
        )
        let descending = TimelineSummary(
            timelines: (1...10).reversed().map {
                timeline(keyUpToCompletion: $0 * 100)
            }
        )

        XCTAssertEqual(ascending.keyUpToCompletion, descending.keyUpToCompletion)
    }

    func testASingleObservationIsItsOwnMedianAndTail() {
        let summary = TimelineSummary(
            timelines: [timeline(keyUpToCompletion: 420)]
        )

        XCTAssertEqual(summary.keyUpToCompletion?.p50, .milliseconds(420))
        XCTAssertEqual(summary.keyUpToCompletion?.p95, .milliseconds(420))
        XCTAssertEqual(summary.keyUpToCompletion?.max, .milliseconds(420))
    }

    /// The tail is the honest part of the claim, and on a small sample p95 is
    /// simply the slowest thing that happened. Reporting max beside it makes
    /// that visible instead of dressing a maximum up as a percentile.
    func testMaxIsReportedSoASmallSampleCannotHideBehindP95() {
        let summary = TimelineSummary(
            timelines: [
                timeline(keyUpToCompletion: 100),
                timeline(keyUpToCompletion: 200),
                timeline(keyUpToCompletion: 3_000),
            ]
        )

        XCTAssertEqual(summary.keyUpToCompletion?.p95, .milliseconds(3_000))
        XCTAssertEqual(summary.keyUpToCompletion?.max, .milliseconds(3_000))
    }

    // MARK: - the decomposition

    func testEachStageAfterKeyUpIsSummarisedSeparately() {
        let summary = TimelineSummary(timelines: [
            timeline(
                keyUpToCompletion: 450,
                transcription: 200,
                cleanup: 5
            )
        ])

        XCTAssertEqual(summary.transcription?.p50, .milliseconds(200))
        XCTAssertEqual(summary.cleanup?.p50, .milliseconds(5))
        XCTAssertEqual(summary.delivery?.p50, .milliseconds(245))
    }
}

final class TimelineSummaryFormattingTests: XCTestCase {
    private func timeline(
        keyUpToCompletion ms: Int,
        stage: UtteranceTimeline.CompletionStage = .pasteVerified
    ) -> UtteranceTimeline {
        let keyUp = ContinuousClock.now
        return UtteranceTimeline(
            keyDown: keyUp,
            micFirstBuffer: keyUp,
            keyUp: keyUp,
            transcriptReady: keyUp.advanced(by: .milliseconds(ms / 2)),
            cleaned: keyUp.advanced(by: .milliseconds(ms / 2)),
            completionStage: stage,
            completed: keyUp.advanced(by: .milliseconds(ms))
        )
    }

    func testTheSampleSizeIsAlwaysPrintedBesideTheNumbers() {
        let text = TimelineSummary(
            timelines: (1...4).map { timeline(keyUpToCompletion: $0 * 100) }
        ).formatted()

        XCTAssertTrue(text.contains("n=4"), text)
        XCTAssertTrue(text.contains("key-up → inserted"), text)
    }

    func testExclusionsAreNamedRatherThanSilentlyDropped() {
        let text = TimelineSummary(timelines: [
            timeline(keyUpToCompletion: 100),
            timeline(keyUpToCompletion: 100, stage: .cancelled),
            timeline(keyUpToCompletion: 100, stage: .leftOnPasteboard),
        ]).formatted()

        XCTAssertTrue(text.contains("cancelled"), text)
        XCTAssertTrue(text.contains("left on pasteboard"), text)
    }

    func testNothingIsExcludedIsStatedExplicitly() {
        let text = TimelineSummary(
            timelines: [timeline(keyUpToCompletion: 100)]
        ).formatted()

        XCTAssertTrue(text.contains("nothing excluded"), text)
    }

    /// An empty sample must not render as a row of zeroes — a zero-millisecond
    /// median is the single most flattering number this could ever print.
    func testAnEmptySampleSaysSoInsteadOfPrintingZeroes() {
        let text = TimelineSummary(timelines: []).formatted()

        XCTAssertFalse(text.contains("p50"), text)
        XCTAssertTrue(text.lowercased().contains("no verified"), text)
    }

    /// Caught in review: the empty-sample sentence was concatenated straight
    /// onto the conditions line, producing "…summarise.n=0 verified pastes".
    func testTheEmptySampleSentenceDoesNotRunIntoTheConditionsLine() {
        let lines = TimelineSummary(timelines: [])
            .formatted()
            .split(separator: "\n")

        XCTAssertEqual(lines.count, 2, "expected sentence and conditions")
        XCTAssertTrue(lines[0].hasSuffix("summarise."), String(lines[0]))
        XCTAssertTrue(lines[1].hasPrefix("n=0"), String(lines[1]))
    }
}
