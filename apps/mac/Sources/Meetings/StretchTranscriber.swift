import Foundation
import os

/// The model a meeting is read with, one stretch at a time.
protocol StretchEngine: Sendable {
    /// Once, before the first stretch. Slow: whisper takes ten-odd seconds.
    func load() async throws
    /// One stretch of 16 kHz mono speech, start to end, as text.
    func text(of samples: [Float]) async throws -> String
}

/// What a meeting's decoding came to, for its record: counts and times,
/// never a word of what was said.
struct StretchTally: Equatable, Sendable {
    var decodedYou = 0
    var decodedThem = 0
    /// Stretches the engine threw on twice. Their words are not in the file.
    var failed = 0
    /// How far behind the meeting the decoding ran: from a stretch joining
    /// the queue to its decode finishing, the worst of the meeting and the
    /// latest.
    var mostBehind: Duration = .zero
    var lastBehind: Duration = .zero
}

/// A meeting heard a stretch at a time, each stretch decoded once.
///
/// A detector finds where speech begins and ends, a cutter cuts the speech
/// out, and the stretches wait in one queue, in the order they ended, for a
/// single worker to hand to the engine. A stretch becomes one turn and one
/// confirmed live line; nothing is decoded twice, and nothing is shown that
/// might change.
actor StretchTranscriber: MeetingTranscriber {
    nonisolated let lines: AsyncStream<LiveLine>

    private let emit: AsyncStream<LiveLine>.Continuation
    private let engine: any StretchEngine
    private let makeDetector: @Sendable () -> any SpeechDetector
    private let ceiling: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private let logger = Logger(subsystem: AppIdentity.loggingSubsystem, category: "stretches")

    /// The two sides are two streams, each with its own detector: whoever
    /// is speaking is the side the speech came from.
    private let youDetector: any SpeechDetector
    private let themDetector: any SpeechDetector
    private var you: StretchCutter
    private var them: StretchCutter

    /// Each chunk is heard after the one before it has been, whoever calls.
    /// The detector is awaited, so without this a chunk could overtake its
    /// predecessor — or `finish` could flush a side mid-chunk.
    private var hearing: Task<Void, Never>?
    private var loading: Task<Void, any Error>?
    private var isReady = false
    private var isFinished = false
    /// Stretches that have ended and wait for the engine, in the order they
    /// ended, with when they joined. Audio leaves memory when its stretch
    /// leaves this queue.
    private var waiting: [(stretch: Stretch, queued: ContinuousClock.Instant)] = []
    private var worker: Task<Void, Never>?
    private var turns: [MeetingTurn] = []
    private(set) var tally = StretchTally()

    /// The 100 ms the capture layer hands over, so a spool is heard in the
    /// same steps the meeting was.
    private static let spoolChunk = 1_600

    /// `ceiling` is the longest stretch the engine is handed — about 25 s
    /// for whisper, 15 s for parakeet. `detector` makes one detector per
    /// side; `now` is the wall the decoding is timed against.
    init(
        engine: any StretchEngine,
        ceiling: Duration,
        detector makeDetector: @escaping @Sendable () -> any SpeechDetector = { LoudnessDetector() },
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.engine = engine
        self.ceiling = ceiling
        self.makeDetector = makeDetector
        self.now = now
        youDetector = makeDetector()
        themDetector = makeDetector()
        you = StretchCutter(side: .you, ceiling: ceiling)
        them = StretchCutter(side: .them, ceiling: ceiling)
        (lines, emit) = AsyncStream<LiveLine>.makeStream()
    }

    // MARK: - MeetingTranscriber

    func begin() async throws {
        try await load()
        isReady = true
        startWorking()
    }

    func feed(_ chunk: MeetingAudioChunk) async {
        let before = hearing
        let this = Task {
            await before?.value
            await hear(chunk)
        }
        hearing = this
        await this.value
    }

    func finish() async -> [MeetingTurn] {
        await hearing?.value
        isFinished = true
        queue(you.flush() + them.flush())
        // A model still loading is waited for: a meeting stopped in its
        // first seconds must not be written out with none of its words. One
        // that failed, or was never asked to load, has nothing to wait for.
        if let loading, (try? await loading.value) != nil {
            isReady = true
            startWorking()
        }
        while let worker {
            await worker.value
        }
        emit.finish()
        return Self.inOrder(turns)
    }

    /// A whole spool, heard the way the meeting was: in the chunks the
    /// capture layer hands over, through a fresh detector per side, each
    /// stretch decoded as soon as it is cut so only one is in memory beside
    /// the recording. A spool has no gaps in it, so its clock is its sample
    /// count.
    func transcribe(you: [Float], them: [Float]) async throws -> [MeetingTurn] {
        try await load()
        var turns: [MeetingTurn] = []
        for (side, samples) in [(Stretch.Side.you, you), (.them, them)] {
            let detector = makeDetector()
            var cutter = StretchCutter(side: side, ceiling: ceiling)
            var start = 0
            while start < samples.count {
                let end = min(start + Self.spoolChunk, samples.count)
                let chunk = Array(samples[start..<end])
                let edges = await detector.hear(chunk)
                let at = StretchCutter.duration(of: start)
                turns += await decodeAlone(cutter.take(chunk, at: at, edges: edges))
                start = end
            }
            turns += await decodeAlone(cutter.flush())
        }
        return Self.inOrder(turns)
    }

    // MARK: - hearing

    private func hear(_ chunk: MeetingAudioChunk) async {
        guard !isFinished else { return }
        let youEdges = await youDetector.hear(chunk.you)
        let themEdges = await themDetector.hear(chunk.them)
        queue(you.take(chunk.you, at: chunk.at, edges: youEdges)
            + them.take(chunk.them, at: chunk.at, edges: themEdges))
    }

    // MARK: - decoding

    /// Loaded once, however many ask: `begin`, `finish` waiting on it, and a
    /// spool all share the one load.
    private func load() async throws {
        let loading = loading ?? Task { [engine] in try await engine.load() }
        self.loading = loading
        try await loading.value
    }

    private func queue(_ stretches: [Stretch]) {
        for stretch in stretches {
            let index = waiting.firstIndex { $0.stretch.end > stretch.end } ?? waiting.endIndex
            waiting.insert((stretch, now()), at: index)
        }
        startWorking()
    }

    private func startWorking() {
        guard isReady, worker == nil, !waiting.isEmpty else { return }
        worker = Task { await work() }
    }

    /// The one worker. It runs until the queue is empty and then stops; the
    /// next stretch to end starts it again.
    private func work() async {
        while !waiting.isEmpty {
            let (stretch, queued) = waiting.removeFirst()
            let text = await decode(stretch)
            let behind = now() - queued
            tally.lastBehind = behind
            tally.mostBehind = max(tally.mostBehind, behind)
            if let text {
                keep(text, from: stretch)
            }
        }
        worker = nil
    }

    /// A stretch the engine throws on gets one more try: a decode that
    /// failed once is often a hiccup, not the audio. Twice, and it is let
    /// go and counted.
    private func decode(_ stretch: Stretch) async -> String? {
        for attempt in 1...2 {
            do {
                let text = try await engine.text(of: stretch.samples)
                switch stretch.side {
                case .you: tally.decodedYou += 1
                case .them: tally.decodedThem += 1
                }
                return text
            } catch {
                logger.error("a stretch failed to decode, try \(attempt): \(error.localizedDescription, privacy: .public)")
            }
        }
        tally.failed += 1
        return nil
    }

    /// Off the queue and out of the panel: for a spool, which nobody is
    /// watching and which has no meeting to fall behind.
    private func decodeAlone(_ stretches: [Stretch]) async -> [MeetingTurn] {
        var turns: [MeetingTurn] = []
        for stretch in stretches {
            guard let text = await decode(stretch), let words = Self.words(in: text) else { continue }
            turns.append(Self.turn(words, from: stretch))
        }
        return turns
    }

    private func keep(_ text: String, from stretch: Stretch) {
        guard let words = Self.words(in: text) else { return }
        let turn = Self.turn(words, from: stretch)
        turns.append(turn)
        let speaker: LiveLine.Speaker = stretch.side == .you ? .you : .them
        emit.yield(LiveLine(speaker: speaker, at: turn.at, text: turn.text, isConfirmed: true))
    }

    // MARK: -

    /// The words in what the engine said, or nil when there are none.
    /// Whisper names a stretch with no speech in it — `[BLANK_AUDIO]`,
    /// `(silence)`, `[MUSIC]` — instead of leaving it blank; the names come
    /// out, and a stretch with nothing else in it is not a turn.
    private static func words(in text: String) -> String? {
        let unmarked = text.replacingOccurrences(
            of: #"\[[^\]]*\]|\([^)]*\)"#, with: " ", options: .regularExpression)
        let words = unmarked.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return words.contains { $0.isLetter || $0.isNumber } ? words : nil
    }

    private static func turn(_ text: String, from stretch: Stretch) -> MeetingTurn {
        MeetingTurn(
            speaker: stretch.side == .you ? .you : .them(nil),
            at: stretch.at,
            text: text)
    }

    /// By the time each was said. Two that began together stay in the order
    /// they were decoded, so the file does not shuffle them between runs.
    private static func inOrder(_ turns: [MeetingTurn]) -> [MeetingTurn] {
        turns.enumerated()
            .sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }
            .map(\.element)
    }
}
