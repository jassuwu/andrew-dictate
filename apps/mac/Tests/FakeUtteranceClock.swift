import Foundation

/// a clock the test moves by hand. a sleep wakes when the hand passes its
/// deadline, or throws the moment its task is cancelled.
final class FakeUtteranceClock: UtteranceClock, @unchecked Sendable {
    private struct Sleeper {
        let deadline: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private let origin = ContinuousClock.now
    private var offset: Duration = .zero
    private var sleepers: [UUID: Sleeper] = [:]

    var now: ContinuousClock.Instant {
        lock.withLock { origin + offset }
    }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        sleepers[id] = Sleeper(
                            deadline: offset + duration,
                            continuation: continuation
                        )
                    }
                }
            }
        } onCancel: {
            let sleeper: Sleeper? = lock.withLock {
                sleepers.removeValue(forKey: id)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by amount: Duration) {
        let due = lock.withLock {
            offset += amount
            let due = sleepers.filter { $0.value.deadline <= offset }
            for id in due.keys {
                sleepers.removeValue(forKey: id)
            }
            return due.values.map(\.continuation)
        }
        for continuation in due {
            continuation.resume()
        }
    }
}
