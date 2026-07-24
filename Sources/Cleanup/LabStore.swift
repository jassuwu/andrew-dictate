import Foundation

struct CleanupLabEntry: Codable, Equatable, Sendable {
    let ts: Date
    let backend: String
    let latencyMs: Double
    let raw: String
    let cleaned: String
}

actor LabStore {
    private let fileURL: URL
    private let capacity: Int

    init(
        fileURL: URL = LabStore.defaultFileURL(),
        capacity: Int = 500
    ) {
        self.fileURL = fileURL
        self.capacity = max(1, capacity)
    }

    func load() throws -> [CleanupLabEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        return Self.capped(
            Self.decodeJSONL(data),
            capacity: capacity
        )
    }

    func append(_ entry: CleanupLabEntry) throws {
        let currentEntries = try load()
        let entries = currentEntries + [entry]

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if entries.count > capacity {
            try Self.encodeJSONL(
                Self.capped(entries, capacity: capacity)
            ).write(to: fileURL, options: .atomic)
            return
        }

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            _ = FileManager.default.createFile(
                atPath: fileURL.path,
                contents: nil
            )
        }

        let handle = try FileHandle(forWritingTo: fileURL)
        defer {
            try? handle.close()
        }
        try handle.seekToEnd()

        if handle.offsetInFile > 0 {
            try handle.write(contentsOf: Data([0x0A]))
        }
        try handle.write(contentsOf: Self.encodeEntry(entry))
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: fileURL)
    }

    nonisolated static func capped(
        _ entries: [CleanupLabEntry],
        capacity: Int
    ) -> [CleanupLabEntry] {
        Array(entries.suffix(max(1, capacity)))
    }

    nonisolated static func encodeJSONL(
        _ entries: [CleanupLabEntry]
    ) throws -> Data {
        var data = Data()
        for (index, entry) in entries.enumerated() {
            if index > 0 {
                data.append(0x0A)
            }
            data.append(try encodeEntry(entry))
        }
        return data
    }

    nonisolated static func decodeJSONL(
        _ data: Data
    ) -> [CleanupLabEntry] {
        data.split(separator: 0x0A).compactMap { line in
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(
                CleanupLabEntry.self,
                from: Data(line)
            )
        }
    }

    nonisolated static func defaultFileURL() -> URL {
        FileManager.default
            .urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            .appendingPathComponent(
                "Andrew Dictate",
                isDirectory: true
            )
            .appendingPathComponent(
                "cleanup-lab.jsonl",
                isDirectory: false
            )
    }

    private nonisolated static func encodeEntry(
        _ entry: CleanupLabEntry
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(entry)
    }
}
