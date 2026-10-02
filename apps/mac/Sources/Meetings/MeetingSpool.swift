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
        /// How many launches have tried to write this one out and failed.
        /// Optional, not defaulted: a synthesized decoder does not fall back
        /// to a property's default, and a manifest written before the ledger
        /// existed must still read — sweeping it would be losing a meeting.
        var attempts: Int?
        /// The transcript this audio was written out into, once it has been
        /// and the audio is still wanted: the transcript did not cover it.
        /// A spool with one is not an orphan — its meeting is on disk, and
        /// writing it out again would be a second file for one meeting.
        var transcript: URL?
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

    /// Where a spool goes when the app has tried twice and cannot read it. A
    /// meeting recording is never deleted, only set aside (ADR 0022).
    static let unreadableFolderName = "unreadable"

    /// Two failed launches is enough: the third would be another quarter of
    /// an hour of the neural engine for the same nothing. The audio stays on
    /// disk, out of the retry loop, and settings says it is there.
    static let attemptsBeforeSettingAside = 2

    /// One more launch has tried and failed. Returns the manifest as it now
    /// stands, so the caller can decide whether that was the last try.
    @discardableResult
    func noteAttempt(_ handle: Handle, manifest: Manifest) -> Manifest {
        var updated = manifest
        updated.attempts = (manifest.attempts ?? 0) + 1
        guard let data = try? Self.encoder.encode(updated) else {
            return updated
        }
        do {
            try data.write(to: handle.manifestURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: handle.manifestURL.path)
        } catch {
            // A ledger that could not be written means one more try than
            // intended, which is better than losing the spool over it.
        }
        return updated
    }

    /// Its meeting is written out, into `transcript`, and the audio stays:
    /// `orphans()` stops offering it. False when the manifest could not be
    /// read or rewritten — then the next launch would write it out again.
    @discardableResult
    func keep(_ handle: Handle, writtenTo transcript: URL) -> Bool {
        guard let data = try? Data(contentsOf: handle.manifestURL),
              var manifest = try? Self.decoder.decode(Manifest.self, from: data)
        else {
            return false
        }
        manifest.transcript = transcript
        guard let updated = try? Self.encoder.encode(manifest),
              (try? updated.write(to: handle.manifestURL, options: .atomic)) != nil
        else {
            return false
        }
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: handle.manifestURL.path)
        return true
    }

    /// Out of the way, not away: `orphans()` stops offering it and nothing
    /// deletes it.
    func setAside(_ handle: Handle) {
        let fm = FileManager.default
        let folder = root.appendingPathComponent(
            Self.unreadableFolderName, isDirectory: true)
        try? fm.createDirectory(
            at: folder, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let destination = folder.appendingPathComponent(
            handle.folder.lastPathComponent, isDirectory: true)
        try? fm.removeItem(at: destination)
        try? fm.moveItem(at: handle.folder, to: destination)
    }

    /// The folder those go to, whether or not anything is in it — the
    /// settings row needs somewhere to send you.
    var unreadableFolder: URL {
        root.appendingPathComponent(Self.unreadableFolderName, isDirectory: true)
    }

    func unreadableCount() -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: unreadableFolder.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.count
    }

    /// One directory read, so launch can tell "a crash left something" from
    /// "nothing to do" without building what recovers it. True can still
    /// come to nothing — junk `orphans()` sweeps, a meeting just begun —
    /// but false is always nothing.
    func mayHoldOrphans() -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: root.path)) ?? []
        return names.contains {
            !$0.hasPrefix(".") && $0 != Self.unreadableFolderName
        }
    }

    /// Spools with a manifest and audio, oldest first. A folder whose manifest
    /// cannot be read is junk and is swept; a manifest without audio is a
    /// meeting that has just begun and is left alone; one set aside as
    /// unreadable is never offered again, and nor is one whose meeting is
    /// already written out.
    func orphans() -> [(handle: Handle, manifest: Manifest)] {
        let fm = FileManager.default
        // Names, not URLs: `contentsOfDirectory(at:)` hands back resolved
        // paths (/private/var/…) that would never equal the handles we
        // issued against `root` as given.
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else {
            return []
        }

        var found: [(handle: Handle, manifest: Manifest)] = []
        for name in names
        where !name.hasPrefix(".") && name != Self.unreadableFolderName {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            let handle = Handle(folder: folder)
            guard let data = try? Data(contentsOf: handle.manifestURL),
                  let manifest = try? Self.decoder.decode(Manifest.self, from: data)
            else {
                try? fm.removeItem(at: folder)
                continue
            }
            guard fm.fileExists(atPath: handle.audioURL.path),
                  manifest.transcript == nil
            else {
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
