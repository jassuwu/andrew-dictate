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
    /// `you` stretches let go before they were decoded, because they were only
    /// the far side coming back through the mic. Not decoded, not failed.
    var bleed = 0
    /// Stretches read, and let go because they were room noise the engine put
    /// a stock phrase to. Counted as read too: the engine did read them.
    var quietDropped = 0
    /// How far behind the meeting the decoding ran: from a stretch joining
    /// the queue to its decode finishing, the worst of the meeting and the
    /// latest.
    var mostBehind: Duration = .zero
    var lastBehind: Duration = .zero
    /// Speech cut into stretches, per side: bleed let go is not counted. Of
    /// that, what the engine read — handed a stretch, it gave text back,
    /// words or none. A stretch that failed twice, or was still waiting when
    /// the engine never came, is speech that was not read; the coverage
    /// check holds the difference against the transcript.
    var speechYou: Duration = .zero
    var speechThem: Duration = .zero
    var readYou: Duration = .zero
    var readThem: Duration = .zero
}

/// A meeting heard a stretch at a time, each stretch decoded once.
///
/// A detector finds where speech begins and ends, a cutter cuts the speech
/// out, and the stretches wait in one queue, in the order they ended, for a
/// single worker to hand to the engine. A stretch becomes one turn and one
/// confirmed live line; nothing is decoded twice, and nothing is shown that
/// might change.
actor StretchTranscriber: MeetingTranscriber {
    enum Failure: Error, LocalizedError {
        /// A spool had speech in it and the engine threw on every stretch.
        case nothingDecoded(stretches: Int)

        var errorDescription: String? {
            switch self {
            case .nothingDecoded(let stretches):
                "none of the \(stretches) stretches of speech would decode"
            }
        }
    }

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
    /// How loud each side has been, for the last minute. A `you` stretch is
    /// held against them when it ends, to tell it from the far side coming
    /// back through the mic.
    private var micLoudness = LoudnessTrail()
    private var farLoudness = LoudnessTrail()

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

    /// A stretch this quiet, over all of it, is room noise: a real recording
    /// with nothing on the mic measured about 0.003. Provisional, to be
    /// tuned against real meetings.
    private static let quietBelow: Float = 0.006

    /// What whisper writes over room noise, from the subtitles it learned
    /// on, lowercased and without punctuation. Said over a quiet stretch
    /// these are not words that were said; over a loud one they may be.
    private static let inventedOnQuiet: Set<String> = [
        "thank you", "thank you very much", "thanks for watching",
        "thank you for watching", "thanks", "bye", "bye bye", "you",
        "please subscribe", "subtitles by the amara org community",
    ]

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
        await feed(chunk, tone: 0)
    }

    func feed(_ chunk: MeetingAudioChunk, tone: Int) async {
        let before = hearing
        let this = Task {
            await before?.value
            await hear(chunk, tone: tone)
        }
        hearing = this
        await this.value
    }

    func finish() async -> [MeetingTurn] {
        await hearing?.value
        isFinished = true
        queue(withoutBleed(you.flush(), mic: micLoudness, far: farLoudness) + them.flush())
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
    /// capture layer hands over, through a fresh detector per side, and the
    /// far side coming back through the mic let go the same way. Each stretch
    /// is decoded as soon as it is cut, so the speech is not copied out whole
    /// beside a recording that is already all in memory. A spool has no gaps
    /// in it, so its clock is its sample count.
    ///
    /// The two sides are walked together, a chunk at a time: a `you` stretch
    /// is held against how loud the far side was while it was said, and that
    /// is only known once the far side has been heard up to there.
    ///
    /// It throws when there was speech and not one stretch of it decoded:
    /// written out, that would read as a meeting where nobody spoke, and the
    /// spool — the only copy of what was said — would go with it. Thrown, it
    /// stays for the next launch. A spool nobody spoke in has nothing to
    /// fail on, and comes back with no turns.
    func transcribe(you: [Float], them: [Float]) async throws -> [MeetingTurn] {
        try await load()
        var turns: [MeetingTurn] = []
        var cut = 0
        let failedBefore = tally.failed
        let youDetector = makeDetector()
        let themDetector = makeDetector()
        var youCutter = StretchCutter(side: .you, ceiling: ceiling)
        var themCutter = StretchCutter(side: .them, ceiling: ceiling)
        var mic = LoudnessTrail()
        var far = LoudnessTrail()
        var start = 0
        while start < max(you.count, them.count) {
            let at = StretchCutter.duration(of: start)
            let youChunk = Self.chunk(of: you, from: start)
            let themChunk = Self.chunk(of: them, from: start)
            mic.hear(youChunk, at: at)
            far.hear(themChunk, at: at)
            var stretches: [Stretch] = []
            if !youChunk.isEmpty {
                let edges = await youDetector.hear(youChunk)
                stretches += withoutBleed(
                    youCutter.take(youChunk, at: at, edges: edges), mic: mic, far: far)
            }
            if !themChunk.isEmpty {
                let edges = await themDetector.hear(themChunk)
                stretches += themCutter.take(themChunk, at: at, edges: edges)
            }
            cut += stretches.count
            turns += await decodeAlone(stretches)
            start += Self.spoolChunk
        }
        let last = withoutBleed(youCutter.flush(), mic: mic, far: far) + themCutter.flush()
        cut += last.count
        turns += await decodeAlone(last)
        if cut > 0, tally.failed - failedBefore == cut {
            throw Failure.nothingDecoded(stretches: cut)
        }
        return Self.inOrder(turns)
    }

    func decodeTally() async -> StretchTally? {
        tally
    }

    // MARK: - hearing

    /// The far side's trail hears it as the tap did, a tone of ours and
    /// all: that is what the mic can hear coming back. Its detector and its
    /// cutter hear the tone as silence, so no stretch begins on it and none
    /// hands it to the engine.
    private func hear(_ chunk: MeetingAudioChunk, tone: Int) async {
        guard !isFinished else { return }
        micLoudness.hear(chunk.you, at: chunk.at)
        farLoudness.hear(chunk.them, at: chunk.at)
        let theirs = OurTones.silencing(chunk.them, first: tone)
        let youEdges = await youDetector.hear(chunk.you)
        let themEdges = await themDetector.hear(theirs)
        queue(withoutBleed(
            you.take(chunk.you, at: chunk.at, edges: youEdges),
            mic: micLoudness, far: farLoudness)
            + them.take(theirs, at: chunk.at, edges: themEdges))
    }

    /// A `you` stretch that is only the far side coming back through the mic
    /// goes no further: it is counted, and the engine never hears it.
    /// `them` is never in doubt.
    private func withoutBleed(
        _ stretches: [Stretch], mic: LoudnessTrail, far: LoudnessTrail
    ) -> [Stretch] {
        var kept: [Stretch] = []
        for stretch in stretches {
            if stretch.side == .you,
               BleedJudge.verdict(mic: mic, far: far, from: stretch.at, to: stretch.speechEnd) == .drop
            {
                tally.bleed += 1
            } else {
                kept.append(stretch)
            }
        }
        return kept
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
            countSpeech(in: stretch)
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
                case .you:
                    tally.decodedYou += 1
                    tally.readYou += stretch.end - stretch.at
                case .them:
                    tally.decodedThem += 1
                    tally.readThem += stretch.end - stretch.at
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
            countSpeech(in: stretch)
            guard let text = await decode(stretch), let turn = read(text, from: stretch) else { continue }
            turns.append(turn)
        }
        return turns
    }

    /// Counted when it is cut, whatever becomes of it after.
    private func countSpeech(in stretch: Stretch) {
        switch stretch.side {
        case .you: tally.speechYou += stretch.end - stretch.at
        case .them: tally.speechThem += stretch.end - stretch.at
        }
    }

    private func keep(_ text: String, from stretch: Stretch) {
        guard let turn = read(text, from: stretch) else { return }
        turns.append(turn)
        let speaker: LiveLine.Speaker = stretch.side == .you ? .you : .them
        emit.yield(LiveLine(speaker: speaker, at: turn.at, text: turn.text, isConfirmed: true))
    }

    // MARK: -

    /// The turn a stretch's text makes, or nil when it makes none: there are
    /// no words in it, or the stretch was room noise and the words are ones
    /// whisper writes over room noise. That one is counted.
    private func read(_ text: String, from stretch: Stretch) -> MeetingTurn? {
        guard let words = Self.words(in: text) else { return nil }
        if Self.isInvented(words, over: stretch) {
            tally.quietDropped += 1
            return nil
        }
        return Self.turn(words, from: stretch)
    }

    /// The chunk of a spool's side that begins at `start`: the last may be
    /// short, and a side that has ended is empty.
    private static func chunk(of samples: [Float], from start: Int) -> [Float] {
        guard start < samples.count else { return [] }
        return Array(samples[start..<min(start + spoolChunk, samples.count)])
    }

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

    private static func isInvented(_ words: String, over stretch: Stretch) -> Bool {
        let plain = words.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
        return inventedOnQuiet.contains(plain) && rms(of: stretch.samples) < quietBelow
    }

    private static func rms(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }

    private static func turn(_ text: String, from stretch: Stretch) -> MeetingTurn {
        MeetingTurn(
            speaker: stretch.side == .you ? .you : .them(nil),
            at: stretch.at,
            text: text,
            end: stretch.end)
    }

    /// By the time each was said. Two that began together stay in the order
    /// they were decoded, so the file does not shuffle them between runs.
    private static func inOrder(_ turns: [MeetingTurn]) -> [MeetingTurn] {
        turns.enumerated()
            .sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }
            .map(\.element)
    }
}
