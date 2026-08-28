import Combine
import Foundation
import OSLog

/// file scope because the first load runs during init, before there is a
/// `self` to log through.
private let dictionaryLogger = Logger(
    subsystem: AppIdentity.loggingSubsystem,
    category: "dictionary"
)

struct DictionaryEntry: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var wrong: String
    var right: String

    init(id: UUID = UUID(), wrong: String, right: String) {
        self.id = id
        self.wrong = wrong
        self.right = right
    }
}

@MainActor
final class DictionaryStore: ObservableObject {
    @Published private(set) var entries: [DictionaryEntry] = []

    /// nil while disk and memory agree. otherwise a sentence the settings
    /// pane can show the user verbatim.
    @Published private(set) var lastFailure: String?

    /// a failed read leaves `entries` empty for reasons the user never
    /// asked for, so an empty table isn't proof of an empty dictionary and
    /// the unreadable file must survive the next write.
    private var loadFailed = false

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        load()
    }

    @discardableResult
    func add(wrong: String, right: String) -> Bool {
        add(DictionaryEntry(wrong: wrong, right: right))
    }

    /// takes a built entry so callers that need the new id — to select the
    /// fresh row — don't have to fish it back out of `entries`.
    @discardableResult
    func add(_ entry: DictionaryEntry) -> Bool {
        entries.append(entry)
        return save()
    }

    @discardableResult
    func update(_ entry: DictionaryEntry) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == entry.id })
        else {
            // the row is already gone; nothing to persist and no i/o went
            // wrong, so an existing failure keeps standing.
            return false
        }

        entries[index] = entry
        return save()
    }

    @discardableResult
    func update(id: UUID, wrong: String, right: String) -> Bool {
        update(DictionaryEntry(id: id, wrong: wrong, right: right))
    }

    @discardableResult
    func updateWrong(id: UUID, wrong: String) -> Bool {
        guard let entry = entries.first(where: { $0.id == id }) else {
            return false
        }
        return update(id: id, wrong: wrong, right: entry.right)
    }

    @discardableResult
    func updateRight(id: UUID, right: String) -> Bool {
        guard let entry = entries.first(where: { $0.id == id }) else {
            return false
        }
        return update(id: id, wrong: entry.wrong, right: right)
    }

    @discardableResult
    func remove(id: UUID) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            return false
        }

        entries.remove(at: index)
        return save()
    }

    @discardableResult
    func remove(_ entry: DictionaryEntry) -> Bool {
        remove(id: entry.id)
    }

    @discardableResult
    func importJSON(from sourceURL: URL) -> Bool {
        let imported: [DictionaryEntry]
        do {
            let data = try Data(contentsOf: sourceURL)
            imported = try JSONDecoder().decode(
                [DictionaryEntry].self,
                from: data
            )
        } catch {
            dictionaryLogger.error(
                """
                dictionary import failed: \
                \(error.localizedDescription, privacy: .public)
                """
            )
            lastFailure = """
                couldn’t import that file — it may not be a dictionary.
                """
            return false
        }

        // an import that can't reach disk must not look like it landed, so
        // the old rows come back if the write fails.
        let previous = entries
        entries = imported
        guard save() else {
            entries = previous
            return false
        }
        return true
    }

    @discardableResult
    func exportJSON(to destinationURL: URL) -> Bool {
        do {
            let data = try encodedEntries()
            try data.write(to: destinationURL, options: .atomic)
            clearFailure()
            return true
        } catch {
            dictionaryLogger.error(
                """
                dictionary export failed: \
                \(error.localizedDescription, privacy: .public)
                """
            )
            lastFailure = """
                couldn’t export your dictionary — nothing was written.
                """
            return false
        }
    }

    private func load() {
        // no file yet is a normal first run, not a failure.
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            entries = try JSONDecoder().decode(
                [DictionaryEntry].self,
                from: data
            )
            loadFailed = false
            lastFailure = nil
        } catch {
            dictionaryLogger.error(
                """
                dictionary load failed: \
                \(error.localizedDescription, privacy: .public)
                """
            )
            loadFailed = true
            lastFailure = """
                couldn’t read your dictionary — the file may be damaged. \
                your saved words are still on disk.
                """
        }
    }

    @discardableResult
    private func save() -> Bool {
        guard preserveUnreadableFile() else {
            return false
        }

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let data = try encodedEntries()
            try data.write(to: fileURL, options: .atomic)
            loadFailed = false
            lastFailure = nil
            return true
        } catch {
            dictionaryLogger.error(
                """
                dictionary save failed: \
                \(error.localizedDescription, privacy: .public)
                """
            )
            lastFailure = """
                couldn’t save your dictionary — that change lives only in \
                this window.
                """
            return false
        }
    }

    /// the file we failed to read still holds the user's words. move it
    /// aside before a save overwrites it, and refuse the save if it won't
    /// move — losing the words silently is the worse outcome.
    private func preserveUnreadableFile() -> Bool {
        guard loadFailed,
              FileManager.default.fileExists(atPath: fileURL.path) else {
            return true
        }

        let stamp = Int(Date().timeIntervalSince1970)
        let base = fileURL.deletingPathExtension().lastPathComponent
        let backupURL = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                "\(base)-damaged-\(stamp).json",
                isDirectory: false
            )

        do {
            try FileManager.default.moveItem(at: fileURL, to: backupURL)
            dictionaryLogger.notice(
                """
                kept unreadable dictionary as \
                \(backupURL.lastPathComponent, privacy: .public)
                """
            )
            return true
        } catch {
            dictionaryLogger.error(
                """
                dictionary backup failed: \
                \(error.localizedDescription, privacy: .public)
                """
            )
            lastFailure = """
                couldn’t set the damaged dictionary file aside — nothing \
                was overwritten.
                """
            return false
        }
    }

    /// a stale message would outlive its problem, but an unread file is
    /// still unread until something rewrites it.
    private func clearFailure() {
        guard !loadFailed else {
            return
        }
        lastFailure = nil
    }

    private func encodedEntries() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(entries)
    }

    private static func defaultFileURL() -> URL {
        AppIdentity.supportDirectory
            .appendingPathComponent("dictionary.json", isDirectory: false)
    }
}
