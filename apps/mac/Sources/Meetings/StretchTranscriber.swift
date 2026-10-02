import Foundation
import os

/// The model a meeting is read with, one stretch at a time.
protocol StretchEngine: Sendable {
    /// Once, before the first stretch. Slow: whisper takes ten-odd seconds.
    func load() async throws
    /// One stretch of 16 kHz mono speech, start to end, as text.
    func text(of samples: [Float]) async throws -> String
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

    private let youDetector: any SpeechDetector
    private var you = StretchCutter(side: .you)

    /// Each chunk is heard after the one before it has been, whoever calls.
    /// The detector is awaited, so without this a chunk could overtake its
    /// predecessor — or `finish` could flush a side mid-chunk.
    private var hearing: Task<Void, Never>?
    private var loading: Task<Void, any Error>?
    private var isReady = false
    private var isFinished = false
    /// Stretches that have ended and wait for the engine, in the order they
    /// ended. Audio leaves memory when its stretch leaves this queue.
    private var waiting: [Stretch] = []
    private var worker: Task<Void, Never>?
    private var turns: [MeetingTurn] = []

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
        (lines, emit) = AsyncStream<LiveLine>.makeStream()
    }

    // MARK: - MeetingTranscriber

    func begin() async throws {
        let loading = Task { [engine] in try await engine.load() }
        self.loading = loading
        try await loading.value
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
        queue(you.flush())
        while let worker {
            await worker.value
        }
        emit.finish()
        return turns
    }

    func transcribe(you: [Float], them: [Float]) async throws -> [MeetingTurn] {
        []
    }

    // MARK: - hearing

    private func hear(_ chunk: MeetingAudioChunk) async {
        guard !isFinished else { return }
        let edges = await youDetector.hear(chunk.you)
        queue(you.take(chunk.you, at: chunk.at, edges: edges))
    }

    // MARK: - decoding

    private func queue(_ stretches: [Stretch]) {
        for stretch in stretches {
            let index = waiting.firstIndex { $0.end > stretch.end } ?? waiting.endIndex
            waiting.insert(stretch, at: index)
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
            let stretch = waiting.removeFirst()
            guard let text = try? await engine.text(of: stretch.samples) else { continue }
            keep(text, from: stretch)
        }
        worker = nil
    }

    private func keep(_ text: String, from stretch: Stretch) {
        let turn = MeetingTurn(speaker: .you, at: stretch.at, text: text)
        turns.append(turn)
        emit.yield(LiveLine(speaker: .you, at: turn.at, text: turn.text, isConfirmed: true))
    }
}
