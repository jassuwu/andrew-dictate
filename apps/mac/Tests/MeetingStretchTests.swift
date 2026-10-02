import XCTest

/// The stretch transcriber, driven the way a meeting drives it: through the
/// coordinator, with a fake tap and a fake engine, and judged by what a
/// person or an agent would read — the transcript file and the live lines.
///
/// Speech is a tone and silence is zeros. Every phrase is played at its own
/// loudness and the fake engine knows a phrase by how loud the stretch it was
/// handed is, so a stretch cut in the wrong place comes back as the wrong
/// words, or none.
///
/// The numbers in here follow from three settings: chunks of 100 ms, a
/// loudness detector with a 0.5 s hangover, and the cutter's 0.3 s of
/// pre-roll. A phrase said from 1.3 s is stamped 1.0 s.
@MainActor
final class MeetingStretchTests: XCTestCase {
    private var dir: URL!
    private var source: FakeSource!
    private var engine: PhraseEngine!
    private var diarizer: RecordingDiarizer!
    private var events: [MeetingEvent] = []

    private let zoom = RunningApp(name: "zoom.us", bundleID: "us.zoom.xos", pid: 42)

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-stretches-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        source = FakeSource()
        engine = PhraseEngine()
        diarizer = RecordingDiarizer()
        events = []
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - who said it, and when

    func testWhatYouSayIsYoursAndStampedWhereYouBeganToSayIt() async throws {
        let c = coordinator(stretches())
        c.start(tapping: zoom)
        await source.awaitStart()

        await play([you("the deploy is blocked", from: 1.3, to: 2.5)], through: 3.5, on: c)
        await waitFor { c.liveLines.count == 1 }

        XCTAssertEqual(live(c), ["you 1.0 the deploy is blocked"])
        c.stop()
        let lines = try await savedLines()
        XCTAssertEqual(lines, ["[00:00:01] you: the deploy is blocked"])
    }

    /// The speaker is the side it came from — nothing is guessed from who
    /// was louder.
    func testTheFarSideIsThemAndTheTurnsComeInTheOrderTheyWereSaid() async throws {
        let c = coordinator(stretches())
        c.start(tapping: zoom)
        await source.awaitStart()

        await play([
            them("are we all here", from: 1.3, to: 2.0),
            you("the deploy is blocked", from: 2.8, to: 4.0),
            them("since when", from: 5.3, to: 6.0),
        ], through: 7.0, on: c)
        await waitFor { c.liveLines.count == 3 }

        XCTAssertEqual(live(c), [
            "them 1.0 are we all here",
            "you 2.5 the deploy is blocked",
            "them 5.0 since when",
        ])
        c.stop()
        let lines = try await savedLines()
        XCTAssertEqual(lines, [
            "[00:00:01] them: are we all here",
            "[00:00:02] you: the deploy is blocked",
            "[00:00:05] them: since when",
        ])
    }

    // MARK: - building a meeting

    private func stretches(ceiling: Duration = .seconds(25), clock: FakeClock = FakeClock()) -> StretchTranscriber {
        StretchTranscriber(
            engine: engine,
            ceiling: ceiling,
            detector: { LoudnessDetector(threshold: 0.02, hangover: .milliseconds(500)) },
            now: { clock.now })
    }

    private func coordinator(
        _ transcriber: StretchTranscriber,
        clock: FakeClock = FakeClock()
    ) -> MeetingCoordinator {
        let folder = dir.appendingPathComponent("docs")
        let c = MeetingCoordinator(
            source: source,
            makeTranscriber: { _ in transcriber },
            diarizer: diarizer,
            spool: MeetingSpool(root: dir.appendingPathComponent("spool")),
            hookRunner: HookRunner(logURL: dir.appendingPathComponent("hooks.log")),
            // nobody here is testing the tap: the far side may be quiet for
            // as long as a test likes without it being called a dead tap.
            thresholds: .init(
                probeTimeout: .seconds(1), silenceTimeout: .seconds(600),
                silenceFloor: 0.001, quietNudgeAfter: .seconds(3_600)),
            now: { clock.now },
            preferences: {
                MeetingPreferences(folder: folder, hook: nil, model: .whisperLargeV3Turbo)
            }
        )
        c.onEvent = { [weak self] in self?.events.append($0) }
        return c
    }

    private struct Said {
        let side: Stretch.Side
        let phrase: String
        let from: Double
        let to: Double
    }

    private func you(_ phrase: String, from: Double, to: Double) -> Said {
        Said(side: .you, phrase: phrase, from: from, to: to)
    }

    private func them(_ phrase: String, from: Double, to: Double) -> Said {
        Said(side: .them, phrase: phrase, from: from, to: to)
    }

