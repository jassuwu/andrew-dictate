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

    /// A browser plays and listens through a helper process, and Core Audio
    /// names the helper, not the app. Arc's helpers do not even keep the
    /// app's capitals.
    func testAHelperProcessIsItsApp() {
        XCTAssertEqual(MeetingApps.callApp(bundleID: "com.google.Chrome.helper")?.name, "chrome")
        XCTAssertEqual(MeetingApps.callApp(bundleID: "com.google.Chrome.helper.Renderer")?.name, "chrome")
        XCTAssertEqual(MeetingApps.callApp(bundleID: "company.thebrowser.browser.helper")?.name, "arc")
        XCTAssertEqual(MeetingApps.callApp(bundleID: "US.ZOOM.XOS")?.name, "zoom")
    }

    /// A prefix is only a helper when a dot follows it: the new teams is not
    /// a helper of the old one, and an app that merely starts with the same
    /// letters is somebody else's.
    func testAPrefixWithoutADotIsAnotherApp() {
        XCTAssertEqual(MeetingApps.callApp(bundleID: "com.microsoft.teams2.helper")?.name, "teams")
        XCTAssertNil(MeetingApps.callApp(bundleID: "com.google.Chromecast"))
        XCTAssertNil(MeetingApps.callApp(bundleID: "us.zoom.xosupdater"))
    }
}
