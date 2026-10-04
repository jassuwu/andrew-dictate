import FluidAudio
import OSLog

/// file scope, and named for the file: the engine is an actor with static
/// members, so there is no single `self` every log site can reach.
private let transcriptionLogger = Logger(
    subsystem: AppIdentity.loggingSubsystem,
    category: "engine"
)

/// one model, loaded, as the engine drives it. every call comes through
/// the engine's gate, one at a time.
protocol LoadedSpeechModel: AnyObject, Sendable {
    /// a take of 16 kHz mono, any length, as text.
    func transcribe(_ samples: [Float]) async throws -> String
    /// a short pass over nothing, so the next take finds it awake.
    func wake() async throws
}

extension LoadedSpeechModel {
    /// a model with nothing to wake.
    func wake() async throws {}
}

/// whichever model dictation picked, loaded, swapped and woken the same
/// way: parakeet, whisper or whistle. a meeting that reads with parakeet has one of
/// its own.
actor SpeechEngine: TranscriptionEngine {
    /// a model and the gate every call into it goes through. made together
    /// and dropped together: a restart's fresh model comes with a fresh
    /// gate, so a call wedged in the old one holds up nothing on the new
    /// one.
    private struct ActiveModel {
        let version: SpeechModel
        let loaded: any LoadedSpeechModel
        let gate: SerialGate
    }

    private struct Preparation {
        let identifier: Int
        let version: SpeechModel
        let task: Task<any LoadedSpeechModel, Error>
    }

    private var activeModel: ActiveModel?
    private var preparation: Preparation?
    private var nextPreparationIdentifier = 0
    private var fallbackVersion: SpeechModel

    init(version: SpeechModel) {
        fallbackVersion = version
    }

    func selectVersionForBlockingPreparation(
        _ version: SpeechModel
    ) {
        fallbackVersion = version
    }

    func prewarm(
        progressHandler: (@Sendable (TranscriptionPreparationUpdate) -> Void)?
    ) async throws {
        let version = fallbackVersion
        guard activeModel?.version != version else {
            return
        }

        let loaded = try await preparedModel(
            for: version,
            progressHandler: progressHandler
        )
        try Task.checkCancellation()
        activate(loaded, version: version)
    }

    func prepareAndSwap(
        to version: SpeechModel,
        progressHandler: (
            @Sendable (TranscriptionPreparationUpdate) -> Void
        )?
    ) async throws {
        guard activeModel?.version != version else {
            return
        }

        let loaded = try await preparedModel(
            for: version,
            progressHandler: progressHandler
        )
        try Task.checkCancellation()

        // The current model remains readable across every suspension above.
        // Replacing this actor-isolated value is the atomic commit point.
        activate(loaded, version: version)
        fallbackVersion = version
    }

    /// not loaded yet means nothing to wake: the load runs its own
    /// warm-up. anything already in the gate — a wake, a take still
    /// finishing, a probe — means the engine is awake, and a wake queued
    /// behind it would stand between the take asked next and the engine.
    func wake() async {
        guard let active = activeModel else {
            return
        }
        let loaded = active.loaded
        _ = try? await active.gate.runIfIdle {
            try await loaded.wake()
        }
    }

    /// one at a time per model, in the order asked (`SerialGate`): a take
    /// asked while the wake runs waits for it, and a probe or a retry
    /// asked while a hung take is still inside waits behind it rather than
    /// run beside it.
    func transcribe(_ samples: [Float]) async throws -> String {
        let active: ActiveModel
        if let activeModel {
            active = activeModel
        } else {
            let version = fallbackVersion
            let loaded = try await preparedModel(
                for: version,
                progressHandler: nil
            )
            try Task.checkCancellation()
            active = activate(loaded, version: version)
        }
        let loaded = active.loaded
        return try await active.gate.run {
            transcriptionLogger.debug("transcribing audio")
            let text = try await loaded.transcribe(samples)
            transcriptionLogger.debug("transcription complete")
            return text
        }
    }

    /// the model on record, with its gate. a model already on record keeps
    /// the gate it has: two takes that both found nothing loaded await the
    /// same preparation, and two gates on one model would let them run
    /// side by side.
    @discardableResult
    private func activate(
        _ loaded: any LoadedSpeechModel,
        version: SpeechModel
    ) -> ActiveModel {
        if let activeModel, activeModel.loaded === loaded {
            return activeModel
        }
        let active = ActiveModel(
            version: version,
            loaded: loaded,
            gate: SerialGate()
        )
        activeModel = active
        return active
    }

    func cancelPreparation() {
        preparation?.task.cancel()
        preparation = nil
    }

    /// the model goes, and its gate with it: a call stuck in the engine
    /// being restarted holds up nothing on the one replacing it.
    func unloadModels() {
        cancelPreparation()
        activeModel = nil
    }

    private func preparedModel(
        for version: SpeechModel,
        progressHandler: (
            @Sendable (TranscriptionPreparationUpdate) -> Void
        )?
    ) async throws -> any LoadedSpeechModel {
        if let activeModel,
           activeModel.version == version {
            return activeModel.loaded
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
                    try await Self.makePrewarmedModel(
                        version: version,
                        progressHandler: progressHandler
                    )
                }
            )
            preparation = newPreparation
            pendingPreparation = newPreparation
        }

        do {
            let prepared = try await pendingPreparation.task.value

            if preparation?.identifier == pendingPreparation.identifier {
                preparation = nil
            }

            return prepared
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

    /// the download if the model is missing, the load, and a warm-up, so
    /// the first take finds it ready.
    private static func makePrewarmedModel(
        version: SpeechModel,
        progressHandler: (
            @Sendable (TranscriptionPreparationUpdate) -> Void
        )?
    ) async throws -> any LoadedSpeechModel {
        transcriptionLogger.notice("prewarming transcription engine")
        transcriptionLogger.notice(
            "downloading \(version.displayName) models if needed"
        )
        try await ModelFiles.download(version) { progress in
            progressHandler?(.downloading(progress: progress))
        }
        try Task.checkCancellation()

        progressHandler?(.warmingUp)
        transcriptionLogger.notice(
            "loading \(version.displayName) models"
        )
        let loaded: any LoadedSpeechModel
        switch version.family {
        case .parakeet:
            loaded = try await ParakeetModel.load(version)
        case .whisper:
            let whisper = WhisperModel(version, translates: false)
            try await whisper.load()
            loaded = whisper
        case .whistle:
            let whistle = WhistleModel()
            try await whistle.load()
            loaded = whistle
        }
        try Task.checkCancellation()
        transcriptionLogger.notice("transcription engine ready")

        return loaded
    }
}

