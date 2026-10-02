import Foundation

/// A call raced against the real clock: whichever comes first, its answer
/// or `Deadline.Passed`. The call that loses is cancelled and left to end
/// where it is. One wedged inside CoreML does not hear a cancel and can
/// only stop being waited on; a task group would wait on it for good.
enum Deadline {
    struct Passed: Error, LocalizedError {
        let limit: Duration

        var errorDescription: String? {
            "no answer in \(String(format: "%.1f", limit.totalSeconds)) s"
        }
    }

    static func race<T: Sendable>(
        _ limit: Duration,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let (answers, answer) = AsyncStream.makeStream(of: Result<T, any Error>.self)
        let call = Task {
            do {
                answer.yield(.success(try await work()))
            } catch {
                answer.yield(.failure(error))
            }
        }
        let timer = Task {
            try? await Task.sleep(for: limit)
            answer.yield(.failure(Passed(limit: limit)))
        }
        defer {
            answer.finish()
            timer.cancel()
            call.cancel()
        }
        for await result in answers {
            return try result.get()
        }
        // the one waiting was cancelled itself.
        throw CancellationError()
    }
}
