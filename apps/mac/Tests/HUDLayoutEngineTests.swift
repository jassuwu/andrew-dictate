import XCTest

final class HUDLayoutEngineTests: XCTestCase {
    func testShortTextAndFixedStatesUseMinimumSize() {
        let shortText = HUDLayoutEngine.layout(
            for: .text(primary: "done", secondary: nil),
            screenWidth: 1_440
        )

        XCTAssertEqual(shortText.size, HUDLayoutEngine.minimumSize)
        XCTAssertEqual(shortText.lineCount, 1)
        XCTAssertEqual(
            HUDLayoutEngine.layout(
                for: .wave,
                screenWidth: 1_440
            ).size,
            HUDLayoutEngine.minimumSize
        )
        XCTAssertEqual(
            HUDLayoutEngine.layout(
                for: .prewarming,
                screenWidth: 1_440
            ).size,
            HUDLayoutEngine.minimumSize
        )
    }

    func testGrowingTextGrowsWidthMonotonically() {
        let widths = [20, 30, 40].map { characterCount in
            HUDLayoutEngine.layout(
                for: .text(
                    primary: String(repeating: "m", count: characterCount),
                    secondary: nil
                ),
                screenWidth: 2_000
            ).size.width
        }

        XCTAssertLessThan(widths[0], widths[1])
        XCTAssertLessThan(widths[1], widths[2])
    }

    func testWidthNeverExceedsScreenCap() {
        let screenWidth: CGFloat = 800
        let layout = HUDLayoutEngine.layout(
            for: .text(
                primary: String(repeating: "wide ", count: 100),
                secondary: nil
            ),
            screenWidth: screenWidth
        )

        XCTAssertEqual(
            layout.size.width,
            screenWidth * HUDLayoutEngine.maximumScreenWidthFraction
        )
    }

    func testPrimaryOverflowAtCapTriggersTwoLineHeight() {
        let layout = HUDLayoutEngine.layout(
            for: .text(
                primary: String(repeating: "overflow ", count: 40),
                secondary: nil
            ),
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

    func testSecondaryRowPreservesGateHeightMath() {
        let singleLineGate = HUDLayoutEngine.layout(
            for: .text(
                primary: "codex fix tests",
                secondary: "tap ⌥ to run · esc to cancel"
            ),
            screenWidth: 1_440
        )
        let wrappedGate = HUDLayoutEngine.layout(
            for: .text(
                primary: String(repeating: "command ", count: 50),
                secondary: "tap ⌥ to run · esc to cancel"
            ),
            screenWidth: 800
        )

        XCTAssertEqual(
            singleLineGate.size.height,
            HUDLayoutEngine.minimumSize.height
        )
        XCTAssertEqual(singleLineGate.lineCount, 1)
        XCTAssertEqual(
            wrappedGate.size.height,
            HUDLayoutEngine.minimumSize.height
                + HUDLayoutEngine.primaryLineHeight
                + HUDLayoutEngine.wrappedLineSpacing
        )
        XCTAssertEqual(wrappedGate.lineCount, 2)
    }

    func testScreenWidthChangesCapAndWrapping() {
        let content = HUDContent.text(
            primary: String(repeating: "m", count: 65),
            secondary: nil
        )
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

    func testAnswerPreviewKeepsShortTextAndEllipsizesLongText() {
        XCTAssertEqual(HUDAnswerFormatter.preview(" short answer \n"), "short answer")

        let longAnswer = String(
            repeating: "a",
            count: HUDAnswerFormatter.maximumPreviewCharacters + 1
        )
        let preview = HUDAnswerFormatter.preview(longAnswer)
        XCTAssertEqual(
            preview.count,
            HUDAnswerFormatter.maximumPreviewCharacters + 2
        )
        XCTAssertTrue(preview.hasSuffix(" ⋯"))
    }
}