    /// The meeting from `start` to `end` seconds, a 100 ms chunk at a time,
    /// stamped on the meeting's clock. The first chunk of a meeting carries a
    /// hum on the far side, under any detector's threshold, so the probe is
    /// heard and the recording starts.
    ///
    /// It returns once the coordinator has taken the last chunk in. The one
    /// before it is fed by then, so every test ends on a second of silence.
    private func play(
        _ said: [Said], from start: Double = 0, through end: Double,
        on c: MeetingCoordinator
    ) async {
        let first = Int((start * 10).rounded())
        let last = Int((end * 10).rounded())
        for k in first..<last {
            source.send(chunk(k, said))
        }
        await waitFor { c.elapsed >= .milliseconds(100 * last - 1) }
        try? await Task.sleep(for: .milliseconds(100))
    }

    private func chunk(_ k: Int, _ said: [Said]) -> MeetingAudioChunk {
        let n = 1_600
        let first = k * n
        var you = [Float](repeating: 0, count: n)
        var them = [Float](repeating: k == 0 ? 0.005 : 0, count: n)
        for line in said {
            let from = max(first, Int((line.from * 16_000).rounded()))
            let to = min(first + n, Int((line.to * 16_000).rounded()))
            guard from < to else { continue }
            let loudness = engine.loudness(of: line.phrase)
            for i in from..<to {
                let sample = sin(Float(i) * 0.05) * loudness
                switch line.side {
                case .you: you[i - first] = sample
                case .them: them[i - first] = sample
                }
            }
        }
        return MeetingAudioChunk(you: you, them: them, at: .milliseconds(100 * k))
    }

    // MARK: - reading it back

    /// The turn lines of the one transcript the meeting saved, once it is
    /// on disk.
    private func savedLines() async throws -> [String] {
        let folder = dir.appendingPathComponent("docs")
        await waitFor(10) { !MeetingTranscriptFile.listAll(in: folder).isEmpty }
        let saved = try XCTUnwrap(
            MeetingTranscriptFile.listAll(in: folder).first, "nothing saved: \(events)")
        let body = try String(contentsOf: saved.fileURL, encoding: .utf8)
        return body.split(separator: "\n").filter { $0.hasPrefix("[") }.map(String.init)
    }

    private func live(_ c: MeetingCoordinator) -> [String] {
        c.liveLines.map { line in
            let who = line.speaker == .you ? "you" : "them"
            let confirmed = line.isConfirmed ? "" : " (tentative)"
            return "\(who) \(seconds(line.at)) \(line.text)\(confirmed)"
        }
    }

    private func seconds(_ duration: Duration) -> String {
        String(format: "%.1f", duration.totalSeconds)
    }

    /// Polls until `condition` holds or the time is up; the assertion after
    /// it says what was there instead.
    private func waitFor(_ seconds: Double = 5, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

// MARK: - fakes

/// A wall the test moves by hand.
private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private let origin = ContinuousClock.now
    private var offset: Duration = .zero

    var now: ContinuousClock.Instant {
        lock.withLock { origin + offset }
    }

    func advance(by amount: Duration) {
        lock.withLock { offset += amount }
    }
}

private final class FakeSource: MeetingAudioSource, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<MeetingAudioChunk>.Continuation?

    func start(tapping app: RunningApp) async throws -> AsyncStream<MeetingAudioChunk> {
        let (stream, continuation) = AsyncStream<MeetingAudioChunk>.makeStream()
        lock.withLock { self.continuation = continuation }
        return stream
    }

    func rebuild() async throws {}

    func stop() async {
        lock.withLock { continuation }?.finish()
    }

    func send(_ chunk: MeetingAudioChunk) {
        _ = lock.withLock { continuation }?.yield(chunk)
    }

    func awaitStart() async {
        while lock.withLock({ continuation == nil }) {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private struct Garbled: Error {}

/// Knows a phrase by its loudness: the test plays phrase n at 0.1 × n, and a
/// stretch is heard as the phrase whose loudness its peak is nearest to.
/// Silence is heard as nothing at all.
private final class PhraseEngine: StretchEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var phrases: [String] = []
    private var decoded: [(phrase: String, samples: Int)] = []

    func loudness(of phrase: String) -> Float {
        lock.withLock {
            if !phrases.contains(phrase) { phrases.append(phrase) }
            return 0.1 * Float(phrases.firstIndex(of: phrase)! + 1)
        }
    }

    /// Every stretch the engine was handed, as the phrase it heard and its
    /// length in samples, in the order it was handed them.
    var handed: [(phrase: String, samples: Int)] {
        lock.withLock { decoded }
    }

    func load() async throws {}

    func text(of samples: [Float]) async throws -> String {
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        return lock.withLock {
            let index = Int((peak * 10).rounded()) - 1
            let phrase = peak < 0.05 ? "" : phrases.indices.contains(index) ? phrases[index] : "?"
            decoded.append((phrase, samples.count))
            return phrase
        }
    }
}

/// Splits nobody; remembers the times it was asked about.
private final class RecordingDiarizer: MeetingDiarizer, @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [Duration] = []

    var askedAbout: [Duration] {
        lock.withLock { asked }
    }

    func split(them: [Float], turns: [MeetingTurn]) async -> [MeetingTurn] {
        lock.withLock { asked += turns.map(\.at) }
        return turns
    }
}
