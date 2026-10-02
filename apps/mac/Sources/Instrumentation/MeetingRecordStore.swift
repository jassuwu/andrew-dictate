import Foundation

/// The last two hundred meeting records, in the app's folder beside the
/// press log.
///
/// On disk because a meeting is looked into after it: on Friday, about
/// Tuesday, by someone who has since restarted the app a dozen times. Small
/// because it is evidence, not history: a few weeks of meetings, a few
/// dozen kilobytes, trimmed on every append. One JSON object per line, like
/// the press log, so a torn write costs one line.
///
/// No words in it, but it is still a record of when you were on a call, so
/// it is 0600 and it goes when you remove your data.
struct MeetingRecordStore: Sendable {
    static let capacity = 200
    /// in the app's folder. the remover takes it with your dictations.
    static let fileName = "meeting-records.jsonl"

    /// one file, more than one hand on it: the app appends from its queue
    /// while a wipe may be unlinking it. an append is a read and a rewrite,
    /// and a wipe landing between the two must not be undone.
    private static let lock = NSLock()

    let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    static func defaultFileURL() -> URL {
        AppIdentity.supportDirectory
            .appendingPathComponent(fileName, isDirectory: false)
    }

    /// rewrites the file each time: two hundred short lines is cheaper to
    /// rewrite than to reason about trimming lazily. lines are kept as bytes
    /// rather than decoded and re-encoded, so a record from a newer build
    /// survives an older one's append.
    func append(_ record: MeetingRecord) throws {
        try Self.lock.withLock {
            try unlockedAppend(record)
        }
    }

    private func unlockedAppend(_ record: MeetingRecord) throws {
        var lines = try rawLines()
        lines.append(try Self.encoder().encode(record))
        let kept = lines.suffix(Self.capacity)

        var data = Data()
        for line in kept {
            data.append(line)
            data.append(0x0A)
        }

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    /// oldest first. a line that will not decode is skipped, not thrown.
    func all() throws -> [MeetingRecord] {
        let decoder = Self.decoder()
        let lines = try Self.lock.withLock { try rawLines() }
        return lines.compactMap {
            try? decoder.decode(MeetingRecord.self, from: $0)
        }
    }

    /// the newest `count`, still oldest first.
    func recent(_ count: Int) throws -> [MeetingRecord] {
        Array(try all().suffix(count))
    }

    /// unlinked, not emptied: removing your data leaves nothing to recover.
    func deleteAll() throws {
        try Self.lock.withLock {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return
            }
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    private func rawLines() throws -> [Data] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        return try Data(contentsOf: fileURL)
            .split(separator: 0x0A, omittingEmptySubsequences: true)
            .map { Data($0) }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
