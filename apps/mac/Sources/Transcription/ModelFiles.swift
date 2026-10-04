import FluidAudio
import Foundation
import WhisperKit
import os

/// Where every speech model comes from and lives, for either job. One
/// download serves both: a model on disk for dictation is on disk for
/// meetings. Whisper lives beside parakeet under FluidAudio's shared
/// folder, so removal (ADR 0035) has one place to look, and `installed()`
/// is a question for the disk, never a memory.
enum ModelFiles {
    private static let logger = Logger(subsystem: AppIdentity.loggingSubsystem, category: "model-files")

    static var whisperDirectory: URL {
        AppIdentity.sharedModelDirectory.appendingPathComponent("whisperkit", isDirectory: true)
    }

    /// Where a model's files are: FluidAudio's folder for parakeet, the
    /// variant's folder for whisper.
    static func folder(for model: SpeechModel) -> URL? {
        if let version = model.asrModelVersion {
            return AsrModels.defaultCacheDirectory(for: version)
        }
        return whisperFolder(for: model)
    }

    /// WhisperKit lays models out as `models/<repo>/<variant>` under its base.
    /// Nil for parakeet, which is not whisper's to lay out.
    static func whisperFolder(for model: SpeechModel) -> URL? {
        guard let variant = model.whisperVariant else { return nil }
        return whisperDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(variant, isDirectory: true)
    }

    static func isInstalled(_ model: SpeechModel, fileManager: FileManager = .default) -> Bool {
        guard let folder = folder(for: model) else { return false }
        if model.whisperVariant != nil {
            let decoder = folder.appendingPathComponent("TextDecoder.mlmodelc")
            return fileManager.fileExists(atPath: decoder.path)
        }
        return isNonemptyDirectory(folder, fileManager: fileManager)
    }

    static func installed() -> Set<SpeechModel> {
        Set(SpeechModel.allCases.filter { isInstalled($0) })
    }

    /// Downloads (or verifies) the model, reporting 0…1. Whisper's
    /// tokenizer comes down after it, so that nothing waits on the network
    /// when the model loads; the tokenizer failing is logged and is not the
    /// model failing: the load fetches it again, or says it cannot.
    static func download(
        _ model: SpeechModel,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        if let variant = model.whisperVariant {
            _ = try await WhisperKit.download(
                variant: variant,
                downloadBase: whisperDirectory,
                progressCallback: { progress($0.fractionCompleted) }
            )
            do {
                try await tokenizer.run()
            } catch {
                logger.error("whisper's tokenizer did not download: \(error.localizedDescription, privacy: .public)")
            }
        } else if let version = model.asrModelVersion {
            _ = try await AsrModels.download(
                version: version,
                progressHandler: { progress($0.fractionCompleted) }
            )
        }
    }

    // MARK: - what a whisper model reads besides the model

    /// Both whisper models have large-v3's vocabulary, 51,866 tokens, which
    /// is how WhisperKit tells it, so both read large-v3's tokenizer.
    private static let tokenizerRepo = "openai/whisper-large-v3"

    /// Where WhisperKit looks for a whisper model's tokenizer first: the
    /// repo's own folder under the base it is given. Nil for parakeet,
    /// which has no use for one. Moving WhisperKit's pin in `project.yml`
    /// means checking that this is still the repo it asks for.
    static func tokenizerFolder(for model: SpeechModel) -> URL? {
        guard model.whisperVariant != nil else { return nil }
        return HubApiWrapper(downloadBase: whisperDirectory)
            .localRepoLocation(HubApiWrapper.Repo(id: tokenizerRepo))
    }

    /// WhisperKit fetches the tokenizer from the Hugging Face Hub the first
    /// time it loads a model, which is a job waiting on the network at its
    /// start. The download fetches it instead, to the folder it looks in.
    /// One download at a time, whoever asks — a download, and the load of a
    /// mac set up before it came with the model — so two never write the
    /// folder at once; both whisper models read the same one.
    private static let tokenizer = OneDownload {
        _ = try await AutoTokenizerWrapper.from(
            pretrained: tokenizerRepo,
            hubApi: HubApiWrapper(downloadBase: whisperDirectory))
    }

    /// Whisper's tokenizer, for a load that found it missing: waited on for
    /// `limit` at most, so a job is not held at its start by a network that
    /// does not answer. Past that, the download goes on in the background
    /// for the next to find. Failing is logged and nothing more: the load
    /// says whether the tokenizer can be read.
    static func fetchTokenizer(within limit: Duration) async {
        do {
            try await tokenizer.run(within: limit)
        } catch {
            logger.error("whisper's tokenizer did not download: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func isNonemptyDirectory(_ directory: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }
        return (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).isEmpty) == false
    }
}
