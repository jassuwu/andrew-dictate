/// whether the engine answers at all: a second of silence, the same
/// question the warm-up asks, against a deadline of its own. asked after a
/// take the engine never answered, to tell a slow moment from a wedge.
enum EngineProbe {
    private static let silence = [Float](repeating: 0, count: 16_000)

    /// false for an error or for no answer in time. a call that never
    /// comes back is left behind: a wedged engine can't be cancelled, only
    /// replaced, and a task group would wait on it for good.
    static func answers(
        _ engine: any TranscriptionEngine,
        within deadline: Duration = TranscriptionDeadline.floor,
        clock: any UtteranceClock = ContinuousUtteranceClock()
    ) async -> Bool {
        let (answers, answer) = AsyncStream.makeStream(of: Bool.self)
        let question = Task {
            let answered = (try? await engine.transcribe(silence)) != nil
            answer.yield(answered)
        }
        let timer = Task {
            try? await clock.sleep(for: deadline)
            answer.yield(false)
        }
        defer {
            answer.finish()
            timer.cancel()
            question.cancel()
        }
        for await answered in answers {
            return answered
        }
        return false
    }
}
