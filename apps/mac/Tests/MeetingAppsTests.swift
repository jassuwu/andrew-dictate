import XCTest

final class MeetingAppsTests: XCTestCase {
    private let zoom = RunningApp(name: "zoom.us", bundleID: "us.zoom.xos", pid: 10)
    private let chrome = RunningApp(name: "Google Chrome", bundleID: "com.google.Chrome", pid: 11)
    private let slack = RunningApp(name: "Slack", bundleID: "com.tinyspeck.slackmacgap", pid: 12)
    private let xcode = RunningApp(name: "Xcode", bundleID: "com.apple.dt.Xcode", pid: 13)
    private let finder = RunningApp(name: "Finder", bundleID: "com.apple.finder", pid: 14)
    private let anon = RunningApp(name: "Thing", bundleID: nil, pid: 15)

    func testMeetingAppsComeFirstInTheKnownOrder() {
        let ranked = MeetingApps.rank([xcode, chrome, anon, slack, zoom])
        XCTAssertEqual(ranked.meeting.map(\.pid), [10, 12, 11])
    }

    func testEverythingElseIsAlphabetical() {
        let ranked = MeetingApps.rank([xcode, finder, anon])
        XCTAssertEqual(ranked.meeting, [])
        XCTAssertEqual(ranked.other.map(\.name), ["Finder", "Thing", "Xcode"])
    }

    func testDisplayNamesAreShortAndLowercase() {
        XCTAssertEqual(MeetingApps.displayName(zoom), "zoom")
        XCTAssertEqual(MeetingApps.displayName(chrome), "chrome")
        XCTAssertEqual(MeetingApps.displayName(xcode), "xcode")
        XCTAssertEqual(MeetingApps.displayName(anon), "thing")
    }

    func testRankOfNothingIsNothing() {
        let ranked = MeetingApps.rank([])
        XCTAssertTrue(ranked.meeting.isEmpty && ranked.other.isEmpty)
    }
}
