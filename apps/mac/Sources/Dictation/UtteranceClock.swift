/// the utterance machine's sense of time: an instant to stamp the timeline
/// with, and a sleep it can be woken from. injected so a test can hold the
/// 120 ms chime delay, the cool-out and the retry's two minutes in its hand
/// instead of waiting on them.
protocol UtteranceClock: Sendable {
    var now: ContinuousClock.Instant { get }
    func sleep(for duration: Duration) async throws
}

/// the real one. continuous, like the timeline has always been: it keeps
/// counting through a sleep, so a stage that spans one says so.
struct ContinuousUtteranceClock: UtteranceClock {
    var now: ContinuousClock.Instant {
        .now
    }

    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
