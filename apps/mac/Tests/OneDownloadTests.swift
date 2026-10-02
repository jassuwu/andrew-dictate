import XCTest

/// A download several may ask for at once — a meeting's load, the speaker
/// split fetched beside it, setup — runs once, so two never write into one
/// folder together; and whoever waits on it waits as long as they choose.
final class OneDownloadTests: XCTestCase {
    /// Asked twice while it runs, it is fetched once, and both hear when it
    /// is done.
    func testTwoAskingAtOnceShareOneFetch() async throws {
        let fetch = Fetch()
        let download = OneDownload { try await fetch.run() }

        async let first: Void = download.run()
        async let second: Void = download.run()
        await fetch.untilStarted()
        // a moment for the second to ask too.
        try await Task.sleep(for: .milliseconds(100))
        fetch.finish()
        _ = try await (first, second)

        XCTAssertEqual(fetch.runs, 1)
    }

    /// Once it has ended, asking again fetches again: a download that failed
    /// is tried afresh, not answered with its old failure.
    func testAskedAgainAfterItEndedItFetchesAgain() async throws {
        let fetch = Fetch()
        fetch.fails = true
        let download = OneDownload { try await fetch.run() }

        fetch.finish()
        do {
            try await download.run()
            XCTFail("the first fetch was meant to fail")
        } catch {}
        fetch.fails = false
        try await download.run()

        XCTAssertEqual(fetch.runs, 2)
    }

    /// A fetch that hangs is waited on as long as the one asking says, and
    /// goes on where it is: the next to ask joins it rather than starting a
    /// second writer beside it.
    func testOneThatHangsIsWaitedOnNoLongerThanAskedAndNotStartedTwice() async throws {
        let fetch = Fetch()
        let download = OneDownload { try await fetch.run() }
        defer { fetch.finish() }

        let asked = ContinuousClock.now
        do {
            try await download.run(within: .milliseconds(200))
            XCTFail("the fetch never finishes, so the wait must run out")
        } catch is Deadline.Passed {}
        XCTAssertLessThan(ContinuousClock.now - asked, .seconds(2))

        do {
            try await download.run(within: .milliseconds(100))
            XCTFail("still hung")
        } catch is Deadline.Passed {}
        XCTAssertEqual(fetch.runs, 1, "the second waited on the first")
    }
}

/// A fetch that runs until it is told to finish, counting its runs.
private final class Fetch: @unchecked Sendable {
    private struct Refused: Error {}

    private let lock = NSLock()
    private var started = 0
    private var finished = false
    private var _fails = false

    var runs: Int { lock.withLock { started } }

    var fails: Bool {
        get { lock.withLock { _fails } }
        set { lock.withLock { _fails = newValue } }
    }

    func finish() {
        lock.withLock { finished = true }
    }

    func run() async throws {
        lock.withLock { started += 1 }
        while !lock.withLock({ finished }) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if fails { throw Refused() }
    }

    func untilStarted() async {
        while runs == 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
