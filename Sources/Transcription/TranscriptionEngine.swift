import FluidAudio

protocol TranscriptionEngine {
    func prewarm() async throws
    func transcribe(_ samples: [Float]) async throws -> String
}

actor ParakeetEngine: TranscriptionEngine {
    private struct Preparation {
        let identifier: Int
        let task: Task<AsrManager, Error>
    }

    private var manager: AsrManager?
    private var preparation: Preparation?
    private var nextPreparationIdentifier = 0

    func prewarm() async throws {
        _ = try await preparedManager()
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        let manager = try await preparedManager()
        let decoderLayerCount = await manager.decoderLayerCount
        var decoderState = TdtDecoderState.make(decoderLayers: decoderLayerCount)

        print("transcribing audio")
        let result = try await manager.transcribe(
            samples,
            decoderState: &decoderState
        )
        print("transcription complete")

        return result.text
    }

    private func preparedManager() async throws -> AsrManager {
        if let manager {
            return manager
        }

        let pendingPreparation: Preparation
        if let preparation {
            pendingPreparation = preparation
        } else {
            nextPreparationIdentifier += 1
            let newPreparation = Preparation(
                identifier: nextPreparationIdentifier,
                task: Task {
                    try await Self.makePrewarmedManager()
                }
            )
            preparation = newPreparation
            pendingPreparation = newPreparation
        }

        do {
            let preparedManager = try await pendingPreparation.task.value

            if preparation?.identifier == pendingPreparation.identifier {
                manager = preparedManager
                preparation = nil
            }

            return preparedManager
        } catch {
            if preparation?.identifier == pendingPreparation.identifier {
                preparation = nil
            }
            print("transcription engine prewarm failed")
            throw error
        }
    }

    private static func makePrewarmedManager() async throws -> AsrManager {
        print("prewarming transcription engine")
        print("downloading parakeet v2 models if needed")
        let modelDirectory = try await AsrModels.download(version: .v2)

        print("loading parakeet v2 models")
        let models = try await AsrModels.load(
            from: modelDirectory,
            version: .v2
        )
        let manager = AsrManager(config: .default, models: models)

        print("running transcription warmup")
        let decoderLayerCount = await manager.decoderLayerCount
        var decoderState = TdtDecoderState.make(decoderLayers: decoderLayerCount)
        let silence = [Float](repeating: 0, count: 16_000)
        _ = try await manager.transcribe(
            silence,
            decoderState: &decoderState
        )
        print("transcription engine ready")

        return manager
    }
}
