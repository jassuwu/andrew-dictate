import Foundation
import WhisperKit
import os

/// Whisper, streamed by hand.
///
/// WhisperKit's own streamer wants to own the microphone and re-transcribes
/// an ever-growing tail; the spike watched its cadence slide from one
/// second to seven. This does the same idea with the reins held: one buffer
/// of the meeting so far, a pass every second or so over everything since
/// the last confirmed segment, every segment but the newest confirmed on the
/// spot, the newest shown dimmed until the next pass agrees. A window that
/// reaches 28 s is confirmed whole, so the work never grows past a whisper
/// window.
///
/// Both sides are mixed into one stream and labelled afterwards by which
/// channel was louder while the segment was spoken. One decode instead of
/// two: large-v3 runs at a quarter of realtime and two of them would not.
actor WhisperMeetingTranscriber: MeetingTranscriber {
    nonisolated let lines: AsyncStream<LiveLine>

    private let emit: AsyncStream<LiveLine>.Continuation
    private let model: MeetingModel
    private let logger = Logger(subsystem: AppIdentity.loggingSubsystem, category: "whisper")

    private var whisper: WhisperKit?
    /// Only the audio since the last confirmed segment; what is behind that
    /// point is on the spool, not in memory. `mixedOffset` is the meeting
    /// sample index of `mixed[0]`.
    private var mixed: [Float] = []
    private var mixedOffset = 0
    /// One entry per 100 ms of the meeting: RMS of each side.
    private var energies: [(you: Float, them: Float)] = []
    private var confirmedUpTo = 0
    private var confirmedTurns: [MeetingTurn] = []
    private var tentativeID: UUID?
    private var worker: Task<Void, Never>?
    private var isRunning = false
    private var isDecoding = false

    private static let sampleRate = Int(MeetingAudioChunk.sampleRate)
    private static let energyBucket = 1_600
    private static let minimumPass = 2 * sampleRate
    private static let confirmWholeWindowAt = 28 * sampleRate

    init(model: MeetingModel) {
        self.model = model
        (lines, emit) = AsyncStream<LiveLine>.makeStream()
    }

    // MARK: - MeetingTranscriber

    func begin() async throws {
        whisper = try await Self.load(model)
        isRunning = true
        worker = Task { [weak self] in
            while let self, await self.isRunning {
                try? await Task.sleep(for: .seconds(1))
                await self.pass(final: false)
            }
        }
    }

    func feed(_ chunk: MeetingAudioChunk) {
        let (mix, buckets) = Self.mixAndBucket(you: chunk.you, them: chunk.them)
        mixed.append(contentsOf: mix)
        energies.append(contentsOf: buckets)
    }

    func finish() async -> [MeetingTurn] {
        isRunning = false
        worker?.cancel()
        while isDecoding {
            try? await Task.sleep(for: .milliseconds(50))
        }
        await pass(final: true)
        emit.finish()
        whisper = nil
        return confirmedTurns
    }

    func transcribe(you: [Float], them: [Float]) async throws -> [MeetingTurn] {
        let whisper = try await Self.load(model)
        let (mix, buckets) = Self.mixAndBucket(you: you, them: them)

        var options = decodingOptions()
        options.chunkingStrategy = .vad
        let results = try await whisper.transcribe(audioArray: mix, decodeOptions: options)
        return Self.segments(of: results).map { segment in
            let start = Double(segment.start)
            let end = Double(segment.end)
            return MeetingTurn(
                speaker: Self.speaker(from: start, to: end, energies: buckets),
                at: .seconds(start),
                text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: - the loop

    private func pass(final: Bool) async {
        guard let whisper, !isDecoding else { return }
        let start = confirmedUpTo
        let end = mixedOffset + mixed.count
        let pending = end - start
        guard pending >= Self.minimumPass || (final && pending > Self.sampleRate / 2) else { return }

        isDecoding = true
        defer { isDecoding = false }

        let window = Array(mixed[(start - mixedOffset)..<(end - mixedOffset)])
        var options = decodingOptions()
        if window.count > 30 * Self.sampleRate {
            options.chunkingStrategy = .vad
        }
        let results: [TranscriptionResult]
        do {
            results = try await whisper.transcribe(audioArray: window, decodeOptions: options)
        } catch {
            logger.error("whisper pass failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        let segments = Self.segments(of: results)
        let confirmWhole = final || window.count >= Self.confirmWholeWindowAt
        let confirmCount = confirmWhole ? segments.count : max(segments.count - 1, 0)
        let base = Double(start) / Double(Self.sampleRate)

        for (index, segment) in segments.prefix(confirmCount).enumerated() {
            let at = base + Double(segment.start)
            let turn = MeetingTurn(
                speaker: Self.speaker(from: at, to: base + Double(segment.end), energies: energies),
                at: .seconds(at),
                text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines))
            confirmedTurns.append(turn)
            // The first newly confirmed line takes over the dimmed one's id,
            // so the panel replaces it instead of showing both.
            let id = (index == 0 ? tentativeID : nil) ?? UUID()
            emit.yield(LiveLine(
                id: id, speaker: Self.liveSpeaker(turn.speaker), at: turn.at,
                text: turn.text, isConfirmed: true))
        }
        if confirmCount > 0 {
            tentativeID = nil
            let lastEnd = Double(segments[confirmCount - 1].end)
            confirmedUpTo = min(end, start + Int(lastEnd * Double(Self.sampleRate)))
        } else if confirmWhole {
            // A whole window of nothing worth keeping: silence, or noise
            // whisper declined. Move on rather than re-decoding it forever.
            confirmedUpTo = end
        }
        if confirmedUpTo > mixedOffset {
            mixed.removeFirst(min(mixed.count, confirmedUpTo - mixedOffset))
            mixedOffset = confirmedUpTo
        }

        if !confirmWhole, let tail = segments.last {
            let at = base + Double(tail.start)
            let id = tentativeID ?? UUID()
            tentativeID = id
            emit.yield(LiveLine(
                id: id,
                speaker: Self.liveSpeaker(Self.speaker(from: at, to: base + Double(tail.end), energies: energies)),
                at: .seconds(at),
                text: tail.text.trimmingCharacters(in: .whitespacesAndNewlines),
                isConfirmed: false))
        }
    }

    private func decodingOptions() -> DecodingOptions {
        var options = DecodingOptions()
        options.task = model.translatesToEnglish ? .translate : .transcribe
        options.language = nil
        options.detectLanguage = true
        options.usePrefillPrompt = true
        options.skipSpecialTokens = true
        options.withoutTimestamps = false
        options.temperature = 0
        return options
    }

    // MARK: - helpers

    private static func load(_ model: MeetingModel) async throws -> WhisperKit {
        try await WhisperKit(WhisperKitConfig(
            model: model.whisperVariant,
            downloadBase: MeetingEngines.modelDirectory,
            modelFolder: MeetingEngines.folder(for: model).path,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: false))
    }

    private static func segments(of results: [TranscriptionResult]) -> [TranscriptionSegment] {
        results
            .flatMap(\.segments)
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start < $1.start }
    }

    /// Whoever was louder while it was said. Overlap goes to the far side —
    /// it is the one being translated, and the one you cannot hear yourself.
    private static func speaker(
        from start: Double, to end: Double,
        energies: [(you: Float, them: Float)]
    ) -> MeetingTurn.Speaker {
        let bucketSeconds = Double(energyBucket) / Double(sampleRate)
        let first = max(0, Int(start / bucketSeconds))
        let last = min(energies.count, max(first + 1, Int(end / bucketSeconds)))
        guard first < last else { return .them(nil) }
        var you: Float = 0, them: Float = 0
        for bucket in energies[first..<last] {
            you += bucket.you
            them += bucket.them
        }
        return you > them * 1.5 ? .you : .them(nil)
    }

    private static func liveSpeaker(_ speaker: MeetingTurn.Speaker) -> LiveLine.Speaker {
        if case .you = speaker { .you } else { .them }
    }

    /// Both sides summed into one clamped stream, plus each side's loudness
    /// per 100 ms — the two things every decode needs, made the same way.
    private static func mixAndBucket(
        you: [Float], them: [Float]
    ) -> (mix: [Float], buckets: [(you: Float, them: Float)]) {
        let n = min(you.count, them.count)
        var mix = [Float](repeating: 0, count: n)
        for i in 0..<n { mix[i] = max(-1, min(1, you[i] + them[i])) }
        var buckets: [(you: Float, them: Float)] = []
        var offset = 0
        while offset < n {
            let end = min(offset + energyBucket, n)
            buckets.append((rms(you[offset..<end]), rms(them[offset..<end])))
            offset = end
        }
        return (mix, buckets)
    }

    private static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }
}
