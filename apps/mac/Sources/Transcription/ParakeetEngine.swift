import FluidAudio
import OSLog

/// file scope, and named for the file: the engine is an actor with static
/// members, so there is no single `self` every log site can reach.
private let transcriptionLogger = Logger(
    subsystem: AppIdentity.loggingSubsystem,
    category: "engine"
)

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
    /// the key-down wake still running. a take waits for it rather than
    /// run beside it: the two would share the manager's buffers mid-call,
    /// and what is pasted has to be what the take alone gives. it is short
    /// (~60 ms warm) and started the length of a held key earlier.
    private var waking: Task<Void, Never>?
    /// half a second of silence: past the model's 0.3 s floor, and padded
    /// to the same 15 s window a short take is, so it wakes everything the
    /// take will use.
    private static let wakeSilence = [Float](repeating: 0, count: 8_000)
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
        // a wake on the old manager has nothing to say about the new one.
        waking = nil
    }

    /// not loaded yet means nothing to wake: the load runs its own
    /// warm-up. a wake already running is the same question.
    func wake() async {
        guard waking == nil, let manager = activeManager?.manager else {
            return
        }
        let wake = Task {
            let decoderLayerCount = await manager.decoderLayerCount
            var decoderState = TdtDecoderState.make(
                decoderLayers: decoderLayerCount
            )
            _ = try? await manager.transcribe(
                Self.wakeSilence,
                decoderState: &decoderState
            )
        }
        waking = wake
        await wake.value
        if waking == wake {
            waking = nil
        }
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        await waking?.value
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

        transcriptionLogger.debug("transcribing audio")
        let result = try await manager.transcribe(
            samples,
            decoderState: &decoderState
        )
        transcriptionLogger.debug("transcription complete")

        return result.text
    }

    func cancelPreparation() {
        preparation?.task.cancel()
        preparation = nil
    }

    func unloadModels() {
        cancelPreparation()
        activeManager = nil
        // a wake stuck in the engine being restarted must not hold up the
        // first take of the one replacing it.
        waking = nil
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
            transcriptionLogger.error(
                """
                transcription engine prewarm failed: \
                \(error.localizedDescription, privacy: .public)
                """
            )
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
        transcriptionLogger.notice("prewarming transcription engine")
        transcriptionLogger.notice(
            "downloading \(version.displayName) models if needed"
        )
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
        transcriptionLogger.notice(
            "loading \(version.displayName) models"
        )
        let models = try await AsrModels.load(
            from: modelDirectory,
            version: asrVersion
        )
        try Task.checkCancellation()
        let manager = AsrManager(config: .default, models: models)

        transcriptionLogger.notice("running transcription warmup")
        let decoderLayerCount = await manager.decoderLayerCount
        var decoderState = TdtDecoderState.make(decoderLayers: decoderLayerCount)
        let silence = [Float](repeating: 0, count: 16_000)
        _ = try await manager.transcribe(
            silence,
            decoderState: &decoderState
        )
        try Task.checkCancellation()
        transcriptionLogger.notice("transcription engine ready")

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
