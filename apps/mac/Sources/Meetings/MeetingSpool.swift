import Foundation
import os

/// The audio of a meeting while it is being recorded. It lives in
/// application support, not in your meetings folder, at 0600. Once the
/// transcript is written it becomes kept audio, or is deleted then and there
/// when that is the setting (ADR 0048). A spool still on disk at launch with
/// no transcript means the app died mid-meeting — and that is worth a
/// transcript too, flagged `recovered`.
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
        /// and the audio is to be kept. A spool with one is not an orphan —
        /// its meeting is on disk, and writing it out again would be a
        /// second file for one meeting — but audio on its way to being kept.
        var transcript: URL?
    }

    struct Handle: Equatable, Sendable {
        let folder: URL

        var audioURL: URL { folder.appendingPathComponent("audio.caf") }
        var manifestURL: URL { folder.appendingPathComponent("manifest.json") }
    }

    let root: URL

    private static let logger = Logger(subsystem: AppIdentity.loggingSubsystem, category: "meeting-spool")

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

    /// The transcript is written and the audio is not to be kept: it has
    /// done its job.
    func finish(_ handle: Handle) throws {
        try FileManager.default.removeItem(at: handle.folder)
    }

    func discard(_ handle: Handle) {
        try? FileManager.default.removeItem(at: handle.folder)
    }

    /// Where a spool goes when the app has tried twice and cannot read it,
    /// or cannot read its audio or its manifest at all. A meeting recording
    /// is never deleted, only set aside (ADR 0022).
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

    /// Its meeting is written out, into `transcript`, and the audio is to be
    /// kept: `orphans()` stops offering it, and `writtenOut()` starts. False
    /// when the manifest could not be read or rewritten — then the next
    /// launch would write it out again.
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
    /// deletes it — not even a recording already set aside under the same
    /// name, which this one then sits beside.
    func setAside(_ handle: Handle) {
        let fm = FileManager.default
        let folder = root.appendingPathComponent(
            Self.unreadableFolderName, isDirectory: true)
        try? fm.createDirectory(
            at: folder, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let name = handle.folder.lastPathComponent
        var destination = folder.appendingPathComponent(name, isDirectory: true)
        var copy = 2
        while fm.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent("\(name)-\(copy)", isDirectory: true)
            copy += 1
        }
        try? fm.moveItem(at: handle.folder, to: destination)
    }

    /// Every recording set aside, home again: back in the spool, where
    /// `orphans()` offers it, with its count of tries cleared. Returned as
    /// they now stand, so the caller can run recovery for exactly these and
    /// not for any other orphan that has a try left.
    func bringBackSetAside() -> [(handle: Handle, manifest: Manifest)] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: unreadableFolder.path)) ?? []
        var back: [(handle: Handle, manifest: Manifest)] = []
        for name in names.sorted() where !name.hasPrefix(".") {
            let aside = Handle(
                folder: unreadableFolder.appendingPathComponent(name, isDirectory: true))
            let home = Handle(folder: root.appendingPathComponent(name, isDirectory: true))
            // no audio is nothing to try, and a name taken in the spool is
            // not ours to write over: either stays where it is.
            guard fm.fileExists(atPath: aside.audioURL.path),
                  !fm.fileExists(atPath: home.folder.path)
            else {
                continue
            }
            var manifest = manifestToTry(in: aside)
            manifest.attempts = nil
            guard let cleared = try? Self.encoder.encode(manifest),
                  (try? cleared.write(to: aside.manifestURL, options: .atomic)) != nil,
                  (try? fm.moveItem(at: aside.folder, to: home.folder)) != nil
            else {
                continue
            }
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: home.manifestURL.path)
            back.append((home, manifest))
        }
        return back
    }

    /// The manifest as it reads, or a minimal one when it is gone or will
    /// not. One that is there and will not read is not ours to overwrite:
    /// it may be the only record of the app and the hour, so it is moved
    /// beside the new one.
    private func manifestToTry(in handle: Handle) -> Manifest {
        if let data = try? Data(contentsOf: handle.manifestURL),
           let manifest = try? Self.decoder.decode(Manifest.self, from: data) {
            return manifest
        }
        try? FileManager.default.moveItem(
            at: handle.manifestURL,
            to: handle.folder.appendingPathComponent("manifest.unreadable.json"))
        return minimalManifest(for: handle)
    }

    /// What a spool says about itself when its manifest is gone or will not
    /// read: nothing but its audio. That says when it was made, and the
    /// meeting is the unnamed one, to be read with the model the app would
    /// pick for a new meeting.
    private func minimalManifest(for handle: Handle) -> Manifest {
        let attributes = try? FileManager.default.attributesOfItem(atPath: handle.audioURL.path)
        let made = (attributes?[.creationDate] as? Date)
            ?? (attributes?[.modificationDate] as? Date)
            ?? Date()
        let model = MeetingModel.default
        return Manifest(
            app: MeetingCoordinator.unnamed, started: made, engine: model.rawValue,
            model: model)
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

    /// Spools with a manifest and audio, oldest first. A folder with audio
    /// whose manifest cannot be read is set aside, audio and all: the
    /// manifest is only what app and when, and the audio is the meeting. A
    /// folder with neither is junk and is swept; a manifest without audio is
    /// a meeting that has just begun and is left alone; one set aside is
    /// never offered again, and nor is one whose meeting is already written
    /// out.
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
                if fm.fileExists(atPath: handle.audioURL.path) {
                    Self.logger.error("a spool's manifest could not be read, so its audio is set aside")
                    setAside(handle)
                } else {
                    try? fm.removeItem(at: folder)
                }
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

    /// Spools whose meeting is written out and whose audio is still here:
    /// on its way to being kept when the app stopped, or kept here because
    /// it could not be moved.
    func writtenOut() -> [(handle: Handle, manifest: Manifest)] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        return names
            .filter { !$0.hasPrefix(".") && $0 != Self.unreadableFolderName }
            .compactMap { name in
                let handle = Handle(folder: root.appendingPathComponent(name, isDirectory: true))
                guard let data = try? Data(contentsOf: handle.manifestURL),
                      let manifest = try? Self.decoder.decode(Manifest.self, from: data),
                      manifest.transcript != nil,
                      fm.fileExists(atPath: handle.audioURL.path)
                else { return nil }
                return (handle, manifest)
            }
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
