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
    /// the app added it: you made the same sound-alike swap to text we
    /// inserted twice (ADR 0046). it fires like any other row; the mark is
    /// only so you can tell, and so taking it out means "don't learn that".
    var learned: Bool

    init(
        id: UUID = UUID(),
        wrong: String,
        right: String,
        learned: Bool = false
    ) {
        self.id = id
        self.wrong = wrong
        self.right = right
        self.learned = learned
    }

    private enum CodingKeys: String, CodingKey {
        case id, wrong, right, learned
    }

    /// a file written before the app could learn has no mark on any row:
    /// every one of them is yours.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        wrong = try container.decode(String.self, forKey: .wrong)
        right = try container.decode(String.self, forKey: .right)
        learned = try container.decodeIfPresent(Bool.self, forKey: .learned)
            ?? false
    }

    /// the mark is written only where it is true, so a row you typed reads
    /// exactly as it always has — in an export, an older copy of the app,
    /// or a text editor.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(wrong, forKey: .wrong)
        try container.encode(right, forKey: .right)
        if learned {
            try container.encode(learned, forKey: .learned)
        }
    }
}

/// one rule as the learner counts it: the side that matches, folded the way
/// the substitution folds it, and the side it becomes, as written.
struct LearningKey: Codable, Hashable, Sendable {
    let wrong: String
    let right: String

    init(wrong: String, right: String) {
        self.wrong = DictionaryStore.matchKey(wrong)
        self.right = right
    }

    init(_ entry: DictionaryEntry) {
        self.init(wrong: entry.wrong, right: entry.right)
    }
}

@MainActor
final class DictionaryStore: ObservableObject {
    @Published private(set) var entries: [DictionaryEntry] = []

    /// learned entries you took out. kept in plain text beside the
    /// dictionary, because each one is a rule you were shown and turned
    /// down — no more private than the rows that file already holds — and a
    /// hash would be a list you could neither read nor clear.
    private(set) var neverLearn: Set<LearningKey> = []

    /// nil while disk and memory agree. otherwise a sentence the settings
    /// pane can show the user verbatim.
    @Published private(set) var lastFailure: String?

    /// what a merge did, so the pane can say it in words.
    struct MergeResult: Equatable, Sendable {
        let added: Int
        let updated: Int
    }

    /// a failed read leaves `entries` empty for reasons the user never
    /// asked for, so an empty table isn't proof of an empty dictionary and
    /// the unreadable file must survive the next write.
    private var loadFailed = false

    private let fileURL: URL

    /// in the app's folder. the remover takes both together.
    static let fileName = "dictionary.json"
    static let neverLearnFileName = "never-learn.json"

    private var neverLearnURL: URL {
        fileURL.deletingLastPathComponent()
            .appendingPathComponent(Self.neverLearnFileName, isDirectory: false)
    }

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        load()
        loadNeverLearn()
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

        // emptying the right side of a working rule used to save, and the
        // rule then deleted that word from every dictation afterwards.
        // typing the wrong side first still saves — only the clearing case
        // is refused.
        let clearsAWorkingRule = !entries[index].right.isEmpty
            && entry.right
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        guard !clearsAWorkingRule else {
            lastFailure = """
                a word has to become something. remove the row to drop the \
                rule.
                """
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

        let removed = entries.remove(at: index)
        guard save() else {
            return false
        }
        // the menu's undo and the table's minus mean the same thing for a
        // row the app added: you saw it and said no.
        if removed.learned {
            rememberNeverLearn(LearningKey(removed))
        }
        return true
    }

    @discardableResult
    func remove(_ entry: DictionaryEntry) -> Bool {
        remove(id: entry.id)
    }

    /// Reads the file and touches nothing else. Import asks before it
    /// replaces, and it cannot ask until it knows what the file holds.
    func decodeEntries(from sourceURL: URL) -> [DictionaryEntry]? {
        do {
            let data = try Data(contentsOf: sourceURL)
            return try JSONDecoder().decode(
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
            return nil
        }
    }

    @discardableResult
    func replace(with imported: [DictionaryEntry]) -> Bool {
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

    /// What an import does when you keep your own words: upsert by `wrong`,
    /// so a file someone sent you can add rules and correct rules but never
    /// delete one you taught it. nil means the write failed and the rows you
    /// had are still the rows you have.
    @discardableResult
    func merge(_ imported: [DictionaryEntry]) -> MergeResult? {
        let previous = entries
        var added = 0
        var updated = 0

        for entry in imported {
            // the same refusal the table makes: a rule that becomes nothing
            // is a rule that can never fire, and a file someone sent you
            // does not get to empty a word you taught it.
            guard !entry.right
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty else {
                continue
            }

            let key = Self.matchKey(entry.wrong)
            guard let index = entries.firstIndex(where: {
                Self.matchKey($0.wrong) == key
            }) else {
                entries.append(entry)
                added += 1
                continue
            }
            guard entries[index].right != entry.right else {
                continue
            }
            // the row keeps its id and the spelling you typed; the file only
            // gets to say what the word becomes.
            entries[index].right = entry.right
            updated += 1
        }

        let result = MergeResult(added: added, updated: updated)
        guard added > 0 || updated > 0 else {
            // the same file twice changes nothing, so nothing is written.
            return result
        }
        guard save() else {
            entries = previous
            return nil
        }
        return result
    }

    /// trimmed and case-folded — the identity `DictionarySubstitutions`
    /// matches on, so a merge can never leave two rows that both fire, and
    /// the suggestion scan can tell what you have already taught it.
    nonisolated static func matchKey(_ wrong: String) -> String {
        wrong.trimmingCharacters(in: .whitespaces).lowercased()
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

    /// no file is the usual case; an unreadable one is logged and treated as
    /// empty — the worst that costs is a rule offered to you a second time.
    private func loadNeverLearn() {
        guard FileManager.default.fileExists(atPath: neverLearnURL.path) else {
            return
        }
        do {
            let data = try Data(contentsOf: neverLearnURL)
            neverLearn = Set(try JSONDecoder().decode([LearningKey].self, from: data))
        } catch {
            dictionaryLogger.error(
                """
                never-learn list unreadable: \
                \(error.localizedDescription, privacy: .public)
                """
            )
        }
    }

    private func rememberNeverLearn(_ key: LearningKey) {
        neverLearn.insert(key)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let sorted = neverLearn.sorted {
                ($0.wrong, $0.right) < ($1.wrong, $1.right)
            }
            try encoder.encode(sorted).write(to: neverLearnURL, options: .atomic)
        } catch {
            // the row is gone either way; this list only stops it coming
            // back, and in memory it still does until the app quits.
            dictionaryLogger.error(
                """
                never-learn list not saved: \
                \(error.localizedDescription, privacy: .public)
                """
            )
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
            .appendingPathComponent(fileName, isDirectory: false)
    }
}
