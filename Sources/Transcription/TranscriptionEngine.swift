import FluidAudio

enum TranscriptionPreparationUpdate: Sendable {
    case downloading(progress: Double)
    case warmingUp
}

protocol TranscriptionEngine {
    func prewarm(
        progressHandler: (@Sendable (TranscriptionPreparationUpdate) -> Void)?
    ) async throws
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

    func prewarm(
        progressHandler: (@Sendable (TranscriptionPreparationUpdate) -> Void)?
    ) async throws {
        _ = try await preparedManager(progressHandler: progressHandler)
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        let manager = try await preparedManager(progressHandler: nil)
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

    private func preparedManager(
        progressHandler: (
            @Sendable (TranscriptionPreparationUpdate) -> Void
        )?
    ) async throws -> AsrManager {
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
                    try await Self.makePrewarmedManager(
                        version: version,
                        progressHandler: progressHandler
                    )
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
        version: EngineVersion,
        progressHandler: (
            @Sendable (TranscriptionPreparationUpdate) -> Void
        )?
    ) async throws -> AsrManager {
        let asrVersion = version.asrModelVersion
        print("prewarming transcription engine")
        print("downloading \(version.displayName) models if needed")
        let modelDirectory = try await AsrModels.download(
            version: asrVersion,
            progressHandler: { progress in
                progressHandler?(
                    .downloading(
                        progress: progress.fractionCompleted
                    )
                )
            }
        )

        progressHandler?(.warmingUp)
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
