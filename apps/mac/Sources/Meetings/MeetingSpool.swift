import Foundation

/// The audio that exists only while a meeting is being recorded. It lives in
/// application support, not in your meetings folder, at 0600, and is deleted
/// the moment the transcript is written (ADR 0040). A spool still on disk at
/// launch means the app died mid-meeting — and that is worth a transcript
/// too, flagged `recovered`.
struct MeetingSpool: Sendable {
    struct Manifest: Codable, Equatable, Sendable {
        let app: String
        let started: Date
        let engine: String
        let model: MeetingModel
    }

    struct Handle: Equatable, Sendable {
        let folder: URL

        var audioURL: URL { folder.appendingPathComponent("audio.caf") }
        var manifestURL: URL { folder.appendingPathComponent("manifest.json") }
    }

    let root: URL

    init(root: URL = Self.defaultRoot) {
        self.root = root
    }

    static var defaultRoot: URL {
        AppIdentity.supportDirectory
            .appendingPathComponent("meeting-spool", isDirectory: true)
    }

    func begin(_ manifest: Manifest) throws -> Handle {
        let fm = FileManager.default
        let private700: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        try fm.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: private700)
        try fm.setAttributes(private700, ofItemAtPath: root.path)

        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(
            at: folder, withIntermediateDirectories: false, attributes: private700)

        let handle = Handle(folder: folder)
        let data = try Self.encoder.encode(manifest)
        try data.write(to: handle.manifestURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: handle.manifestURL.path)
        return handle
    }

    /// The transcript is written; the audio has done its job.
    func finish(_ handle: Handle) throws {
        try FileManager.default.removeItem(at: handle.folder)
    }

    func discard(_ handle: Handle) {
        try? FileManager.default.removeItem(at: handle.folder)
    }

    /// Spools with a manifest and audio, oldest first. A folder whose manifest
    /// cannot be read is junk and is swept; a manifest without audio is a
    /// meeting that has just begun and is left alone.
    func orphans() -> [(handle: Handle, manifest: Manifest)] {
        let fm = FileManager.default
        // Names, not URLs: `contentsOfDirectory(at:)` hands back resolved
        // paths (/private/var/…) that would never equal the handles we
        // issued against `root` as given.
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else {
            return []
        }

        var found: [(handle: Handle, manifest: Manifest)] = []
        for name in names where !name.hasPrefix(".") {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            let handle = Handle(folder: folder)
            guard let data = try? Data(contentsOf: handle.manifestURL),
                  let manifest = try? Self.decoder.decode(Manifest.self, from: data)
            else {
                try? fm.removeItem(at: folder)
                continue
            }
            guard fm.fileExists(atPath: handle.audioURL.path) else {
                continue
            }
            found.append((handle, manifest))
        }
        return found.sorted { $0.manifest.started < $1.manifest.started }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
