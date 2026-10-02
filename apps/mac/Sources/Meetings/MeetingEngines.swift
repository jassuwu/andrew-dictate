import FluidAudio
import Foundation
import WhisperKit
import os

/// Where the meeting models come from and go. Whisper lives beside parakeet
/// under FluidAudio's shared folder, so removal (ADR 0035) has one place to
/// look, and `installed()` is a question for the disk, never a memory.
/// Parakeet *is* dictation's v3, in dictation's folder: on disk for one is
/// on disk for both.
enum MeetingEngines {
    enum Failure: Error, LocalizedError {
        case notInstalled(MeetingModel)

        var errorDescription: String? {
            switch self {
            case .notInstalled(let model): "\(model.shortName) is not on this mac"
            }
        }
    }

    private static let logger = Logger(subsystem: AppIdentity.loggingSubsystem, category: "meeting-models")

    static var modelDirectory: URL {
        AppIdentity.sharedModelDirectory.appendingPathComponent("whisperkit", isDirectory: true)
    }

    /// WhisperKit lays models out as `models/<repo>/<variant>` under its base.
    /// Nil for parakeet, which is not whisper's to lay out.
    static func folder(for model: MeetingModel) -> URL? {
        guard let variant = model.whisperVariant else { return nil }
        return modelDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(variant, isDirectory: true)
    }

    static func isInstalled(_ model: MeetingModel) -> Bool {
        guard let folder = folder(for: model) else {
            // parakeet: the one answer dictation's settings and setup use.
            return ModelStore.isOnDisk(.v3)
        }
        let decoder = folder.appendingPathComponent("TextDecoder.mlmodelc")
        return FileManager.default.fileExists(atPath: decoder.path)
    }

    static func installed() -> Set<MeetingModel> {
        Set(MeetingModel.allCases.filter(isInstalled))
    }

    /// What listens to a meeting, for the model it was started with.
    ///
    /// Every model reads the meeting a stretch at a time: each side cut where
    /// Silero hears speech begin and end, and each stretch decoded once.
    static func makeTranscriber(for model: MeetingModel) async throws -> any MeetingTranscriber {
        guard isInstalled(model) else {
            throw Failure.notInstalled(model)
        }
        switch model {
        case .parakeetV3:
            return stretches(ParakeetStretchEngine(), ceiling: ParakeetStretchEngine.ceiling)
        case .whisperLargeV3, .whisperLargeV3Turbo:
            return stretches(WhisperStretchEngine(model: model), ceiling: WhisperStretchEngine.ceiling)
        }
    }

    /// A meeting heard a stretch at a time, both sides by one voice model
    /// loaded for this meeting and let go with it.
    private static func stretches(_ engine: any StretchEngine, ceiling: Duration) -> StretchTranscriber {
        let voice = SileroVoice()
        return StretchTranscriber(engine: engine, ceiling: ceiling, detector: { voice.detector() })
    }

    static func makeDiarizer() -> any MeetingDiarizer {
        FluidDiarizer()
    }

    // MARK: - what a whisper meeting reads besides the model

    /// Both whisper models have large-v3's vocabulary, 51,866 tokens, which
    /// is how WhisperKit tells it, so both read large-v3's tokenizer.
    private static let tokenizerRepo = "openai/whisper-large-v3"

    /// Where WhisperKit looks for a whisper model's tokenizer first: the
    /// repo's own folder under the base it is given. Nil for parakeet,
    /// which has no use for one. Moving WhisperKit's pin in `project.yml`
    /// means checking that this is still the repo it asks for.
    static func tokenizerFolder(for model: MeetingModel) -> URL? {
        guard model.whisperVariant != nil else { return nil }
        return HubApiWrapper(downloadBase: modelDirectory)
            .localRepoLocation(HubApiWrapper.Repo(id: tokenizerRepo))
    }

    /// WhisperKit fetches the tokenizer from the Hugging Face Hub the first
    /// time it loads a model, which is a meeting waiting on the network at
    /// its start. Setup fetches it instead, to the folder it looks in.
    private static func fetchTokenizer(for model: MeetingModel) async throws {
        guard model.whisperVariant != nil else { return }
        _ = try await AutoTokenizerWrapper.from(
            pretrained: tokenizerRepo,
            hubApi: HubApiWrapper(downloadBase: modelDirectory))
    }

    /// Downloads (or verifies) the model, reporting 0…1. False means it did
    /// not finish; the caller shows "try again".
    ///
    /// What a whisper meeting reads besides the model comes down after it,
    /// so that no meeting waits on the network at its start: the tokenizer.
    /// It failing is logged and is not the model failing: a meeting without
    /// it says so rather than fetching it.
    static func prepare(
        _ model: MeetingModel,
        progress: @escaping @Sendable (Double) -> Void
    ) async -> Bool {
        do {
            if let variant = model.whisperVariant {
                _ = try await WhisperKit.download(
                    variant: variant,
                    downloadBase: modelDirectory,
                    progressCallback: { progress($0.fractionCompleted) }
                )
            } else {
                // the call dictation's engine makes, to the folder it reads.
                _ = try await AsrModels.download(
                    version: EngineVersion.v3.asrModelVersion,
                    progressHandler: { progress($0.fractionCompleted) }
                )
            }
        } catch {
            return false
        }
        do {
            try await fetchTokenizer(for: model)
        } catch {
            logger.error("whisper's tokenizer did not download: \(error.localizedDescription, privacy: .public)")
        }
        progress(1)
        return isInstalled(model)
    }
}
