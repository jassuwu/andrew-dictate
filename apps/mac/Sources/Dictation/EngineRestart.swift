/// a restart of a speech model already on disk: the loaded one goes and the
/// same one loads fresh. that takes seconds. one still going after a minute
/// has wedged somewhere a restart can't reach, and waiting on it longer
/// leaves every press saying "loading the speech model…" for good. past the
/// deadline it has failed, which the next press retries out loud.
enum EngineRestart {
    static let deadline = Duration.seconds(60)

    enum Outcome: Equatable, Sendable {
        case restarted
        /// why, for the log.
        case failed(String)
        case timedOut

        /// what the speech model is now. anything but a finished restart is
        /// `.failed`, and a press on `.failed` tries again and says so.
        var preparationState: EnginePreparationState {
            self == .restarted ? .ready : .failed
        }
    }

    /// the first of the restart and the deadline to answer. a restart that
    /// never comes back is cancelled and left behind: a wedged load can't
    /// be taken back, only replaced by the next press's. cancelling the
    /// caller cancels the restart.
    static func run(
        within deadline: Duration = deadline,
        clock: any UtteranceClock = ContinuousUtteranceClock(),
        _ restart: @escaping @Sendable () async throws -> Void
    ) async -> Outcome {
        let (outcomes, answer) = AsyncStream.makeStream(of: Outcome.self)
        let attempt = Task {
            do {
                try await restart()
                answer.yield(.restarted)
            } catch {
                answer.yield(.failed(error.localizedDescription))
            }
        }
        let timer = Task {
            try? await clock.sleep(for: deadline)
            guard !Task.isCancelled else {
                return
            }
            answer.yield(.timedOut)
        }
        defer {
            answer.finish()
            timer.cancel()
            attempt.cancel()
        }
        return await withTaskCancellationHandler {
            for await outcome in outcomes {
                return outcome
            }
            return .failed("cancelled")
        } onCancel: {
            attempt.cancel()
        }
    }
}
