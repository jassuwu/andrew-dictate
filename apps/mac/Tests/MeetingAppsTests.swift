import XCTest

final class MeetingAppsTests: XCTestCase {
    func testACallAppIsKnownByItsBundleIDAndGoesByAShortName() {
        XCTAssertEqual(MeetingApps.callApp(bundleID: "us.zoom.xos")?.name, "zoom")
        XCTAssertEqual(MeetingApps.callApp(bundleID: "com.tinyspeck.slackmacgap")?.name, "slack")
        XCTAssertEqual(MeetingApps.callApp(bundleID: "com.google.Chrome")?.name, "chrome")
    }

    /// Teams shipped a second app under a new id; both are teams.
    func testBothTeamsAreTeams() {
        XCTAssertEqual(MeetingApps.callApp(bundleID: "com.microsoft.teams2")?.name, "teams")
        XCTAssertEqual(MeetingApps.callApp(bundleID: "com.microsoft.teams")?.name, "teams")
    }

    func testAnythingElseIsNotACallApp() {
        XCTAssertNil(MeetingApps.callApp(bundleID: "com.apple.dt.Xcode"))
        XCTAssertNil(MeetingApps.callApp(bundleID: "com.apple.finder"))
    }
}
