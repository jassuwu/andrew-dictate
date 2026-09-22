import XCTest

final class EnginePreparationStateTests: XCTestCase {
    /// the first press after skipping setup is the one that starts the
    /// download, so it prices it rather than reporting 0%.
    func testTheFirstPressPricesTheDownload() {
        XCTAssertEqual(
            EnginePreparationState.notStarted.pressedEarlyNotice(
                downloadSize: "about 460 mb"
            ),
            "downloading the speech model — about 460 mb"
        )
    }

    func testAPressWhileDownloadingReportsWholePercent() {
        XCTAssertEqual(
            EnginePreparationState.downloading(progress: 0.42)
                .pressedEarlyNotice(downloadSize: "about 460 mb"),
            "downloading the speech model — 42%"
        )
    }

    func testProgressOutsideZeroToOneIsClamped() {
        XCTAssertEqual(
            EnginePreparationState.downloading(progress: 1.4)
                .pressedEarlyNotice(downloadSize: "about 460 mb"),
            "downloading the speech model — 100%"
        )
        XCTAssertEqual(
            EnginePreparationState.downloading(progress: -0.2)
                .pressedEarlyNotice(downloadSize: "about 460 mb"),
            "downloading the speech model — 0%"
        )
    }

    func testUnpackingSaysItIsLoading() {
        XCTAssertEqual(
            EnginePreparationState.warmingUp.pressedEarlyNotice(
                downloadSize: "about 460 mb"
            ),
            "loading the speech model…"
        )
    }

    /// a ready model is not an early press, and a failed one already has its
    /// own pill one branch over — neither needs this one.
    func testReadyAndFailedSayNothingHere() {
        XCTAssertNil(
            EnginePreparationState.ready.pressedEarlyNotice(
                downloadSize: "about 460 mb"
            )
        )
        XCTAssertNil(
            EnginePreparationState.failed.pressedEarlyNotice(
                downloadSize: "about 460 mb"
            )
        )
    }
}
