import Combine
import Foundation

struct DictionaryEntry: Codable, Identifiable, Sendable {
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

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("dictionary failed to save: \(error.localizedDescription)")
        }
    }

    private static func defaultFileURL() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Andrew Dictate", isDirectory: true)
            .appendingPathComponent("dictionary.json", isDirectory: false)
    }
}
