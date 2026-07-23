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
    private let version: EngineVersion

    init(version: EngineVersion) {
        self.version = version
    }

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
                    try await Self.makePrewarmedManager(version: version)
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

    private static func makePrewarmedManager(
        version: EngineVersion
    ) async throws -> AsrManager {
        let asrVersion = version.asrModelVersion
        print("prewarming transcription engine")
        print("downloading \(version.displayName) models if needed")
        let modelDirectory = try await AsrModels.download(
            version: asrVersion
        )

        print("loading \(version.displayName) models")
        let models = try await AsrModels.load(
            from: modelDirectory,
            version: asrVersion
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

private extension EngineVersion {
    var asrModelVersion: AsrModelVersion {
        switch self {
        case .v2:
            .v2
        case .v3:
            .v3
        }
    }
}