/// parakeet, loaded: FluidAudio's manager.
private final class ParakeetModel: LoadedSpeechModel {
    /// half a second of silence: past the model's 0.3 s floor, and padded
    /// to the same 15 s window a short take is, so it wakes everything the
    /// take will use.
    private static let wakeSilence = [Float](repeating: 0, count: 8_000)

    private let manager: AsrManager

    private init(manager: AsrManager) {
        self.manager = manager
    }

    static func load(_ version: SpeechModel) async throws -> ParakeetModel {
        guard let asrVersion = version.asrModelVersion else {
            throw SpeechModel.NotParakeet(model: version)
        }
        let models = try await AsrModels.load(
            from: AsrModels.defaultCacheDirectory(for: asrVersion),
            version: asrVersion
        )
        try Task.checkCancellation()
        let loaded = ParakeetModel(
            manager: AsrManager(config: .default, models: models)
        )

        transcriptionLogger.notice("running transcription warmup")
        _ = try await loaded.transcribe(
            [Float](repeating: 0, count: 16_000)
        )
        return loaded
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        let decoderLayerCount = await manager.decoderLayerCount
        var decoderState = TdtDecoderState.make(decoderLayers: decoderLayerCount)
        return try await manager.transcribe(
            samples,
            decoderState: &decoderState
        ).text
    }

    func wake() async throws {
        _ = try await transcribe(Self.wakeSilence)
    }
}

/// whisper, for a take: cut at quiet into pieces it reads in one window,
/// each decoded in turn and joined.
extension WhisperModel: LoadedSpeechModel {
    func transcribe(_ samples: [Float]) async throws -> String {
        var words: [String] = []
        for piece in QuietSplit.pieces(of: samples, longest: Self.ceiling) {
            let text = try await text(of: piece)
            if !text.isEmpty {
                words.append(text)
            }
        }
        return words.joined(separator: " ")
    }
}

extension SpeechModel {
    /// FluidAudio's name for a parakeet model; nil for every other.
    var asrModelVersion: AsrModelVersion? {
        switch self {
        case .parakeetV2: .v2
        case .parakeetV3: .v3
        case .whisperLargeV3, .whisperLargeV3Turbo, .whistle: nil
        }
    }

    struct NotParakeet: Error, LocalizedError {
        let model: SpeechModel

        var errorDescription: String? {
            "\(model.shortName) is not a parakeet model"
        }
    }
}
