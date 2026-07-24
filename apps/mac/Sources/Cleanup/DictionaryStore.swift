import Combine
import Foundation

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

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        load()
    }

    @discardableResult
    func add(wrong: String, right: String) -> DictionaryEntry {
        let entry = DictionaryEntry(wrong: wrong, right: right)
        entries.append(entry)
        save()
        return entry
    }

    func update(_ entry: DictionaryEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else {
            return
        }

        entries[index] = entry
        save()
    }

    func update(id: UUID, wrong: String, right: String) {
        update(DictionaryEntry(id: id, wrong: wrong, right: right))
    }

    func updateWrong(id: UUID, wrong: String) {
        guard let entry = entries.first(where: { $0.id == id }) else {
            return
        }
        update(id: id, wrong: wrong, right: entry.right)
    }

    func updateRight(id: UUID, right: String) {
        guard let entry = entries.first(where: { $0.id == id }) else {
            return
        }
        update(id: id, wrong: entry.wrong, right: right)
    }

    func remove(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            return
        }

        entries.remove(at: index)
        save()
    }

    func remove(_ entry: DictionaryEntry) {
        remove(id: entry.id)
    }

    func importJSON(from sourceURL: URL) throws {
        let data = try Data(contentsOf: sourceURL)
        let importedEntries = try JSONDecoder().decode(
            [DictionaryEntry].self,
            from: data
        )
        entries = importedEntries
        save()
    }

    func exportJSON(to destinationURL: URL) throws {
        let data = try encodedEntries()
        try data.write(to: destinationURL, options: .atomic)
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            entries = try JSONDecoder().decode(
                [DictionaryEntry].self,
                from: data
            )
        } catch {
            print("dictionary failed to load: \(error.localizedDescription)")
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let data = try encodedEntries()
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("dictionary failed to save: \(error.localizedDescription)")
        }
    }

    private func encodedEntries() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(entries)
    }

    private static func defaultFileURL() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Andrew Dictate", isDirectory: true)
            .appendingPathComponent("dictionary.json", isDirectory: false)
    }
}
