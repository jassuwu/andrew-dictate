/// what a prewarm reports while it runs: the download, then the compile.
enum TranscriptionPreparationUpdate: Sendable {
    case downloading(progress: Double)
    case warmingUp
}

/// the engine, as everything outside it sees it. its own file, apart from
/// `ParakeetEngine`, so the test bundle — which links no FluidAudio — can
/// drive the dictation path against a fake one. Sendable because the
/// utterance machine hands it samples from the main actor.
protocol TranscriptionEngine: Sendable {
    func prewarm(
        progressHandler: (@Sendable (TranscriptionPreparationUpdate) -> Void)?
    ) async throws
    func transcribe(_ samples: [Float]) async throws -> String
}
