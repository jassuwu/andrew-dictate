import XCTest

/// the windows are real glass over whatever app is behind them, so the
/// worst backdrop is a full-screen white one. these are the floor under
/// that case: nobody can tune the tint, the scrim or the ink back under
/// AA without this failing first.
final class BrandPaletteTests: XCTestCase {
    private let white: [Double] = [255, 255, 255]
    /// the desktop ADR 0039's four-window spike was judged over.
    private let darkDesktop: [Double] = [28, 28, 31]

    func testPrimaryTypeClearsAAOverAWhiteApp() {
        let surface = pane(over: white)

        XCTAssertGreaterThan(contrast(BrandUI.textPrimaryRGB, surface), 4.5)
    }

    func testSecondaryTypeClearsAAOverAWhiteApp() {
        let surface = pane(over: white)
        let ink = composite(
            BrandUI.textPrimaryRGB,
            alpha: BrandUI.textSecondaryOpacity,
            over: surface
        )

        XCTAssertGreaterThan(contrast(ink, surface), 4.5)
    }

    /// why the scrim exists: the tint on its own composites to a light
    /// grey over a white app and the words stop being words.
    func testTheTintAloneWouldNotClearIt() {
        let glassOnly = composite(
            BrandUI.windowBgRGB,
            alpha: BrandUI.windowTintOpacity,
            over: white
        )

        XCTAssertLessThan(contrast(BrandUI.textPrimaryRGB, glassOnly), 2)
    }

    /// and why it is safe: over the dark desktop the ladder was chosen
    /// against, the scrim moves the pane by about one value of grey.
    func testTheScrimIsInvisibleOverTheDarkDesktop() {
        let surface = pane(over: darkDesktop)

        for channel in 0..<3 {
            XCTAssertEqual(
                surface[channel],
                BrandUI.windowBgRGB[channel],
                accuracy: 3
            )
        }
    }

    /// what a `.brandGlassWindow()` pane composites to: the tinted glass
    /// over the backdrop, then the scrim over the glass.
    private func pane(over backdrop: [Double]) -> [Double] {
        let glass = composite(
            BrandUI.windowBgRGB,
            alpha: BrandUI.windowTintOpacity,
            over: backdrop
        )
        return composite(
            BrandUI.windowBgRGB,
            alpha: BrandUI.windowScrimOpacity,
            over: glass
        )
    }

    private func composite(
        _ rgb: [Double],
        alpha: Double,
        over backdrop: [Double]
    ) -> [Double] {
        (0..<3).map { rgb[$0] * alpha + backdrop[$0] * (1 - alpha) }
    }

    /// WCAG 2.1 contrast over raw sRGB channels.
    private func contrast(_ a: [Double], _ b: [Double]) -> Double {
        let first = luminance(a)
        let second = luminance(b)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    private func luminance(_ rgb: [Double]) -> Double {
        let linear = rgb.map { channel -> Double in
            let value = channel / 255
            return value <= 0.04045
                ? value / 12.92
                : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear[0]
            + 0.7152 * linear[1]
            + 0.0722 * linear[2]
    }
}
