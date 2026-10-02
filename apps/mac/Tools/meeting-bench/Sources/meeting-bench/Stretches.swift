import FluidAudio
import Foundation

/// a stretch of one side's speech, cut at a pause or at the cap.
struct Stretch: Codable, Sendable {
    let side: Side
    /// seconds into the meeting.
    let start: Double
    let end: Double
    /// when the VAD could know the stretch was over: the end plus the pause it
    /// waited for, or the moment the cap was hit. the plan says a stretch is
    /// available at `end`; the live run cannot be earlier than this.
    let detectedAt: Double

    var seconds: Double { end - start }
}

/// Silero's speech probability, one number per 4096 samples (256 ms), turned
/// into stretches. the same rules FluidAudio's own state machine uses
/// (enter above `threshold`, leave after `minSilence` below `negativeThreshold`),
/// plus a cap it does not have in streaming: when a stretch reaches `cap`
/// seconds it is cut at the quietest chunk of its last `cutWindow` seconds.
///
/// it is fed one probability at a time, so the offline pass and the paced run
/// share it and cannot disagree.
struct Segmenter {
    static let chunk = 4_096
    static let chunkSeconds = Double(chunk) / Double(sampleRate)

    struct Settings: Sendable {
        /// FluidAudio's VadConfig default entry threshold, and its default offset below it.
        var threshold: Float = 0.85
        var negativeThreshold: Float = 0.70
        var minSilence = 0.5
        var minSpeech = 0.25
        var pad = 0.1
        var cap: Double
        var cutWindow = 6.0
    }

    let side: Side
    let settings: Settings
    private var index = 0
    private var speechStart: Double?
    private var silenceStart: Double?
    private var quietest: (probability: Float, time: Double)?

    init(side: Side, settings: Settings) {
        self.side = side
        self.settings = settings
    }

    mutating func push(_ probability: Float) -> [Stretch] {
        let t0 = Double(index) * Self.chunkSeconds
        let t1 = t0 + Self.chunkSeconds
        index += 1
        var done: [Stretch] = []

        if probability >= settings.threshold {
            silenceStart = nil
            if speechStart == nil { speechStart = t0 }
        } else if probability < settings.negativeThreshold, let start = speechStart {
            let silence = silenceStart ?? t0
            silenceStart = silence
            if t1 - silence >= settings.minSilence {
                done += emit(start: start, end: silence, now: t1)
                speechStart = nil
                silenceStart = nil
                quietest = nil
            }
        }

        if let start = speechStart {
            if t1 - start >= settings.cap - settings.cutWindow,
               quietest == nil || probability <= quietest!.probability {
                quietest = (probability, t0 + Self.chunkSeconds / 2)
            }
            if t1 - start >= settings.cap {
                let cut = quietest?.time ?? t1
                done += emit(start: start, end: cut, now: t1)
                speechStart = cut
                silenceStart = nil
                quietest = nil
            }
        }
        return done
    }

    /// the meeting ended mid-speech: whatever is open is a stretch.
    mutating func finish(total: Double) -> [Stretch] {
        defer { speechStart = nil }
        guard let start = speechStart else { return [] }
        return emit(start: start, end: total, now: total, padEnd: false)
    }

    private func emit(start: Double, end: Double, now: Double, padEnd: Bool = true) -> [Stretch] {
        let padded = (max(0, start - settings.pad), min(now, end + (padEnd ? settings.pad : 0)))
        guard padded.1 - padded.0 >= settings.minSpeech else { return [] }
        return [Stretch(side: side, start: padded.0, end: padded.1, detectedAt: now)]
    }
}

/// Silero VAD from FluidAudio, one streaming state per side.
final class SileroProbabilities {
    private let vad: VadManager
    private var state: VadStreamState

    private init(vad: VadManager) {
        self.vad = vad
        state = VadStreamState.initial()
    }

    static func load() async throws -> VadManager {
        try await VadManager()
    }

    static func makeStream(vad: VadManager) -> SileroProbabilities {
        SileroProbabilities(vad: vad)
    }

    /// speech probability of the next 4096 samples.
    func next(_ chunk: [Float]) async throws -> Float {
        let result = try await vad.processStreamingChunk(chunk, state: state)
        state = result.state
        return result.probability
    }
}

enum Stretching {
    /// every stretch of one side, offline. the same chunks, the same state
    /// machine, only not paced.
    static func cut(
        _ samples: [Float], side: Side, vad: VadManager, settings: Segmenter.Settings
    ) async throws -> [Stretch] {
        let probabilities = SileroProbabilities.makeStream(vad: vad)
        var segmenter = Segmenter(side: side, settings: settings)
        var stretches: [Stretch] = []
        var offset = 0
        while offset + Segmenter.chunk <= samples.count {
            let p = try await probabilities.next(Array(samples[offset..<offset + Segmenter.chunk]))
            stretches += segmenter.push(p)
            offset += Segmenter.chunk
        }
        stretches += segmenter.finish(total: Double(samples.count) / Double(sampleRate))
        return stretches
    }

    static func samples(of stretch: Stretch, in audio: [Float]) -> [Float] {
        let start = max(0, Int(stretch.start * Double(sampleRate)))
        let end = min(audio.count, Int(stretch.end * Double(sampleRate)))
        return Array(audio[start..<max(start, end)])
    }
}
