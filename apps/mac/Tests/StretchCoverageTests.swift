import XCTest

/// What the stretch transcriber knows about how much of a meeting it read:
/// per side, the speech it cut into stretches, and how much of that came
/// back from the engine. The coverage check holds the transcript against
/// these.
///
/// Speech is a tone, silence is zeros, chunks are 100 ms, and the loudness
/// detector has a 0.5 s hangover: a phrase said from 1.3 s to 2.5 s is cut
/// from 1.0 s, with its pre-roll, to 2.5 s — a stretch of 1.5 s.
final class StretchCoverageTests: XCTestCase {
    func testTheSpeechCutAndReadIsCountedPerSide() async throws {
        let engine = WordsEngine()
        let transcriber = stretches(engine)
        try await transcriber.begin()

        await play([
            .init(side: .you, from: 1.3, to: 2.5),
            .init(side: .them, from: 3.3, to: 4.0),
        ], through: 5.0, into: transcriber)
        _ = await transcriber.finish()

        let tally = await transcriber.tally
        XCTAssertEqual(tally.speechYou, .seconds(1.5))
        XCTAssertEqual(tally.readYou, .seconds(1.5))
        XCTAssertEqual(tally.speechThem, .seconds(1))
        XCTAssertEqual(tally.readThem, .seconds(1))
    }

    // MARK: - building a meeting

    private func stretches(_ engine: WordsEngine) -> StretchTranscriber {
        StretchTranscriber(
            engine: engine,
            ceiling: .seconds(25),
            detector: { LoudnessDetector(threshold: 0.02, hangover: .milliseconds(500)) })
    }

    private struct Said {
        let side: Stretch.Side
        let from: Double
        let to: Double
    }

    /// The meeting from the start to `end` seconds, fed a 100 ms chunk at a
    /// time on the meeting's clock.
    private func play(_ said: [Said], through end: Double, into transcriber: StretchTranscriber) async {
        for k in 0..<Int((end * 10).rounded()) {
            await transcriber.feed(chunk(k, said))
        }
    }

    private func chunk(_ k: Int, _ said: [Said]) -> MeetingAudioChunk {
        let (you, them) = sides(of: said, from: k * 1_600, count: 1_600)
        return MeetingAudioChunk(you: you, them: them, at: .milliseconds(100 * k))
    }

    private func sides(of said: [Said], from first: Int, count n: Int) -> ([Float], [Float]) {
        var you = [Float](repeating: 0, count: n)
        var them = [Float](repeating: 0, count: n)
        for line in said {
            let from = max(first, Int((line.from * 16_000).rounded()))
            let to = min(first + n, Int((line.to * 16_000).rounded()))
            guard from < to else { continue }
            for i in from..<to {
                let sample = sin(Float(i) * 0.05) * 0.3
                switch line.side {
                case .you: you[i - first] += sample
                case .them: them[i - first] += sample
                }
            }
        }
        return (you, them)
    }
}

// MARK: - fakes

private struct Refused: Error {}

/// Hears every stretch as a few words. Told to, it throws on the first
/// decodes it is handed, or will not load at all.
private final class WordsEngine: StretchEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var failuresLeft = 0
    private var refuses = false

    func failFirst(_ count: Int) {
        lock.withLock { failuresLeft = count }
    }

    func refuseToLoad() {
        lock.withLock { refuses = true }
    }

    func load() async throws {
        if lock.withLock({ refuses }) { throw Refused() }
    }

    func text(of samples: [Float]) async throws -> String {
        try lock.withLock {
            if failuresLeft > 0 {
                failuresLeft -= 1
                throw Refused()
            }
            return "a few words"
        }
    }
}
