import XCTest

/// the watchdog pings the main thread only while a press is in flight and
/// a little after, and says when a ping went unanswered too long. real
/// time, short numbers: the thing under test is a thread that stops.
@MainActor
final class MainThreadWatchdogTests: XCTestCase {
    private var stalls: [Int] = []

    private func watchdog(
        linger: TimeInterval = 1,
        afterHardwareChange: TimeInterval = 1
    ) -> MainThreadWatchdog {
        MainThreadWatchdog(
            interval: 0.05,
            threshold: 0.2,
            linger: linger,
            afterHardwareChange: afterHardwareChange,
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
        dog.watch(.recording)
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
        dog.watch(.transcribing)
        XCTAssertTrue(dog.isWatching)

        dog.windDown()
        XCTAssertTrue(dog.isWatching)
        await eventually { !dog.isWatching }
        XCTAssertFalse(dog.isWatching)

        dog.watch(.recording)
        dog.windDown()
        dog.watch(.recording)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(dog.isWatching)
        dog.windDown()
    }

    /// a monitor, the lid, a wake: the hourglass that followed them came
    /// before any press. the watch starts at the change, runs its window,
    /// then costs nothing again.
    func testAHardwareChangeIsWatchedForItsWindow() async throws {
        let dog = watchdog(afterHardwareChange: 1.5)

        dog.watchAfterHardwareChange()
        XCTAssertTrue(dog.isWatching)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(dog.isWatching)
        await eventually { !dog.isWatching }
        XCTAssertFalse(dog.isWatching)
    }

    /// a press that ends inside a change's window doesn't cut it short,
    /// and a change during a press's linger stretches it.
    func testAPressAndAChangeKeepWatchingUntilTheLaterEnds() async throws {
        let dog = watchdog(linger: 0.05, afterHardwareChange: 1.5)

        dog.watchAfterHardwareChange()
        dog.watch(.recording)
        dog.windDown()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(dog.isWatching)
        await eventually { !dog.isWatching }
        XCTAssertFalse(dog.isWatching)

        dog.watch(.transcribing)
        dog.windDown()
        dog.watchAfterHardwareChange()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(dog.isWatching)
        await eventually { !dog.isWatching }
        XCTAssertFalse(dog.isWatching)
    }

    /// a change's window never ends a press still in flight.
    func testAChangeWindowEndingMidPressKeepsWatching() async throws {
        let dog = watchdog(afterHardwareChange: 0.05)

        dog.watchAfterHardwareChange()
        dog.watch(.recording)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(dog.isWatching)
        dog.windDown()
    }

    /// real time on a shared ci runner: a sleep can overshoot a short
    /// window by more than the window. "it stops" is asked until it is
    /// true or a generous deadline passes, never after one fixed sleep.
    private func eventually(
        within deadline: Duration = .seconds(5),
        _ condition: () -> Bool
    ) async {
        let clock = ContinuousClock()
        let end = clock.now + deadline
        while !condition(), clock.now < end {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
