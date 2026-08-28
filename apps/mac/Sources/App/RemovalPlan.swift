import Foundation
import os

/// Everything this app has put on the machine, and what removing it costs.
///
/// "It leaves no traces" is a claim, and a claim the user cannot check is
/// marketing. This enumerates the actual paths, reports their real sizes, and
/// removes exactly what was chosen — including the two things that live outside
/// the app's own folder and would otherwise be left behind: the shared speech
/// model cache, and the preferences domain.
struct RemovalPlan {
    enum Item: String, CaseIterable, Identifiable, Sendable {
        case dictations
        case dictionary
        case labLog
        case settings
        case speechModels

        var id: String { rawValue }

        var title: String {
            switch self {
            case .dictations: "everything you've dictated"
            case .dictionary: "your dictionary"
            case .labLog: "the cleanup lab log"
            case .settings: "settings and preferences"
            case .speechModels: "the speech models"
            }
        }

        /// The part that stops a default from being a surprise.
        var caveat: String? {
            switch self {
            case .speechModels:
                "shared with any other app built on FluidAudio — "
                    + "removing this makes them download it again"
            case .dictations:
                "cannot be recovered"
            case .dictionary, .labLog, .settings:
                nil
            }
        }
    }

    struct Entry: Identifiable, Sendable {
        let item: Item
        let bytes: Int64
        /// False when there is nothing on disk to remove — shown, but as an
        /// already-clean line rather than a choice.
        let exists: Bool

        var id: String { item.id }
    }

    let entries: [Entry]

    var totalBytes: Int64 {
        entries.filter(\.exists).reduce(0) { $0 + $1.bytes }
    }
}

/// Finds what is on disk, and removes it.
///
/// Paths are injected so this can be tested against a scratch directory rather
/// than against the machine it runs on — a test that could delete the author's
/// real archive is not a test worth having.
struct Remover {
    let supportDirectory: URL
    let modelDirectory: URL
    let preferencesDomain: String
    let fileManager: FileManager
    let userDefaults: UserDefaults

    init(
        supportDirectory: URL = AppIdentity.supportDirectory,
        modelDirectory: URL = AppIdentity.sharedModelDirectory,
        preferencesDomain: String = AppIdentity.bundleID,
        fileManager: FileManager = .default,
        userDefaults: UserDefaults = .standard
    ) {
        self.supportDirectory = supportDirectory
        self.modelDirectory = modelDirectory
        self.preferencesDomain = preferencesDomain
        self.fileManager = fileManager
        self.userDefaults = userDefaults
    }

    func url(for item: RemovalPlan.Item) -> URL? {
        switch item {
        case .dictations:
            supportDirectory.appendingPathComponent("dictations.jsonl")
        case .dictionary:
            supportDirectory.appendingPathComponent("dictionary.json")
        case .labLog:
            supportDirectory.appendingPathComponent("cleanup-lab.jsonl")
        case .speechModels:
            modelDirectory
        case .settings:
            nil
        }
    }

    func plan() -> RemovalPlan {
        RemovalPlan(
            entries: RemovalPlan.Item.allCases.map { item in
                guard let url = url(for: item) else {
                    // Preferences are a domain, not a file. They are always
                    // worth offering: leaving them behind is how an app
                    // "reinstalls" with its old state intact.
                    return RemovalPlan.Entry(
                        item: item,
                        bytes: 0,
                        exists: userDefaults
                            .persistentDomain(forName: preferencesDomain)?
                            .isEmpty == false
                    )
                }
                let size = allocatedSize(of: url)
                return RemovalPlan.Entry(
                    item: item,
                    bytes: size,
                    exists: fileManager.fileExists(atPath: url.path)
                )
            }
        )
    }

    private static let logger = Logger(
        subsystem: AppIdentity.loggingSubsystem,
        category: "removal"
    )

    /// Removes each chosen item, and reports the ones it could not.
    /// A partial failure is returned rather than thrown: removing four of five
    /// things is a real outcome, and pretending otherwise would leave the user
    /// unsure what is still on their disk. `onFailure` carries the underlying
    /// error — a failure with no reason attached once cost an evening of
    /// guessing (ADR 0035).
    @discardableResult
    func remove(
        _ items: Set<RemovalPlan.Item>,
        onFailure: (RemovalPlan.Item, Error) -> Void = { _, _ in }
    ) -> [RemovalPlan.Item] {
        var failed: [RemovalPlan.Item] = []

        for item in RemovalPlan.Item.allCases where items.contains(item) {
            guard let url = url(for: item) else {
                userDefaults.removePersistentDomain(
                    forName: preferencesDomain
                )
                continue
            }
            guard fileManager.fileExists(atPath: url.path) else {
                continue
            }
            do {
                try fileManager.removeItem(at: url)
            } catch {
                failed.append(item)
                Self.logger.error(
                    """
                    couldn't remove \(item.rawValue, privacy: .public): \
                    \(error.localizedDescription, privacy: .public)
                    """
                )
                onFailure(item, error)
            }
        }

        // The app's own folder goes too, but only once it is empty — anything
        // still in there is something this plan did not know about, and
        // deleting it unseen would be worse than leaving it.
        if (try? fileManager.contentsOfDirectory(
            atPath: supportDirectory.path
        ))?.isEmpty == true {
            try? fileManager.removeItem(at: supportDirectory)
        }

        return failed
    }

    private func allocatedSize(of url: URL) -> Int64 {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ) else {
            return 0
        }

        guard isDirectory.boolValue else {
            let values = try? url.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]
            )
            return Int64(
                values?.totalFileAllocatedSize ?? values?.fileSize ?? 0
            )
        }

        guard let walker = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let child as URL in walker {
            let values = try? child.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]
            )
            total += Int64(
                values?.totalFileAllocatedSize ?? values?.fileSize ?? 0
            )
        }
        return total
    }
}
