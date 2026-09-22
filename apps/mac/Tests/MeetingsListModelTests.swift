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
}
