import XCTest

final class HUDLayoutEngineTests: XCTestCase {
    func testShortTextUsesMinimumSizeAndGlass() {
        let shortText = HUDLayoutEngine.layout(
            for: .text("done"),
            screenWidth: 1_440
        )

        XCTAssertEqual(shortText.size, HUDLayoutEngine.minimumSize)
        XCTAssertEqual(shortText.lineCount, 1)
        XCTAssertEqual(shortText.style, .glass)
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
        XCTAssertEqual(wave.style, .bare)
        XCTAssertEqual(prewarming.size, HUDLayoutEngine.waveSize)
        XCTAssertEqual(prewarming.style, .bare)
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
