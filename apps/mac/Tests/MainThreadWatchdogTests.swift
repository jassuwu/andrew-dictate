import XCTest

/// the watchdog pings the main thread only while a press is in flight and
/// a little after, and says when a ping went unanswered too long. real
/// time, short numbers: the thing under test is a thread that stops.
@MainActor
final class MainThreadWatchdogTests: XCTestCase {
    private var stalls: [Int] = []

    private func watchdog(linger: TimeInterval = 1) -> MainThreadWatchdog {
        MainThreadWatchdog(
            interval: 0.05,
            threshold: 0.2,
            linger: linger,
            onStall: { [weak self] milliseconds in
                self?.stalls.append(milliseconds)
            }
        )
    }

    /// at idle the app costs nothing: no timer until a press is in flight.
    func testIdleItIsNotWatching() {
        XCTAssertFalse(watchdog().isWatching)
    }

    func testAMainThreadThatStopsAnsweringIsReportedOnceItAnswers() async throws {
        let dog = watchdog()
        dog.watch("recording")
        try await Task.sleep(for: .milliseconds(150))

        Thread.sleep(forTimeInterval: 0.4)
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertGreaterThanOrEqual(stalls.max() ?? 0, 300, "\(stalls)")
        dog.windDown()
    }

    /// a press is over: it keeps watching through the linger, then stops
    /// costing anything — unless the next press arrives first.
    func testItStopsWatchingOnceThePressHasLingered() async throws {
        let dog = watchdog(linger: 0.1)
        dog.watch("transcribing")
        XCTAssertTrue(dog.isWatching)

        dog.windDown()
        XCTAssertTrue(dog.isWatching)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(dog.isWatching)

        dog.watch("recording")
        dog.windDown()
        dog.watch("recording")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(dog.isWatching)
        dog.windDown()
    }
}
