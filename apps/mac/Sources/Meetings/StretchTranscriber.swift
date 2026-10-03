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
    /// Stretches the engine threw on, or did not answer in time, twice.
    /// Their words are not in the file.
    var failed = 0
    /// Tries the engine did not answer in time: a call wedged in CoreML,
    /// most likely, rather than audio it could not read. Each is a try that
    /// failed, so a stretch that timed out twice is in `failed` too.
    var timedOut = 0
    /// Stretches cut and never decoded, because `finish` stopped waiting for
    /// them or the model never came: not decoded, and not failed. Their
    /// speech is speech that was not read.
    var unfinished = 0
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

    /// How long the engine is waited on before what it has not done is let
    /// go. One call that never comes back would otherwise hold the only
    /// worker for good: every stretch after it queued with its audio, the
    /// panel stopped, and `finish` never returning, so the meeting sat on
    /// `writing it out` until quit. Provisional, like every number a meeting
    /// runs on.
    struct Patience: Sendable {
        /// One try at a stretch gets this…
        var decode: Duration = .seconds(10)
        /// …and this much more for every second of the stretch. Whisper
        /// reads a stretch in a fraction of its length, so a try that runs
        /// past both is a wedge, not a slow day.
        var decodePerSecond: Double = 1
        /// `finish` gets this, from when it is called, for the model still
        /// loading and every stretch still to decode; after it, it returns
        /// what it has.
        var finish: Duration = .seconds(60)

        static let provisional = Patience()

        /// For one try at `stretch`.
        func decoding(_ stretch: Stretch) -> Duration {
            decode + (stretch.end - stretch.at) * decodePerSecond
        }
    }

    nonisolated let lines: AsyncStream<LiveLine>

    private let emit: AsyncStream<LiveLine>.Continuation
    private let engine: any StretchEngine
    private let makeDetector: @Sendable () -> any SpeechDetector
    private let ceiling: Duration
    private let patience: Patience
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
    /// The worker has a stretch with the engine.
    private var isDecoding = false
    /// `finish` has stopped waiting: nothing decoded from here is kept or
    /// counted.
    private var gaveUp = false
    private var turns: [MeetingTurn] = []
    private(set) var tally = StretchTally()

    /// The 100 ms the capture layer hands over, so a spool is heard in the
    /// same steps the meeting was.
    private static let spoolChunk = 1_600

    /// The far side a spool opens with that is the start sound, in samples.
    private static let startSoundInASpool = StretchCutter.samples(
        in: OurTones.silenced(for: OurTones.startSound))

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
    /// side; `now` is the wall the decoding is timed against, and
    /// `patience` how long it is waited on, by the real clock.
    init(
        engine: any StretchEngine,
        ceiling: Duration,
        detector makeDetector: @escaping @Sendable () -> any SpeechDetector = { LoudnessDetector() },
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        patience: Patience = .provisional
    ) {
        self.engine = engine
        self.ceiling = ceiling
        self.patience = patience
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

    /// Waits for what is left to decode, as long as `patience` says and no
    /// longer: past that, the meeting is written out with what was read,
    /// and the stretches still waiting, or being decoded, are let go and
    /// counted, their speech not read, for the coverage check to see.
    func finish() async -> [MeetingTurn] {
        await hearing?.value
        isFinished = true
        queue(withoutBleed(you.flush(), mic: micLoudness, far: farLoudness) + them.flush())
        let limit = patience.finish
        let decoded = (try? await Deadline.race(limit) { [self] in
            await self.decodeWhatIsLeft()
        }) != nil
        if !decoded {
            logger.error("stopped waiting for the decoding after \(limit.totalSeconds, format: .fixed(precision: 0), privacy: .public) s")
        }
        letGoOfWhatIsLeft()
        emit.finish()
        return Self.inOrder(turns)
    }

    /// A whole spool already in memory: walked a block at a time like one
    /// read off the disk, each block a slice of the two sides taken when it
    /// is asked for.
    func transcribe(you: [Float], them: [Float]) async throws -> [MeetingTurn] {
        try await transcribe(blocks: Self.blocks(of: you, them))
    }

    /// A whole spool, heard the way the meeting was: in the chunks the
    /// capture layer hands over, through a fresh detector per side, and the
    /// far side coming back through the mic let go the same way. Each stretch
    /// is decoded as soon as it is cut, and the next block is read only once
    /// the one before it has been heard, so no more of the spool is in
    /// memory than a meeting holds as it is recorded: a block, the quiet
    /// the cutters keep, the stretch being decoded and the minute of
    /// loudness the trails keep. A spool has no gaps in it, so its clock is
    /// its sample count.
    ///
    /// The two sides are walked together, a chunk at a time: a `you` stretch
    /// is held against how loud the far side was while it was said, and that
    /// is only known once the far side has been heard up to there.
    ///
    /// It throws when there was speech and not one stretch of it decoded:
    /// written out, that would read as a meeting where nobody spoke, and the
    /// spool — the only copy of what was said — would go with it. Thrown, it
    /// stays for the next launch. A spool nobody spoke in has nothing to
    /// fail on, and comes back with no turns. A block that could not be read
    /// throws too.
    func transcribe(blocks: AsyncThrowingStream<SpoolBlock, any Error>) async throws -> [MeetingTurn] {
        try await load()
        let failedBefore = tally.failed
        var spool = SpoolHearing(
            youDetector: makeDetector(), themDetector: makeDetector(), ceiling: ceiling)
        var steps = SpoolSteps(length: Self.spoolChunk)
        for try await block in blocks {
            steps.add(block)
            while let step = steps.next() {
                await hear(step, in: &spool)
            }
        }
        steps.end()
        while let step = steps.next() {
            await hear(step, in: &spool)
        }
        let last = withoutBleed(spool.you.flush(), mic: spool.mic, far: spool.far) + spool.them.flush()
        spool.cut += last.count
        spool.turns += await decodeAlone(last)
        if spool.cut > 0, tally.failed - failedBefore == spool.cut {
            throw Failure.nothingDecoded(stretches: spool.cut)
        }
        return Self.inOrder(spool.turns)
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

    /// One step of a spool, through that spool's own detectors, cutters and
    /// trails, and whatever it cut decoded there and then.
    ///
    /// A spool opens on the start sound, in the far side, and it is heard
    /// the way the meeting heard it: whole in the trail, as silence by the
    /// detector and the cutter. The start sound after a rebuild and the
    /// quiet probe are where the spool alone cannot say, and are read as
    /// they are.
    private func hear(_ step: SpoolSteps.Step, in spool: inout SpoolHearing) async {
        let at = StretchCutter.duration(of: step.start)
        spool.mic.hear(step.you, at: at)
        spool.far.hear(step.them, at: at)
        let theirs = OurTones.silencing(step.them, first: Self.startSoundInASpool - step.start)
        var stretches: [Stretch] = []
        if !step.you.isEmpty {
            let edges = await spool.youDetector.hear(step.you)
            stretches += withoutBleed(
                spool.you.take(step.you, at: at, edges: edges), mic: spool.mic, far: spool.far)
        }
        if !theirs.isEmpty {
            let edges = await spool.themDetector.hear(theirs)
            stretches += spool.them.take(theirs, at: at, edges: edges)
        }
        spool.cut += stretches.count
        spool.turns += await decodeAlone(stretches)
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
        while !waiting.isEmpty, !gaveUp {
            let (stretch, queued) = waiting.removeFirst()
            isDecoding = true
            let text = await decode(stretch, queued: true)
            isDecoding = false
            guard !gaveUp else { break }
            let behind = now() - queued
            tally.lastBehind = behind
            tally.mostBehind = max(tally.mostBehind, behind)
            if let text {
                keep(text, from: stretch)
            }
        }
        worker = nil
    }

    /// What `finish` waits for: a model still loading — a meeting stopped
    /// in its first seconds must not be written out with none of its words
    /// — and then the worker, until the queue is empty. A model that failed,
    /// or was never asked to load, has nothing to wait for.
    private func decodeWhatIsLeft() async {
        if let loading, (try? await loading.value) != nil {
            isReady = true
            startWorking()
        }
        while let worker {
            await worker.value
        }
    }

    /// The end of `finish`: whatever is still waiting, or still being
    /// decoded, is not going to be read. A decode that comes back after
    /// this is let go where it lands.
    private func letGoOfWhatIsLeft() {
        gaveUp = true
        let left = waiting.count + (isDecoding ? 1 : 0)
        guard left > 0 else { return }
        tally.unfinished += left
        waiting.removeAll()
        logger.error("\(left, privacy: .public) stretches were never decoded")
    }

    /// A stretch the engine throws on, or does not answer in time, gets one
    /// more try: a decode that failed once is often a hiccup, not the
    /// audio. Twice, and it is let go and counted. A call that never comes
    /// back is left where it is, and the worker goes on without it.
    ///
    /// `queued` is a stretch off the meeting's queue, which `finish` may
    /// have stopped waiting for while the engine had it: then nothing is
    /// counted, as it already has been.
    private func decode(_ stretch: Stretch, queued: Bool = false) async -> String? {
        let limit = patience.decoding(stretch)
        for attempt in 1...2 {
            do {
                let text = try await Deadline.race(limit) { [engine, samples = stretch.samples] in
                    try await engine.text(of: samples)
                }
                if queued, gaveUp { return nil }
                switch stretch.side {
                case .you:
                    tally.decodedYou += 1
                    tally.readYou += stretch.end - stretch.at
                case .them:
                    tally.decodedThem += 1
                    tally.readThem += stretch.end - stretch.at
                }
                return text
            } catch is Deadline.Passed {
                if queued, gaveUp { return nil }
                tally.timedOut += 1
                logger.error("a stretch was not decoded in \(limit.totalSeconds, format: .fixed(precision: 1), privacy: .public) s, try \(attempt)")
            } catch {
                if queued, gaveUp { return nil }
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

    /// Two sides in memory as blocks of a spool, sliced as each is asked
    /// for. A side shorter than the other has ended, and its blocks are
    /// short, then empty.
    private static func blocks(of you: [Float], _ them: [Float]) -> AsyncThrowingStream<SpoolBlock, any Error> {
        let next = OSAllocatedUnfairLock(initialState: 0)
        return AsyncThrowingStream(unfolding: {
            let start = next.withLock { start in
                defer { start += spoolChunk }
                return start
            }
            guard start < max(you.count, them.count) else { return nil }
            func slice(_ side: [Float]) -> [Float] {
                start < side.count ? Array(side[start..<min(start + spoolChunk, side.count)]) : []
            }
            return (slice(you), slice(them))
        })
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

/// One spool's hearing, fresh for it: a detector, a cutter and a loudness
/// trail per side, the stretches cut so far and the turns they came to.
private struct SpoolHearing {
    let youDetector: any SpeechDetector
    let themDetector: any SpeechDetector
    var you: StretchCutter
    var them: StretchCutter
    var mic = LoudnessTrail()
    var far = LoudnessTrail()
    var cut = 0
    var turns: [MeetingTurn] = []

    init(youDetector: any SpeechDetector, themDetector: any SpeechDetector, ceiling: Duration) {
        self.youDetector = youDetector
        self.themDetector = themDetector
        you = StretchCutter(side: .you, ceiling: ceiling)
        them = StretchCutter(side: .them, ceiling: ceiling)
    }
}

/// Blocks of a spool, as long as the disk hands them over, as the steps a
/// meeting is heard in: `length` samples of each side at a time, both from
/// the same sample. A side shorter than the other in a block has ended
/// there — a spool with one channel has no far side at all — and its steps
/// are short, then empty, from there on. What it holds is the block it was
/// last given, and less than a step of the one before.
private struct SpoolSteps {
    struct Step {
        /// The spool's sample it begins at.
        let start: Int
        let you: [Float]
        let them: [Float]
    }

    let length: Int
    private var you: [Float] = []
    private var them: [Float] = []
    private var youEnded = false
    private var themEnded = false
    private var start = 0

    init(length: Int) {
        self.length = length
    }

    mutating func add(_ block: SpoolBlock) {
        you += block.you
        them += block.them
        if block.you.count < block.them.count { youEnded = true }
        if block.them.count < block.you.count { themEnded = true }
    }

    /// No more blocks are coming.
    mutating func end() {
        youEnded = true
        themEnded = true
    }

    /// The next step, once each side has a whole one or has ended.
    mutating func next() -> Step? {
        guard you.count >= length || youEnded,
              them.count >= length || themEnded,
              !you.isEmpty || !them.isEmpty
        else { return nil }
        let step = Step(start: start, you: Array(you.prefix(length)), them: Array(them.prefix(length)))
        you.removeFirst(step.you.count)
        them.removeFirst(step.them.count)
        start += length
        return step
    }
}
