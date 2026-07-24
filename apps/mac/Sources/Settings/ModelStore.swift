import FluidAudio
import Foundation

struct InstalledModel: Identifiable, Equatable {
    let version: EngineVersion
    let isDownloaded: Bool
    let onDiskSize: String

    var id: EngineVersion {
        version
    }
}

enum ModelStoreError: LocalizedError {
    case unsafeModelDirectory

    var errorDescription: String? {
        switch self {
        case .unsafeModelDirectory:
            "the model download location is invalid"
        }
    }
}

@MainActor
final class ModelStore {
    private let fileManager: FileManager
    private let activeVersion: @MainActor () -> EngineVersion

    init(
        fileManager: FileManager = .default,
        activeVersion: @escaping @MainActor () -> EngineVersion
    ) {
        self.fileManager = fileManager
        self.activeVersion = activeVersion
    }

    func installedModels() -> [InstalledModel] {
        EngineVersion.allCases.map { version in
            let directory = modelDirectory(for: version)
            let isDownloaded = isNonemptyDirectory(directory)
            let size = isDownloaded
                ? recursiveAllocatedSize(of: directory)
                : 0

            return InstalledModel(
                version: version,
                isDownloaded: isDownloaded,
                onDiskSize: Self.formattedSize(size)
            )
        }
    }

    func removalDecision(
        for version: EngineVersion
    ) -> ModelRemovalDecision {
        ModelRemovalPolicy.decision(
            of: version,
            activeVersion: activeVersion()
        )
    }

    @discardableResult
    func remove(
        _ version: EngineVersion
    ) throws -> ModelRemovalDecision {
        let decision = removalDecision(for: version)

        let modelsRoot = MLModelConfigurationUtils
            .defaultModelsDirectory()
            .standardizedFileURL
        let directory = modelDirectory(for: version).standardizedFileURL

        guard directory.deletingLastPathComponent() == modelsRoot else {
            throw ModelStoreError.unsafeModelDirectory
        }

        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }

        return decision
    }

    private func modelDirectory(for version: EngineVersion) -> URL {
        AsrModels.defaultCacheDirectory(for: version.asrModelVersion)
    }

    private func isNonemptyDirectory(_ directory: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: directory.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            return false
        }

        return (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).isEmpty) == false
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
