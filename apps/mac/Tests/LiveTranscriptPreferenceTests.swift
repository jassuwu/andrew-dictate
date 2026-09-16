import XCTest

final class LiveTranscriptPreferenceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        suite = "AndrewDictateTests.LiveTranscript.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    /// The one meeting where the app has proved nothing yet is the one it
    /// used to show nothing during.
    func testNeverWrittenMeansTheFirstMeetingShowsItsWork() {
        XCTAssertTrue(LiveTranscriptPreference.wasOpenLastTime(in: defaults))
    }

    func testClosingItOnceKeepsItClosed() {
        LiveTranscriptPreference.remember(false, in: defaults)

        XCTAssertFalse(LiveTranscriptPreference.wasOpenLastTime(in: defaults))
    }

    func testLeavingItOpenBringsItBack() {
        LiveTranscriptPreference.remember(true, in: defaults)

        XCTAssertTrue(LiveTranscriptPreference.wasOpenLastTime(in: defaults))
    }
}
