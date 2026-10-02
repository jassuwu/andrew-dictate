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

/// the pill's one button (ADR 0047): beside the words, inside the glass, and
/// the pill grows to hold it rather than squeezing the sentence.
extension HUDLayoutEngineTests {
    func testAPillWithAButtonIsWiderByTheButtonAndTheGapBeforeIt() throws {
        // wider than the smallest pill, so the minimum does not hide the sum
        let message = "a question long enough to outgrow the smallest pill?"
        let plain = HUDLayoutEngine.layout(
            for: .text(message),
            screenWidth: 1_440
        )
        let asking = HUDLayoutEngine.layout(
            for: .text(message, button: "record"),
            screenWidth: 1_440
        )

        let button = try XCTUnwrap(asking.button)
        XCTAssertNil(plain.button)
        XCTAssertEqual(asking.lineCount, 1)
        XCTAssertEqual(asking.size.height, HUDLayoutEngine.minimumSize.height)
        XCTAssertEqual(button.height, HUDLayoutEngine.buttonHeight)
        XCTAssertEqual(
            asking.size.width,
            plain.size.width
                - HUDLayoutEngine.horizontalPadding
                + HUDLayoutEngine.buttonGap
                + button.width
                + HUDLayoutEngine.buttonInset,
            accuracy: 0.001
        )
    }

    /// the button sits as far from the glass's edge as the glass's corner
    /// is round minus its own, so the two curves share a centre.
    func testTheButtonIsConcentricWithThePill() {
        XCTAssertEqual(
            HUDLayoutEngine.buttonInset,
            (HUDLayoutEngine.minimumSize.height - HUDLayoutEngine.buttonHeight) / 2
        )
        XCTAssertEqual(
            HUDLayoutEngine.pillCornerRadius - HUDLayoutEngine.buttonInset,
            HUDLayoutEngine.buttonHeight / 2
        )
    }

    /// a pill without a button is the pill it always was.
    func testAPillWithoutAButtonIsUnchanged() {
        let message = "the mic changed — pasted what i had."
        XCTAssertEqual(
            HUDLayoutEngine.layout(for: .text(message), screenWidth: 1_512),
            HUDLayoutEngine.layout(for: .text(message, button: nil), screenWidth: 1_512)
        )
        XCTAssertNil(
            HUDLayoutEngine.layout(for: .text(message), screenWidth: 1_512).button
        )
    }

    /// the questions are short on purpose: none of them wraps, even on the
    /// smallest screen a mac ships with.
    func testTheQuestionsStayOnOneLineOnASmallScreen() {
        for (message, button) in [
            ("facetime call — record it?", "record"),
            ("call ended — stop recording?", "stop"),
            ("still recording?", "stop"),
        ] {
            XCTAssertEqual(
                HUDLayoutEngine.layout(
                    for: .text(message, button: button),
                    screenWidth: 1_280
                ).lineCount,
                1,
                message
            )
        }
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
            "no sound from MacBook Pro Microphone",
            "no sound from the microphone",
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
