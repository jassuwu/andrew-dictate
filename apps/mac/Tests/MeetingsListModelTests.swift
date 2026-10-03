import XCTest

/// the meetings half of history, and the one thing the pane can ask of it:
/// narrow this pile to the one call i am thinking of.
@MainActor
final class MeetingsListModelTests: XCTestCase {
    private func meeting(
        app: String,
        at seconds: TimeInterval
    ) -> MeetingSummary {
        MeetingSummary(
            fileURL: URL(fileURLWithPath: "/tmp/\(app)-\(Int(seconds)).md"),
            app: app,
            started: Date(timeIntervalSince1970: seconds),
            duration: .seconds(600),
            complete: true,
            gapCount: 0,
            recovered: false
        )
    }

    func testTheAppNameNarrowsThePile() {
        let zoom = meeting(app: "zoom", at: 1_000_000)
        let chrome = meeting(app: "chrome", at: 2_000_000)
        let model = MeetingsListModel { [zoom, chrome] }

        model.query = "ZOOM"

        XCTAssertEqual(model.filtered, [zoom])
    }

    /// the row is the only place a meeting's date is written, so the row's own
    /// spelling of it is what someone would type back — in whatever locale
    /// they are in.
    func testTheDateAsTheRowShowsItNarrowsThePile() {
        let zoom = meeting(app: "zoom", at: 1_000_000)
        let chrome = meeting(app: "chrome", at: 2_000_000)
        let model = MeetingsListModel { [zoom, chrome] }

        model.query = zoom.started.formatted(
            date: .abbreviated,
            time: .shortened
        )

        XCTAssertEqual(model.filtered, [zoom])
    }

    func testABlankQueryLeavesThePileAlone() {
        let zoom = meeting(app: "zoom", at: 1_000_000)
        let chrome = meeting(app: "chrome", at: 2_000_000)
        let model = MeetingsListModel { [zoom, chrome] }

        model.query = "  "

        XCTAssertFalse(model.isSearching)
        XCTAssertEqual(model.filtered.count, 2)
    }

    /// an empty result is a search that found nothing, not an empty folder —
    /// the pane says a different sentence for each.
    func testAQueryThatMatchesNothingIsStillASearch() {
        let zoom = meeting(app: "zoom", at: 1_000_000)
        let model = MeetingsListModel { [zoom] }

        model.query = "teams"

        XCTAssertTrue(model.filtered.isEmpty)
        XCTAssertTrue(model.isSearching)
        XCTAssertEqual(model.items.count, 1, "and the folder is untouched")
    }

    // MARK: - recordings that could not be transcribed

    /// the line that counts them offers a retry, and what it says afterwards
    /// is what is on disk afterwards: the ones that worked are meetings now,
    /// the ones that did not are still counted.
    func testTryingAgainRereadsTheCountAndTheMeetingsOnceTheRetryIsDone() async {
        let zoom = meeting(app: "zoom", at: 1_000_000)
        var setAside = 3
        var meetings: [MeetingSummary] = []
        var asked = 0
        let model = MeetingsListModel(
            setAsideFolder: URL(fileURLWithPath: "/tmp/unreadable"),
            countSetAside: { setAside },
            tryAgain: {
                asked += 1
                setAside = 1
                meetings = [zoom]
            },
            load: { meetings })
        XCTAssertEqual(model.setAsideCount, 3)
        XCTAssertEqual(model.items, [])
        XCTAssertTrue(model.canTryAgain)

        await model.tryAgain()

        XCTAssertEqual(asked, 1)
        XCTAssertEqual(model.setAsideCount, 1)
        XCTAssertEqual(model.items, [zoom])
        XCTAssertFalse(model.tryingAgain)
    }

    /// a retry can take a quarter of an hour a recording. the line says it
    /// is working, and asking again meanwhile asks for nothing.
    func testTheLineSaysItIsTryingAgainWhileItRunsAndAsksOnlyOnce() async {
        var model: MeetingsListModel!
        var asked = 0
        var tryingWhileItRan: Bool?
        model = MeetingsListModel(
            setAsideFolder: URL(fileURLWithPath: "/tmp/unreadable"),
            countSetAside: { 2 },
            tryAgain: {
                asked += 1
                tryingWhileItRan = model.tryingAgain
                await model.tryAgain()
            },
            load: { [] })

        await model.tryAgain()

        XCTAssertEqual(asked, 1)
        XCTAssertEqual(tryingWhileItRan, true)
        XCTAssertFalse(model.tryingAgain)
    }

    /// a pane that was given nothing to retry with offers no button for it.
    func testWithNothingToRetryWithThereIsNoTryAgain() async {
        let model = MeetingsListModel(
            setAsideFolder: URL(fileURLWithPath: "/tmp/unreadable"),
            countSetAside: { 2 },
            load: { [] })

        await model.tryAgain()

        XCTAssertFalse(model.canTryAgain)
        XCTAssertFalse(model.tryingAgain)
        XCTAssertEqual(model.setAsideCount, 2)
    }
}
