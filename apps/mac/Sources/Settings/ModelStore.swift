import FluidAudio
import Foundation

struct InstalledModel: Identifiable, Equatable {
    let version: SpeechModel
    let isDownloaded: Bool
    let onDiskSize: String

    var id: SpeechModel {
        version
    }
}

enum ModelStoreError: LocalizedError {
    case unsafeModelDirectory
    case removalFailed(SpeechModel, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .unsafeModelDirectory:
            "the model download location is invalid"
        case let .removalFailed(version, underlying):
            "couldn’t remove \(version.shortName) — "
                + Self.reason(underlying)
        }
    }

    /// macOS error strings are sentence-cased and often quote a file
    /// name, so only the first character is lowered — a blanket
    /// .lowercased() would rewrite the path it is telling you about.
    private static func reason(_ error: Error) -> String {
        let text = error.localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = text.first else {
            return "the file system refused"
        }
        return first.lowercased() + text.dropFirst()
    }
}

@MainActor
final class ModelStore {
    private let fileManager: FileManager
    private let activeVersion: @MainActor () -> SpeechModel

    init(
        fileManager: FileManager = .default,
        activeVersion: @escaping @MainActor () -> SpeechModel
    ) {
        self.fileManager = fileManager
        self.activeVersion = activeVersion
    }

    /// one answer to "is it already here": the settings list asks it per
    /// model, and prewarm asks it once, before any bytes move, so setup can
    /// say whether the download it is about to start actually happened.
    nonisolated static func isOnDisk(
        _ version: SpeechModel,
        fileManager: FileManager = .default
    ) -> Bool {
        ModelFiles.isInstalled(version, fileManager: fileManager)
    }

    func installedModels() -> [InstalledModel] {
        SpeechModel.allCases.map { version in
            let isDownloaded = Self.isOnDisk(
                version,
                fileManager: fileManager
            )
            let size = isDownloaded
                ? ModelFiles.folder(for: version)
                    .map(recursiveAllocatedSize(of:)) ?? 0
                : 0

            return InstalledModel(
                version: version,
                isDownloaded: isDownloaded,
                onDiskSize: Self.formattedSize(size)
            )
        }
    }

    func removalDecision(
        for version: SpeechModel
    ) -> ModelRemovalDecision {
        ModelRemovalPolicy.decision(
            of: version,
            activeVersion: activeVersion()
        )
    }

    /// the decision is the caller’s cue to unload the engine, so it is
    /// only handed back once the bytes are actually gone — discarding
    /// it would mean tearing down for a delete that never happened.
    func remove(
        _ version: SpeechModel
    ) throws -> ModelRemovalDecision {
        let decision = removalDecision(for: version)

        guard let directory = ModelFiles.folder(for: version)?
            .standardizedFileURL,
              directory.deletingLastPathComponent()
                == Self.expectedParent(of: version) else {
            throw ModelStoreError.unsafeModelDirectory
        }

        if fileManager.fileExists(atPath: directory.path) {
            do {
                try fileManager.removeItem(at: directory)
            } catch {
                // "couldn’t remove download" tells you nothing you can
                // act on; the real reason usually names the fix.
                throw ModelStoreError.removalFailed(
                    version,
                    underlying: error
                )
            }
        }

        return decision
    }

    /// the one folder each kind of model may be removed from: anything
    /// else means a path went wrong, and nothing is deleted.
    private static func expectedParent(of version: SpeechModel) -> URL? {
        switch version.family {
        case .parakeet:
            MLModelConfigurationUtils
                .defaultModelsDirectory()
                .standardizedFileURL
        case .whisper:
            ModelFiles.whisperDirectory
                .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
                .standardizedFileURL
        case .whistle:
            AppIdentity.sharedModelDirectory.standardizedFileURL
        }
    }

    private func recursiveAllocatedSize(of directory: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
        ]
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return 0
        }

        var byteCount: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: keys),
                  values.isRegularFile == true else {
                continue
            }

            let fileByteCount = values.totalFileAllocatedSize
                ?? values.fileAllocatedSize
                ?? values.fileSize
                ?? 0
            byteCount += Int64(fileByteCount)
        }
        return byteCount
    }

    private static func formattedSize(_ byteCount: Int64) -> String {
        ByteCountFormatter.string(
            fromByteCount: byteCount,
            countStyle: .file
        ).lowercased()
    }
}
