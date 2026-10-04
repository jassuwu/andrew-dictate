/// what a prewarm reports while it runs: the download, then the compile.
enum TranscriptionPreparationUpdate: Sendable {
    case downloading(progress: Double)
    case warmingUp
}

/// the engine, as everything outside it sees it. its own file, apart from
/// `SpeechEngine`, so the test bundle — which links no FluidAudio — can
/// drive the dictation path against a fake one. Sendable because the
/// utterance machine hands it samples from the main actor.
protocol TranscriptionEngine: Sendable {
    func prewarm(
        progressHandler: (@Sendable (TranscriptionPreparationUpdate) -> Void)?
    ) async throws
    func transcribe(_ samples: [Float]) async throws -> String
    /// a short pass over nothing, so the next take finds the engine awake:
    /// the neural engine idles down between dictations and a take handed to
    /// it cold waits on it. asked at key-down, answered in its own time.
    func wake() async
}

extension TranscriptionEngine {
    /// an engine with nothing to wake.
    func wake() async {}
}
