import Foundation
import XCTest

/// one call at a time through the engine: the order they were asked in,
/// never two at once, and a call that never comes back holds only the gate
/// it went through.
final class SerialGateTests: XCTestCase {
    func testCallsRunInTheOrderTheyWereAsked() async throws {
        let gate = SerialGate()
        let first = Latch()
        let log = Log()

        let held = Task {
            try await gate.run {
                await first.wait()
                log.append("first")
            }
        }
        await settle { gate.isBusy }
        let second = Task {
            try await gate.run { log.append("second") }
        }
        await settle { gate.inFlight == 2 }
        let third = Task {
            try await gate.run { log.append("third") }
        }
        await settle { gate.inFlight == 3 }

        first.open()
        _ = try await (held.value, second.value, third.value)

        XCTAssertEqual(log.entries, ["first", "second", "third"])
    }

    /// what the fluidaudio manager can't take: a second call starting while
    /// the first is still inside it.
    func testNoTwoCallsOverlap() async throws {
        let gate = SerialGate()
        let inside = Counter()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await gate.run {
                        inside.enter()
                        try? await Task.sleep(for: .milliseconds(2))
                        inside.leave()
                    }
                }
            }
            try await group.waitForAll()
        }

        XCTAssertEqual(inside.most, 1)
        XCTAssertFalse(gate.isBusy)
    }

    /// a call that throws is still finished: the next one runs.
    func testAFailedCallLetsTheNextOneRun() async throws {
        let gate = SerialGate()
        struct Failure: Error {}

        await XCTAssertThrowsErrorAsync(
            try await gate.run { throw Failure() }
        )
        let answer = try await gate.run { "next" }

        XCTAssertEqual(answer, "next")
    }

    /// a hung call holds everything behind it on its own gate — which is
    /// why a restart builds a fresh manager and a fresh gate with it.
    func testAHungCallHoldsItsGateButNotAFreshOne() async throws {
        let wedged = SerialGate()
        let hang = Latch()
        defer { hang.open() }
        let log = Log()

        let hung = Task {
            try await wedged.run { await hang.wait() }
        }
        await settle { wedged.isBusy }
        let behind = Task {
            try await wedged.run { log.append("behind the hung call") }
        }
        await settle { wedged.inFlight == 2 }

        let fresh = SerialGate()
        let answer = try await fresh.run { "answered" }

        XCTAssertEqual(answer, "answered")
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(log.entries, [], "still queued behind the hung call")

        hang.open()
        _ = try await (hung.value, behind.value)
        XCTAssertEqual(log.entries, ["behind the hung call"])
    }

    /// a probe that gave up while it waited must not run afterwards: its
    /// second of silence would only delay whatever was asked next.
    func testACallCancelledWhileQueuedNeverRuns() async throws {
        let gate = SerialGate()
        let first = Latch()
        let log = Log()

        let held = Task {
            try await gate.run { await first.wait() }
        }
        await settle { gate.isBusy }
        let cancelled = Task {
            try await gate.run { log.append("cancelled call ran") }
        }
        await settle { gate.inFlight == 2 }

        cancelled.cancel()
        first.open()
        try await held.value

        await XCTAssertThrowsErrorAsync(try await cancelled.value)
        XCTAssertEqual(log.entries, [])
        XCTAssertFalse(gate.isBusy)
    }

    // MARK: - the wake

    /// a wake asked while anything is running or waiting is not asked at
    /// all: queued, it would stand between the take and the engine.
    func testAWakeIsSkippedWhileAnythingIsInFlight() async throws {
        let gate = SerialGate()
        let take = Latch()
        let log = Log()

        let running = Task {
            try await gate.run {
                await take.wait()
                log.append("take")
            }
        }
        await settle { gate.isBusy }

        let woke: Void? = try await gate.runIfIdle { log.append("wake") }

        XCTAssertNil(woke)
        take.open()
        try await running.value
        XCTAssertEqual(log.entries, ["take"])
    }

    func testAWakeRunsWhenTheGateIsIdle() async throws {
        let gate = SerialGate()

        let woke = try await gate.runIfIdle { "awake" }

        XCTAssertEqual(woke, "awake")
        XCTAssertFalse(gate.isBusy)
    }

    /// a take asked while the wake runs waits for it, rather than run
    /// beside it.
    func testATakeWaitsForAWakeAlreadyRunning() async throws {
        let gate = SerialGate()
        let wake = Latch()
        let log = Log()

        let waking = Task {
            try await gate.runIfIdle {
                await wake.wait()
                log.append("wake")
            }
        }
        await settle { gate.isBusy }
        let take = Task {
            try await gate.run { log.append("take") }
        }
        await settle { gate.inFlight == 2 }

        wake.open()
        _ = try await (waking.value, take.value)

        XCTAssertEqual(log.entries, ["wake", "take"])
    }

    // MARK: - pieces

    private func settle(
        until isDone: @Sendable () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<400 {
            if isDone() {
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("never settled", file: file, line: line)
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {}
}

/// shut until opened; everyone waiting goes through at once.
private final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let goNow = lock.withLock {
                if isOpen {
                    return true
                }
                waiters.append(continuation)
                return false
            }
            if goNow {
                continuation.resume()
            }
        }
    }

    func open() {
        let waiting = lock.withLock {
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        waiting.forEach { $0.resume() }
    }
}

private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var _entries: [String] = []

    var entries: [String] {
        lock.withLock { _entries }
    }

    func append(_ entry: String) {
        lock.withLock { _entries.append(entry) }
    }
}

/// how many calls are inside at once, and the most there ever were.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var now = 0
    private var _most = 0

    var most: Int {
        lock.withLock { _most }
    }

    func enter() {
        lock.withLock {
            now += 1
            _most = max(_most, now)
        }
    }

    func leave() {
        lock.withLock { now -= 1 }
    }
}
