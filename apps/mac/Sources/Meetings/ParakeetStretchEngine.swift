import FluidAudio
import Foundation

/// Parakeet, v2 or v3, reading a meeting a stretch at a time.
///
/// Its own `ParakeetEngine`, never dictation's: the meeting loads it when it
/// starts and lets it go with the transcriber when it ends, and a stretch
/// never waits behind a dictation take or holds one up. Everything else is
/// dictation's own code — the download if the model is missing, the load,
/// the warm-up, one decode at a time through the engine's gate.
struct ParakeetStretchEngine: StretchEngine {
    /// The longest stretch it is handed: the 15 s parakeet's encoder reads
    /// in one pass. Past that FluidAudio cuts the audio into windows of its
    /// own and stitches them back.
    static let ceiling = Duration.seconds(15)

    /// Parakeet refuses anything under 0.3 s. A stretch can be shorter —
    /// the tail of talk cut at the ceiling, or speech closed by a gap — and
    /// a word in it is still a word, so it is padded out with silence.
    private static let shortest = ASRConstants.minimumRequiredSamples(
        forSampleRate: Int(MeetingAudioChunk.sampleRate))

    private let engine: ParakeetEngine

    init(model: SpeechModel) {
        engine = ParakeetEngine(version: model)
    }

    func load() async throws {
        try await engine.prewarm(progressHandler: nil)
    }

    func text(of samples: [Float]) async throws -> String {
        guard samples.count < Self.shortest else {
            return try await engine.transcribe(samples)
        }
        let silence = [Float](repeating: 0, count: Self.shortest - samples.count)
        return try await engine.transcribe(samples + silence)
    }
}
