import FluidAudio
import Foundation
import WhisperKit
import os

/// Where the meeting models come from and go. Whisper lives beside parakeet
/// under FluidAudio's shared folder, so removal (ADR 0035) has one place to
/// look, and `installed()` is a question for the disk, never a memory.
/// Parakeet *is* dictation's v2 and v3, in dictation's folder: on disk for
/// one job is on disk for both.
enum MeetingEngines {
    private static let logger = Logger(subsystem: AppIdentity.loggingSubsystem, category: "meeting-models")

    static var modelDirectory: URL {
        AppIdentity.sharedModelDirectory.appendingPathComponent("whisperkit", isDirectory: true)
    }

    /// WhisperKit lays models out as `models/<repo>/<variant>` under its base.
    /// Nil for parakeet, which is not whisper's to lay out.
    static func folder(for model: SpeechModel) -> URL? {
        guard let variant = model.whisperVariant else { return nil }
        return modelDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(variant, isDirectory: true)
    }

    static func isInstalled(_ model: SpeechModel) -> Bool {
        if model.asrModelVersion != nil {
            // the one answer dictation's settings and setup use.
            return ModelStore.isOnDisk(model)
        }
        guard let folder = folder(for: model) else { return false }
        let decoder = folder.appendingPathComponent("TextDecoder.mlmodelc")
        return FileManager.default.fileExists(atPath: decoder.path)
    }

    static func installed() -> Set<SpeechModel> {
        Set(SpeechModel.allCases.filter(isInstalled))
    }

    /// What listens to a meeting, for the model it was started with.
    ///
    /// Every model reads the meeting a stretch at a time: each side cut where
    /// Silero hears speech begin and end, and each stretch decoded once.
    static func makeTranscriber(for model: SpeechModel) async throws -> any MeetingTranscriber {
        guard isInstalled(model) else {
            throw SpeechModel.NotInstalled(model: model)
        }
        // the speaker split is read at the end of the meeting; a mac that
        // was set up before its models came down with the meeting model
        // gets them now, in the background, so they are there by then.
        // whisper's tokenizer is not fetched here: the load needs it before
        // anything else, and fetches it itself.
        if !FluidDiarizer.isOnDisk {
            Task.detached(priority: .utility) { await fetchSpeakerSplit() }
        }
        if model.asrModelVersion != nil {
            return stretches(ParakeetStretchEngine(model: model), ceiling: ParakeetStretchEngine.ceiling)
        }
        return stretches(WhisperStretchEngine(model: model), ceiling: WhisperStretchEngine.ceiling)
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
    static func tokenizerFolder(for model: SpeechModel) -> URL? {
        guard model.whisperVariant != nil else { return nil }
        return HubApiWrapper(downloadBase: modelDirectory)
            .localRepoLocation(HubApiWrapper.Repo(id: tokenizerRepo))
    }

    /// WhisperKit fetches the tokenizer from the Hugging Face Hub the first
    /// time it loads a model, which is a meeting waiting on the network at
    /// its start. Setup fetches it instead, to the folder it looks in. One
    /// download at a time, whoever asks — setup, and the load of a mac set
    /// up before it came with the model — so two never write the folder at
    /// once; both whisper models read the same one.
    private static let tokenizer = OneDownload {
        _ = try await AutoTokenizerWrapper.from(
            pretrained: tokenizerRepo,
            hubApi: HubApiWrapper(downloadBase: modelDirectory))
    }

    /// The speaker-split models, one download at a time in the same way:
    /// setup, and a meeting started on a mac that does not have them yet.
    private static let speakerSplit = OneDownload { try await FluidDiarizer.fetch() }

    /// Whisper's tokenizer, for a load that found it missing: waited on for
    /// `limit` at most, so a meeting is not held at its start by a network
    /// that does not answer. Past that, the download goes on in the
    /// background for the next to find. Failing is logged and nothing more:
    /// the load says whether the tokenizer can be read.
    static func fetchTokenizer(within limit: Duration) async {
        do {
            try await tokenizer.run(within: limit)
        } catch {
            logger.error("whisper's tokenizer did not download: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The speaker-split models, for a mac that does not have them yet.
    /// Failing is logged and nothing more: a meeting without them has
    /// plain `them`.
    static func fetchSpeakerSplit() async {
        do {
            try await speakerSplit.run()
        } catch {
            logger.error("the speaker-split models did not download: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// What `prepare` fetches after the model: the tokenizer for a whisper
    /// model, and the speaker-split models for every model. Failing is
    /// logged and nothing more.
    static func fetchWhatSetupOwes(_ model: SpeechModel) async {
        if model.whisperVariant != nil {
            do {
                try await tokenizer.run()
            } catch {
                logger.error("whisper's tokenizer did not download: \(error.localizedDescription, privacy: .public)")
            }
        }
        await fetchSpeakerSplit()
    }

    /// Downloads (or verifies) the model, reporting 0…1. False means it did
    /// not finish; the caller shows "try again".
    ///
    /// What a meeting reads besides the model comes down after it, so that
    /// no meeting waits on the network at its start or its end: whisper's
    /// tokenizer for a whisper model, and the speaker-split models for every
    /// model. Either failing is logged and is not the model failing: a
    /// meeting without the split has plain `them`, and one without a
    /// tokenizer says so rather than fetching it.
    static func prepare(
        _ model: SpeechModel,
        progress: @escaping @Sendable (Double) -> Void
    ) async -> Bool {
        do {
            if let variant = model.whisperVariant {
                _ = try await WhisperKit.download(
                    variant: variant,
                    downloadBase: modelDirectory,
                    progressCallback: { progress($0.fractionCompleted) }
                )
            } else if let version = model.asrModelVersion {
                // the call dictation's engine makes, to the folder it reads.
                _ = try await AsrModels.download(
                    version: version,
                    progressHandler: { progress($0.fractionCompleted) }
                )
            }
        } catch {
            return false
        }
        await fetchWhatSetupOwes(model)
        progress(1)
        return isInstalled(model)
    }
}
