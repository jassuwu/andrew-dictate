import XCTest

final class CaptureCapWarningTests: XCTestCase {
    /// 48 kHz, a five-minute cap, thirty seconds of lead.
    private let cap = 48_000 * 300
    private let lead = 48_000 * 30

    private func makeWarning() -> CaptureCapWarning {
        CaptureCapWarning(
            maximumFrameCount: cap,
            leadFrameCount: lead
        )
    }

    func testTripsAtCapMinusTheLead() {
        var warning = makeWarning()

        XCTAssertEqual(warning.threshold, 48_000 * 270)
        XCTAssertFalse(warning.shouldWarn(at: 48_000 * 270 - 1))
        XCTAssertTrue(warning.shouldWarn(at: 48_000 * 270))
    }

    func testWarnsExactlyOnce() {
        var warning = makeWarning()
        let threshold = warning.threshold

        XCTAssertTrue(warning.shouldWarn(at: threshold))
        for frameCount in [threshold, threshold + 4_800, cap] {
            XCTAssertFalse(warning.shouldWarn(at: frameCount))
        }
    }

    /// frame-counted, not wall-clocked: hold the key over a dead mic for
    /// five minutes and there is nothing to warn about.
    func testATakeThatNeverGotAudioNeverWarns() {
        var warning = makeWarning()

        XCTAssertFalse(warning.shouldWarn(at: 0))
        XCTAssertTrue(warning.isArmed)
    }

    func testResetRearmsForTheNextTake() {
        var warning = makeWarning()
        let threshold = warning.threshold

        XCTAssertTrue(warning.shouldWarn(at: cap))
        warning.reset()
        XCTAssertTrue(warning.shouldWarn(at: threshold))
    }

    /// a cap inside the lead is its own warning — staying silent beats
    /// saying "thirty seconds left" at frame zero.
    func testACapShorterThanTheLeadIsDisarmed() {
        var short = CaptureCapWarning(
            maximumFrameCount: 48_000 * 10,
            leadFrameCount: lead
        )

        XCTAssertEqual(short.threshold, 0)
        XCTAssertFalse(short.isArmed)
        XCTAssertFalse(short.shouldWarn(at: 48_000 * 10))
    }
}
