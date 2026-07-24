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
    private struct ActiveManager {
        let version: EngineVersion
        let manager: AsrManager
    }

    private struct Preparation {
        let identifier: Int
        let version: EngineVersion
        let task: Task<AsrManager, Error>
    }

    private var activeManager: ActiveManager?
    private var preparation: Preparation?
    private var nextPreparationIdentifier = 0
    private var fallbackVersion: EngineVersion

    init(version: EngineVersion) {
        fallbackVersion = version
    }

    func selectVersionForBlockingPreparation(
        _ version: EngineVersion
    ) {
        fallbackVersion = version
    }

    func prewarm(
        progressHandler: (@Sendable (TranscriptionPreparationUpdate) -> Void)?
    ) async throws {
        let version = fallbackVersion
        guard activeManager?.version != version else {
            return
        }

        let manager = try await preparedManager(
            for: version,
            progressHandler: progressHandler
        )
        try Task.checkCancellation()
        activeManager = ActiveManager(
            version: version,
            manager: manager
        )
    }

    func prepareAndSwap(
        to version: EngineVersion,
        progressHandler: (
            @Sendable (TranscriptionPreparationUpdate) -> Void
        )?
    ) async throws {
        guard activeManager?.version != version else {
            return
        }

        let manager = try await preparedManager(
            for: version,
            progressHandler: progressHandler
        )
        try Task.checkCancellation()

        // The current manager remains readable across every suspension above.
        // Replacing this actor-isolated value is the atomic commit point.
        activeManager = ActiveManager(
            version: version,
            manager: manager
        )
        fallbackVersion = version
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        let manager: AsrManager
        if let activeManager {
            manager = activeManager.manager
        } else {
            let version = fallbackVersion
            manager = try await preparedManager(
                for: version,
                progressHandler: nil
            )
            try Task.checkCancellation()
            activeManager = ActiveManager(
                version: version,
                manager: manager
            )
        }
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

    func cancelPreparation() {
        preparation?.task.cancel()
        preparation = nil
    }

    func unloadModels() {
        cancelPreparation()
        activeManager = nil
    }

    private func preparedManager(
        for version: EngineVersion,
        progressHandler: (
            @Sendable (TranscriptionPreparationUpdate) -> Void
        )?
    ) async throws -> AsrManager {
        if let activeManager,
           activeManager.version == version {
            return activeManager.manager
        }

        let pendingPreparation: Preparation
        if let preparation,
           preparation.version == version {
            pendingPreparation = preparation
        } else {
            preparation?.task.cancel()
            nextPreparationIdentifier += 1
            let newPreparation = Preparation(
                identifier: nextPreparationIdentifier,
                version: version,
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
        try Task.checkCancellation()

        progressHandler?(.warmingUp)
        print("loading \(version.displayName) models")
        let models = try await AsrModels.load(
            from: modelDirectory,
            version: asrVersion
        )
        try Task.checkCancellation()
        let manager = AsrManager(config: .default, models: models)

        print("running transcription warmup")
        let decoderLayerCount = await manager.decoderLayerCount
        var decoderState = TdtDecoderState.make(decoderLayers: decoderLayerCount)
        let silence = [Float](repeating: 0, count: 16_000)
        _ = try await manager.transcribe(
            silence,
            decoderState: &decoderState
        )
        try Task.checkCancellation()
        print("transcription engine ready")

        return manager
    }
}

extension EngineVersion {
    var asrModelVersion: AsrModelVersion {
        switch self {
        case .v2:
            .v2
        case .v3:
            .v3
        }
    }
}
