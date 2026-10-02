import FluidAudio
import Foundation

/// the app's own path, as the app runs it: one AsrManager over the Parakeet
/// v2 models, handed the whole utterance at key-up.
/// mirrors apps/mac/Sources/Transcription/TranscriptionEngine.swift, in its
/// manager config, its decoder state, its warm-up and its transcribe call.
struct Batch {
    let manager: AsrManager

    /// the models the app already has on disk. never downloads: a missing
    /// cache is a reason to run the app once, not a 443 MB surprise.
    static func loadModels() async throws -> AsrModels {
        let directory = Folders.parakeetV2
        guard AsrModels.modelsExist(at: directory, version: .v2) else {
            throw FidelityError(
                "the Parakeet v2 models are not at \(directory.path). run the app once so it fetches them."
            )
        }
        return try await AsrModels.load(from: directory, version: .v2)
    }

    init(models: AsrModels) async throws {
        manager = AsrManager(config: .default, models: models)

        // the app's warm-up: a second of silence.
        let decoderLayerCount = await manager.decoderLayerCount
        var decoderState = TdtDecoderState.make(decoderLayers: decoderLayerCount)
        _ = try await manager.transcribe([Float](repeating: 0, count: 16_000), decoderState: &decoderState)
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        let decoderLayerCount = await manager.decoderLayerCount
        var decoderState = TdtDecoderState.make(decoderLayers: decoderLayerCount)
        let result = try await manager.transcribe(samples, decoderState: &decoderState)
        return result.text
    }
}
