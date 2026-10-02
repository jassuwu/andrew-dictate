import XCTest

final class HUDLayoutEngineTests: XCTestCase {
    func testShortTextUsesMinimumSizeAndGlass() {
        let shortText = HUDLayoutEngine.layout(
            for: .text("done"),
            screenWidth: 1_440
        )

        XCTAssertEqual(shortText.size, HUDLayoutEngine.minimumSize)
        XCTAssertEqual(shortText.lineCount, 1)
    }

    func testWaveStatesAreBareAtWaveSize() {
        let wave = HUDLayoutEngine.layout(
            for: .wave,
            screenWidth: 1_440
        )
        let prewarming = HUDLayoutEngine.layout(
            for: .prewarming,
            screenWidth: 1_440
        )

        XCTAssertEqual(wave.size, HUDLayoutEngine.waveSize)
        XCTAssertEqual(prewarming.size, HUDLayoutEngine.waveSize)
    }

    func testGrowingTextGrowsWidthMonotonically() {
        let widths = [20, 30, 40].map { characterCount in
            HUDLayoutEngine.layout(
                for: .text(String(repeating: "m", count: characterCount)),
                screenWidth: 2_000
            ).size.width
        }

        XCTAssertLessThan(widths[0], widths[1])
        XCTAssertLessThan(widths[1], widths[2])
    }

    func testWidthNeverExceedsScreenCap() {
        let screenWidth: CGFloat = 800
        let layout = HUDLayoutEngine.layout(
            for: .text(String(repeating: "wide ", count: 100)),
            screenWidth: screenWidth
        )

        XCTAssertEqual(
            layout.size.width,
            screenWidth * HUDLayoutEngine.maximumScreenWidthFraction
        )
    }

    func testPrimaryOverflowAtCapTriggersTwoLineHeight() {
        let layout = HUDLayoutEngine.layout(
            for: .text(String(repeating: "overflow ", count: 40)),
            screenWidth: 800
        )

        XCTAssertEqual(layout.lineCount, 2)
        XCTAssertEqual(
            layout.size.height,
            HUDLayoutEngine.minimumSize.height
                + HUDLayoutEngine.primaryLineHeight
                + HUDLayoutEngine.wrappedLineSpacing
        )
    }

    func testScreenWidthChangesCapAndWrapping() {
        let content = HUDContent.text(String(repeating: "m", count: 65))
        let narrow = HUDLayoutEngine.layout(
            for: content,
            screenWidth: 800
        )
        let wide = HUDLayoutEngine.layout(
            for: content,
            screenWidth: 1_600
        )

        XCTAssertEqual(narrow.size.width, 440, accuracy: 0.001)
        XCTAssertEqual(narrow.lineCount, 2)
        XCTAssertGreaterThan(wide.size.width, narrow.size.width)
        XCTAssertEqual(wide.lineCount, 1)
        XCTAssertEqual(
            wide.size.height,
            HUDLayoutEngine.minimumSize.height
        )
    }
}

/// `flashFeedback` pays a wrapped pill 0.6 s more, because two lines are two
/// reads — so which messages wrap is a timing decision, not just a layout one.
extension HUDLayoutEngineTests {
    func testFailurePillsFitOneLineOnARealScreen() {
        for message in [
            "heard nothing",
            "locked — tap to end",
            "the mic changed — pasted what i had.",
            "microphone isn't responding",
            "accessibility is off — the dictation key is dead",
            "still finishing the last one",
            "couldn't transcribe — tap to try again",
            "speech model didn't download — finish setup",
            "downloading the speech model — about 460 mb",
            "can't hear zoom — allow system audio recording in privacy settings",
        ] {
            XCTAssertEqual(
                HUDLayoutEngine.layout(
                    for: .text(message),
                    screenWidth: 1_512
                ).lineCount,
                1,
                message
            )
        }
    }

    /// the copied-instead pills grew a "⌘V to paste" tail. they are
    /// instructions, so truncation would be worse than a long pill.
    func testCopiedInsteadPillsStayOnOneLineOnASmallScreen() {
        for message in [
            "copied — secure field · ⌘V to paste",
            "copied — focus changed · ⌘V to paste",
            "copied — couldn't paste it · ⌘V to paste",
            "copied — what you said before the lock · ⌘V to paste",
            "the clipboard is busy — nothing was copied",
        ] {
            let layout = HUDLayoutEngine.layout(
                for: .text(message),
                screenWidth: 1_280
            )

            XCTAssertEqual(layout.lineCount, 1, message)
            XCTAssertLessThan(
                layout.size.width,
                1_280 * HUDLayoutEngine.maximumScreenWidthFraction
            )
        }
    }

    /// the longest thing the pill ever says only wraps on a small screen,
    /// and that is the case that earns the extra beat.
    func testTheLongestFailureWrapsOnASmallScreen() {
        let layout = HUDLayoutEngine.layout(
            for: .text(
                "can't hear zoom — allow system audio recording in privacy settings"
            ),
            screenWidth: 640
        )

        XCTAssertEqual(layout.lineCount, 2)
    }
}
