/// how long the engine gets to answer one take before the press stops
/// waiting on it.
///
/// parakeet answers a typical take in 30–200 ms on a release build and a few
/// hundred in debug, and runs a long one at many times real time. the floor
/// covers every short take with a wide margin, including an engine the ANE
/// has to wake up after an idle spell or a sleep. past sixteen seconds of
/// audio the deadline grows at a quarter of the take: five minutes, the
/// capture ceiling, gets 75 s, which only an engine running slower than four
/// times real time would miss — a hang, not a slow day. a deadline missed by
/// a slow engine costs a tap; one never set costs every press after it.
enum TranscriptionDeadline {
    static let floor = Duration.seconds(4)
    /// takes in a row gone unanswered before the engine is restarted rather
    /// than checked: a retry of the first that hangs too is not a slow day.
    static let unansweredBeforeRestart = 2
    /// the engine's input: 16 kHz mono.
    private static let sampleRate = 16_000.0

    static func forSamples(_ count: Int) -> Duration {
        max(floor, .seconds(Double(count) / sampleRate) / 4)
    }
}
