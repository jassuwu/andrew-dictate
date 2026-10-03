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
        /// The transcript this audio was written out into, once it has been.
        /// A spool with one is not an orphan — its meeting is on disk, and
        /// writing it out again would be a second file for one meeting — but
        /// audio on its way to being kept, or to being deleted.
        var transcript: URL?
        /// Set with `transcript` when the audio was not to be kept: its
        /// delete failed, or the app stopped in the middle of it, and the
        /// next launch finishes it. Absent is kept, as every written-out
        /// spool was before there was a way to say otherwise.
        var deleteAudio: Bool?
        /// The meeting's gaps, noted as each began and ended, with where
        /// the spool's clock was at each: a recovery's file keeps them, and
        /// its turns land where the meeting had them. Optional, like
        /// `attempts`: a manifest from before them reads as a meeting that
        /// had none.
        var gaps: [Gap]?
        /// How long the meeting had run by the wall, in seconds, when this
        /// was last written: at each end of a gap, and at the stop. A spool
        /// holds only the audio it was given, and a sleep gives it none.
        var durationS: Double?

        var duration: Duration? {
            get { durationS.map { .seconds($0) } }
            set { durationS = newValue?.totalSeconds }
        }
    }

    /// A gap as a meeting notes it while it runs: where it began on the
    /// meeting's clock and how much audio the spool held then, and the same
    /// for its end once it has one.
    struct Gap: Equatable, Sendable {
        var began: Duration
        var spooledAtBegan: Duration
        var ended: Duration?
        var spooledAtEnded: Duration?

        init(
            began: Duration, spooledAtBegan: Duration,
            ended: Duration? = nil, spooledAtEnded: Duration? = nil
        ) {
            self.began = began
            self.spooledAtBegan = spooledAtBegan
            self.ended = ended
            self.spooledAtEnded = spooledAtEnded
        }

        /// One that has closed, as it is noted.
        init(_ gap: SpoolClock.Gap) {
            self.init(
                began: gap.began, spooledAtBegan: gap.spooledAtBegan,
                ended: gap.ended, spooledAtEnded: gap.spooledAtEnded)
        }

        /// On both clocks, once it has closed.
        var closed: SpoolClock.Gap? {
            guard let ended, let spooledAtEnded else { return nil }
            return SpoolClock.Gap(
                began: began, ended: ended,
                spooledAtBegan: spooledAtBegan, spooledAtEnded: spooledAtEnded)
        }
    }

    struct Handle: Equatable, Sendable {
        let folder: URL

        var audioURL: URL { folder.appendingPathComponent("audio.caf") }
        var manifestURL: URL { folder.appendingPathComponent("manifest.json") }
    }

    let root: URL
    /// How a spool's files are deleted once its meeting is written out.
    /// Injected so a test can have the disk refuse.
    private let remove: @Sendable (URL) throws -> Void

    private static let logger = Logger(subsystem: AppIdentity.loggingSubsystem, category: "meeting-spool")

    init(
        root: URL = Self.defaultRoot,
        remove: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) {
        self.root = root
        self.remove = remove
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

    /// The transcript is written into `transcript` and the audio is not to
    /// be kept: it has done its job. The manifest says so before anything
    /// is deleted, so a delete the disk refuses — or an app that stops in
    /// the middle of one — leaves a spool the next launch deletes, and
    /// never one it writes out a second time. Then the audio, so no part of
    /// a delete leaves audio without the manifest that says whose it is;
    /// then the rest. False when it is not all gone.
    @discardableResult
    func finish(_ handle: Handle, writtenTo transcript: URL) -> Bool {
        let marked = update(handle) {
            $0.transcript = transcript
            $0.deleteAudio = true
        }
        if !marked {
            Self.logger.error("a written-out spool could not be marked before it was deleted")
        }
        return letGo(handle)
    }

    /// A spool whose meeting is written out and whose audio was to go with
    /// it, gone: what `finish` could not do, done at a later launch.
    @discardableResult
    func letGo(_ handle: Handle) -> Bool {
        do {
            if FileManager.default.fileExists(atPath: handle.audioURL.path) {
                try remove(handle.audioURL)
            }
            try remove(handle.folder)
            return true
        } catch {
            Self.logger.error("a written-out spool could not be deleted: \(error.localizedDescription, privacy: .public)")
            return false
        }
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

    /// The meeting's gaps so far and how long it has run, written over the
    /// last ones as they change: a launch after a crash finds what the
    /// meeting was, and not only what its spool holds. False when the
    /// manifest could not be read or rewritten; the meeting records on.
    @discardableResult
    func note(_ handle: Handle, gaps: [Gap], duration: Duration) -> Bool {
        update(handle) {
            $0.gaps = gaps
            $0.duration = duration
        }
    }

    /// Its meeting is written out, into `transcript`, and the audio is to be
    /// kept: `orphans()` stops offering it, and `writtenOut()` starts. False
    /// when the manifest could not be read or rewritten — then the next
    /// launch would write it out again.
    @discardableResult
    func keep(_ handle: Handle, writtenTo transcript: URL) -> Bool {
        update(handle) { $0.transcript = transcript }
    }

    /// The manifest as it reads, changed, and written back whole in its
    /// place. False when it could not be read or rewritten.
    private func update(_ handle: Handle, _ change: (inout Manifest) -> Void) -> Bool {
        guard let data = try? Data(contentsOf: handle.manifestURL),
              var manifest = try? Self.decoder.decode(Manifest.self, from: data)
        else {
            return false
        }
        change(&manifest)
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
    /// a meeting that has just begun and is left alone, unless its meeting
    /// is written out, when it is what a delete left and is swept; one set
    /// aside is never offered again, and nor is one whose meeting is
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
                if fm.fileExists(atPath: handle.audioURL.path) {
                    Self.logger.error("a spool's manifest could not be read, so its audio is set aside")
                    setAside(handle)
                } else {
                    try? fm.removeItem(at: folder)
                }
                continue
            }
            guard fm.fileExists(atPath: handle.audioURL.path) else {
                // its meeting written out and its audio gone where it was
                // going: only the folder was left, and nothing needs it.
                if manifest.transcript != nil {
                    try? fm.removeItem(at: folder)
                }
                continue
            }
            guard manifest.transcript == nil else {
                continue
            }
            found.append((handle, manifest))
        }
        return found.sorted { $0.manifest.started < $1.manifest.started }
    }

    /// One spool, looked at again: its manifest as it now reads, when it is
    /// still an orphan — its audio there and its meeting not written out —
    /// and nil when it is gone, set aside, written out, or will not read.
    func orphan(_ handle: Handle) -> Manifest? {
        guard FileManager.default.fileExists(atPath: handle.audioURL.path),
              let data = try? Data(contentsOf: handle.manifestURL),
              let manifest = try? Self.decoder.decode(Manifest.self, from: data),
              manifest.transcript == nil
        else {
            return nil
        }
        return manifest
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

extension MeetingSpool.Manifest {
    /// The meeting a spool was, from what its manifest noted and the
    /// `spooled` audio it holds: its gaps on both clocks, and how long it
    /// ran — as long as last noted, or as far as its audio reaches on the
    /// meeting's clock, whichever is later. A gap still open is one the app
    /// died in, and it runs to that end. A manifest that noted nothing is a
    /// meeting with no gaps, as long as its audio.
    func meeting(spooled: Duration) -> (recording: MeetingSession.Recording, clock: SpoolClock) {
        var noted = gaps ?? []
        if let last = noted.indices.last, noted[last].ended == nil {
            let reached = noted[last].began + max(.zero, spooled - noted[last].spooledAtBegan)
            noted[last].ended = max(duration ?? .zero, reached)
            noted[last].spooledAtEnded = spooled
        }
        let clock = SpoolClock(noted.compactMap(\.closed))
        let ran = max(duration ?? .zero, clock.onTheMeetingsClock(spooled))
        return (MeetingSession.Recording(duration: ran, gaps: clock.meetingGaps), clock)
    }
}

/// Seconds on disk, like the file's gaps: whoever opens a manifest can read
/// it, and an open gap has no end yet.
extension MeetingSpool.Gap: Codable {
    private enum CodingKeys: String, CodingKey {
        case began
        case spooledAtBegan
        case ended
        case spooledAtEnded
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            began: .seconds(try container.decode(Double.self, forKey: .began)),
            spooledAtBegan: .seconds(try container.decode(Double.self, forKey: .spooledAtBegan)),
            ended: try container.decodeIfPresent(Double.self, forKey: .ended).map { .seconds($0) },
            spooledAtEnded: try container.decodeIfPresent(Double.self, forKey: .spooledAtEnded)
                .map { .seconds($0) })
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(began.totalSeconds, forKey: .began)
        try container.encode(spooledAtBegan.totalSeconds, forKey: .spooledAtBegan)
        try container.encodeIfPresent(ended?.totalSeconds, forKey: .ended)
        try container.encodeIfPresent(spooledAtEnded?.totalSeconds, forKey: .spooledAtEnded)
    }
}
