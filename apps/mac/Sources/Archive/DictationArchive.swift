import Foundation

/// Every dictation, on disk, until the user deletes it.
///
/// **One JSON object per line, appended.** A single JSON array would have to be
/// re-encoded and rewritten on every dictation, and this file is expected to
/// grow for years at a hundred entries a day. Appending is O(1) and a partial
/// write can only damage the last line.
///
/// The file is chmod 0600. It is a permanent record of everything its owner has
/// said, and the default 0644 would make that readable by every other account
/// on the machine.
struct DictationArchive {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    static func defaultFileURL() -> URL {
        AppIdentity.supportDirectory
            .appendingPathComponent("dictations.jsonl", isDirectory: false)
    }

    func append(_ dictation: Dictation) throws {
        var line = try Self.encoder.encode(dictation)
        line.append(0x0A)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard FileManager.default.createFile(
                atPath: fileURL.path,
                contents: line,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return
        }

        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    /// Oldest first. A line that will not decode is skipped rather than thrown:
    /// one damaged entry must not cost the user every dictation they have.
    ///
    /// A file that exists and will not read is the one case that does throw.
    /// SPEC §4 applied to the archive: an unreadable archive must not be
    /// handed back looking like an empty one.
    func all() throws -> [Dictation] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        // Split the bytes, not a decoded string: JSONDecoder validates UTF-8
        // itself, so a torn tail or a lone bad byte costs exactly the line it
        // is on — which is what makes the non-atomic append survivable.
        return try Data(contentsOf: fileURL)
            .split(separator: 0x0A, omittingEmptySubsequences: true)
            .compactMap {
                try? Self.decoder.decode(Dictation.self, from: Data($0))
            }
    }

    /// The newest kept dictation, which is what "fix a word…" opens on at
    /// launch. It reads the whole file to take the last line — the same
    /// ceiling every read here has, and one entry point the seed can be
    /// tested through.
    func latest() throws -> Dictation? {
        try all().last
    }

    func delete(id: UUID) throws {
        try replace(with: try all().filter { $0.id != id })
    }

    func deleteAll() throws {
        try replace(with: [])
    }

    /// Deletion is the one operation that rewrites. An emptied archive removes
    /// the file rather than truncating it, so "delete everything" leaves
    /// nothing on disk to be recovered.
    private func replace(with dictations: [Dictation]) throws {
        guard !dictations.isEmpty else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }

        var data = Data()
        for dictation in dictations {
            data.append(try Self.encoder.encode(dictation))
            data.append(0x0A)
        }
        try data.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
