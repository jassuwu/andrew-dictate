import FluidAudio
import OSLog

/// file scope, and named for the file: the engine is an actor with static
/// members, so there is no single `self` every log site can reach.
private let transcriptionLogger = Logger(
    subsystem: AppIdentity.loggingSubsystem,
    category: "engine"
)

actor ParakeetEngine: TranscriptionEngine {
    /// a manager and the gate every call into it goes through. made
    /// together and dropped together: a restart's fresh manager comes with
    /// a fresh gate, so a call wedged in the old one holds up nothing on
    /// the new one.
    private struct ActiveManager {
        let version: EngineVersion
        let manager: AsrManager
        let gate: SerialGate
    }

    private struct Preparation {
        let identifier: Int
        let version: EngineVersion
        let task: Task<AsrManager, Error>
    }

    private var activeManager: ActiveManager?
    private var preparation: Preparation?
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
        activate(manager, version: version)
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
        activate(manager, version: version)
        fallbackVersion = version
    }

    /// not loaded yet means nothing to wake: the load runs its own
    /// warm-up. anything already in the gate — a wake, a take still
    /// finishing, a probe — means the engine is awake, and a wake queued
    /// behind it would stand between the take asked next and the engine.
    func wake() async {
        guard let manager = activeManager?.manager,
              let gate = activeManager?.gate else {
            return
        }
        _ = try? await gate.runIfIdle {
            _ = try await Self.transcribe(Self.wakeSilence, with: manager)
        }
    }

    /// one at a time per manager, in the order asked (`SerialGate`): a
    /// take asked while the wake runs waits for it, and a probe or a retry
    /// asked while a hung take is still inside waits behind it rather than
    /// run beside it.
    func transcribe(_ samples: [Float]) async throws -> String {
        let active: ActiveManager
        if let activeManager {
            active = activeManager
        } else {
            let version = fallbackVersion
            let manager = try await preparedManager(
                for: version,
                progressHandler: nil
            )
            try Task.checkCancellation()
            active = activate(manager, version: version)
        }
        let manager = active.manager
        return try await active.gate.run {
            transcriptionLogger.debug("transcribing audio")
            let text = try await Self.transcribe(samples, with: manager)
            transcriptionLogger.debug("transcription complete")
            return text
        }
    }

    /// the only call into a published manager, and only ever from inside
    /// its gate.
    private static func transcribe(
        _ samples: [Float],
        with manager: AsrManager
    ) async throws -> String {
        let decoderLayerCount = await manager.decoderLayerCount
        var decoderState = TdtDecoderState.make(decoderLayers: decoderLayerCount)
        return try await manager.transcribe(
            samples,
            decoderState: &decoderState
        ).text
    }

    /// the manager on record, with its gate. a manager already on record
    /// keeps the gate it has: two takes that both found nothing loaded
    /// await the same preparation, and two gates on one manager would let
    /// them run side by side.
    @discardableResult
    private func activate(
        _ manager: AsrManager,
        version: EngineVersion
    ) -> ActiveManager {
        if let activeManager, activeManager.manager === manager {
            return activeManager
        }
        let active = ActiveManager(
            version: version,
            manager: manager,
            gate: SerialGate()
        )
        activeManager = active
        return active
    }

    func cancelPreparation() {
        preparation?.task.cancel()
        preparation = nil
    }

    /// the manager goes, and its gate with it: a call stuck in the engine
    /// being restarted holds up nothing on the one replacing it.
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
