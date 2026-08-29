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
        case meetingLeftovers
        case settings
        case speechModels
        case permissions

        var id: String { rawValue }

        var title: String {
            switch self {
            case .dictations: "everything you've dictated"
            case .dictionary: "your dictionary"
            case .meetingLeftovers: "unfinished meeting audio and the hook log"
            case .settings: "settings and preferences"
            case .speechModels: "the speech models"
            case .permissions: "the permissions you granted"
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
            case .permissions:
                "microphone, accessibility, system audio. macOS asks again if you come back."
            case .meetingLeftovers:
                "your saved transcripts are documents, in the folder you chose — they stay."
            case .dictionary, .settings:
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
    /// Forgets every grant macOS holds for a bundle id. Injected so a test
    /// never runs `tccutil` against the author's real machine.
    let resetPermissions: (String) throws -> Void

    init(
        supportDirectory: URL = AppIdentity.supportDirectory,
        modelDirectory: URL = AppIdentity.sharedModelDirectory,
        preferencesDomain: String = AppIdentity.bundleID,
        fileManager: FileManager = .default,
        userDefaults: UserDefaults = .standard,
        resetPermissions: @escaping (String) throws -> Void = Remover.resetPermissionsWithTCCUtil
    ) {
        self.supportDirectory = supportDirectory
        self.modelDirectory = modelDirectory
        self.preferencesDomain = preferencesDomain
        self.fileManager = fileManager
        self.userDefaults = userDefaults
        self.resetPermissions = resetPermissions
    }

    /// `tccutil reset All <bundle id>` — the same thing a person would type,
    /// and the only supported way to make macOS forget. Notifications are
    /// not TCC and stay in system settings › notifications.
    static func resetPermissionsWithTCCUtil(_ bundleID: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "All", bundleID]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.executableRuntimeMismatch)
        }
    }

    func url(for item: RemovalPlan.Item) -> URL? {
        switch item {
        case .dictations:
            supportDirectory.appendingPathComponent("dictations.jsonl")
        case .dictionary:
            supportDirectory.appendingPathComponent("dictionary.json")
        case .meetingLeftovers:
            // two things, one item: the spool folder and hooks.log. the
            // folder is the url; the log goes with it in `remove`.
            supportDirectory.appendingPathComponent("meeting-spool", isDirectory: true)
        case .speechModels:
            modelDirectory
        case .settings, .permissions:
            nil
        }
    }

    func plan() -> RemovalPlan {
        RemovalPlan(
            entries: RemovalPlan.Item.allCases.map { item in
                guard let url = url(for: item) else {
                    // Preferences are a domain, not a file. They are always
                    // worth offering: leaving them behind is how an app
                    // "reinstalls" with its old state intact. Permissions
                    // cannot be asked about at all (ADR 0021); they are
                    // offered once setup has ever run, because that is when
                    // a grant was first asked for.
                    let domain = userDefaults.persistentDomain(forName: preferencesDomain)
                    return RemovalPlan.Entry(
                        item: item,
                        bytes: 0,
                        exists: item == .permissions
                            ? domain?["AndrewDictate.onboardingCompleted"] as? Bool == true
                            : domain?.isEmpty == false
                    )
                }
                var size = allocatedSize(of: url)
                var exists = fileManager.fileExists(atPath: url.path)
                if item == .meetingLeftovers {
                    let log = supportDirectory.appendingPathComponent("hooks.log")
                    if fileManager.fileExists(atPath: log.path) {
                        size += allocatedSize(of: log)
                        exists = true
                    }
                }
                return RemovalPlan.Entry(item: item, bytes: size, exists: exists)
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
                if item == .permissions {
                    do {
                        try resetPermissions(preferencesDomain)
                    } catch {
                        failed.append(item)
                        Self.logger.error("couldn't reset permissions: \(error.localizedDescription, privacy: .public)")
                        onFailure(item, error)
                    }
                } else {
                    userDefaults.removePersistentDomain(
                        forName: preferencesDomain
                    )
                }
                continue
            }
            if item == .meetingLeftovers {
                let log = supportDirectory.appendingPathComponent("hooks.log")
                if fileManager.fileExists(atPath: log.path) {
                    try? fileManager.removeItem(at: log)
                }
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
