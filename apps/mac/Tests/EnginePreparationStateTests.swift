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

    // MARK: - what an early press does about it

    /// a failed load — a download that dropped, a restart that didn't come
    /// back — is usually a blip, and the key is the user asking: the next
    /// press tries again rather than leaving the key dead for good.
    func testAPressAfterAFailedLoadTriesAgain() {
        XCTAssertEqual(EnginePreparationState.failed.earlyPress, .retryPreparing)
    }

    /// nobody asked for the model yet: the press is the ask.
    func testAPressBeforeAnyLoadStartsOne() {
        XCTAssertEqual(EnginePreparationState.notStarted.earlyPress, .startPreparing)
    }

    /// one already on its way is waited on, not started over.
    func testAPressWhileItLoadsWaits() {
        XCTAssertEqual(EnginePreparationState.downloading(progress: 0.4).earlyPress, .wait)
        XCTAssertEqual(EnginePreparationState.warmingUp.earlyPress, .wait)
        XCTAssertEqual(EnginePreparationState.ready.earlyPress, .wait)
    }
}
