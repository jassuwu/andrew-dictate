import CryptoKit
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
    /// variant's folder for whisper, whistle's own for whistle.
    static func folder(for model: SpeechModel) -> URL? {
        switch model.family {
        case .parakeet: model.asrModelVersion.map(AsrModels.defaultCacheDirectory(for:))
        case .whisper: whisperFolder(for: model)
        case .whistle: whistleDirectory
        }
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
        switch model.family {
        case .parakeet:
            return isNonemptyDirectory(folder, fileManager: fileManager)
        case .whisper:
            let decoder = folder.appendingPathComponent("TextDecoder.mlmodelc")
            return fileManager.fileExists(atPath: decoder.path)
        case .whistle:
            // only a file that was checked whole is ever moved here.
            return fileManager.fileExists(atPath: whistleFile.path)
        }
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
        } else if model.family == .whistle, !isInstalled(model) {
            try await downloadWhistle(progress: progress)
        }
    }

    // MARK: - whistle

    static var whistleDirectory: URL {
        AppIdentity.sharedModelDirectory.appendingPathComponent("whistle", isDirectory: true)
    }

    static var whistleFile: URL {
        whistleDirectory.appendingPathComponent("whistle.cact")
    }

    /// The one file, pinned to a commit so it is the file the engine in
    /// Vendor/Needle was built for, and checked against its sha-256 before
    /// it is moved into place.
    private static let whistleSource = URL(string:
        "https://huggingface.co/Cactus-Compute/whistle/resolve/"
        + "b358ddadd89b7a713b5aa131f23032d3cca1b251/whistle.cact")!
    private static let whistleDigest =
        "b6e02f048568ac5d01a2042556c658061e699acbc0aa2a1439f52f3d461dffeb"

    enum WhistleDownloadFailure: Error, LocalizedError {
        case status(Int)
        case notTheFile

        var errorDescription: String? {
            switch self {
            case .status(let code): "whistle's download answered \(code)"
            case .notTheFile: "the whistle download wasn't the file it should be"
            }
        }
    }

    private static func downloadWhistle(progress: @escaping @Sendable (Double) -> Void) async throws {
        let (downloaded, response) = try await FileDownload.run(whistleSource, progress: progress)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw WhistleDownloadFailure.status(http.statusCode)
        }
        let bytes = try Data(contentsOf: downloaded, options: .mappedIfSafe)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard digest == whistleDigest else { throw WhistleDownloadFailure.notTheFile }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: whistleDirectory, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: whistleFile.path) {
            _ = try fileManager.replaceItemAt(whistleFile, withItemAt: downloaded)
        } else {
            try fileManager.moveItem(at: downloaded, to: whistleFile)
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
