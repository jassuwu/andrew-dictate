import AVFoundation
import Foundation
import os

/// How long a meeting's audio waits after its transcript is written, before
/// it is deleted without asking (ADR 0048). A transcript the coverage check
/// found thin keeps its audio until you delete it, whatever this says. Read
/// once when a meeting starts, like the folder and the model.
enum KeepMeetingAudio: String, CaseIterable, Identifiable, Sendable {
    case deleteAtOnce = "delete-at-once"
    case oneDay = "one-day"
    case sevenDays = "seven-days"

    static let `default` = oneDay

    var id: Self { self }

    /// The words the settings row offers.
    var label: String {
        switch self {
        case .deleteAtOnce: "delete at once"
        case .oneDay: "one day"
        case .sevenDays: "seven days"
        }
    }

    /// What the row says under its name, for the choice it shows. A thin
    /// transcript keeps its audio whatever is chosen.
    var caption: String {
        switch self {
        case .deleteAtOnce:
            "deleted the moment the transcript is written. a transcript that comes out thin keeps its audio on this mac, never in the transcripts folder, until you delete it."
        case .oneDay, .sevenDays:
            "it stays on this mac, never in the transcripts folder, and is deleted by itself after that. a transcript that comes out thin keeps its audio until you delete it."
        }
    }

    /// How long after the file it is kept, or nil for not at all.
    var keptFor: TimeInterval? {
        switch self {
        case .deleteAtOnce: nil
        case .oneDay: 86_400
        case .sevenDays: 7 * 86_400
        }
    }
}

/// A meeting's audio after its transcript is written: compressed, labelled,
/// and kept in the app's private folder — never in the transcripts folder —
/// until its date, then deleted without asking (ADR 0048).
///
/// `meeting-audio/<id>.m4a` is AAC at the spool's 16 kHz with the two sides
/// still two channels, and `meeting-audio/<id>.json` beside it says which
/// transcript it belongs to, when the meeting started, the model, and until
/// when it is kept — or that it is kept until you delete it. A spool that
/// would not compress is kept as it was, `<id>.caf`: a failed conversion
/// never costs the audio. 0600 files in a 0700 folder, like the spool.
struct KeptAudio: Sendable {
    /// What the JSON beside the audio says.
    struct Label: Equatable, Sendable {
        let transcript: URL
        let started: Date
        let model: MeetingModel
        /// When the sweep deletes it. nil keeps it until you do.
        let until: Date?
    }

    /// Audio on disk, and its label.
    struct Entry: Equatable, Sendable, Identifiable {
        let id: String
        let audio: URL
        let label: Label
    }

    static let folderName = "meeting-audio"

    let root: URL
    /// The wall its dates are read against. Injected so a test can move it.
    let now: @Sendable () -> Date
    private let compress: @Sendable (_ caf: URL, _ m4a: URL) throws -> Void

    init(
        root: URL = Self.defaultRoot,
        now: @escaping @Sendable () -> Date = { Date() },
        compress: @escaping @Sendable (_ caf: URL, _ m4a: URL) throws -> Void = KeptAudio.aac
    ) {
        self.root = root
        self.now = now
        self.compress = compress
    }

    static var defaultRoot: URL {
        AppIdentity.supportDirectory.appendingPathComponent(folderName, isDirectory: true)
    }

    private static let logger = Logger(subsystem: AppIdentity.loggingSubsystem, category: "kept-audio")

    // MARK: - keeping

    /// The spool's audio, kept under `label`, and then the spool is gone.
    ///
    /// The label goes in first, so no audio is ever in the folder with
    /// nothing to say whose it is or when it goes. Then the audio, made
    /// beside the spool, opened again and checked to hold the whole meeting,
    /// and moved in whole; a conversion that fails, or comes out short,
    /// moves the spool's own file in instead. Audio already moved in by a
    /// run that stopped before the spool went is taken as kept, when it
    /// holds the meeting, rather than moved in a second time. Only then is
    /// the spool let go, its audio first. False when the audio could not be
    /// moved in: the spool stays where it is, and with it the audio.
    @discardableResult
    func keep(_ handle: MeetingSpool.Handle, label: Label) -> Bool {
        let id = handle.folder.lastPathComponent
        do {
            try makeRoot()
            try write(label, to: labelURL(id))
        } catch {
            Self.logger.error("could not label kept audio: \(error.localizedDescription, privacy: .public)")
            return false
        }
        if let already = audioURL(id), Self.holdsAll(of: handle.audioURL, in: already) {
            letGoOfTheSpool(handle)
            return true
        }
        guard moveIn(handle, as: id) else { return false }
        letGoOfTheSpool(handle)
        return true
    }

    /// The spool's audio, compressed and checked, or as it was, in the
    /// folder under `id`, in place of anything there that did not hold the
    /// meeting. False when it could not be moved in.
    private func moveIn(_ handle: MeetingSpool.Handle, as id: String) -> Bool {
        let fm = FileManager.default
        let compressed = handle.folder.appendingPathComponent("audio.m4a")
        var audio: (from: URL, to: URL)
        do {
            try? fm.removeItem(at: compressed)
            try compress(handle.audioURL, compressed)
            audio = (compressed, root.appendingPathComponent("\(id).m4a"))
        } catch {
            Self.logger.error("could not compress a meeting's audio, keeping it as it was: \(error.localizedDescription, privacy: .public)")
            try? fm.removeItem(at: compressed)
            audio = (handle.audioURL, root.appendingPathComponent("\(id).caf"))
        }
        guard fm.fileExists(atPath: audio.from.path) else {
            Self.logger.error("a meeting's audio to keep is not where it was")
            return false
        }
        // what is there for this meeting did not hold it, or the check
        // above would have kept it: the original is still in the spool.
        for ext in Self.audioExtensions {
            try? fm.removeItem(at: root.appendingPathComponent("\(id).\(ext)"))
        }
        do {
            try fm.moveItem(at: audio.from, to: audio.to)
        } catch {
            Self.logger.error("could not move a meeting's audio in: \(error.localizedDescription, privacy: .public)")
            return false
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: audio.to.path)
        return true
    }

    /// The spool, once its audio is kept: its audio first, so no part of
    /// this leaves audio there without the manifest that says whose it is.
    /// Audio that will not go leaves the spool whole and marked, and the
    /// next launch, finding the audio already kept, lets it go then.
    private func letGoOfTheSpool(_ handle: MeetingSpool.Handle) {
        let fm = FileManager.default
        if fm.fileExists(atPath: handle.audioURL.path) {
            do {
                try fm.removeItem(at: handle.audioURL)
            } catch {
                Self.logger.error("a kept meeting's spool could not be deleted yet: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
        try? fm.removeItem(at: handle.folder)
    }

    /// How far a kept copy's length may fall from the spool's and still
    /// hold all of it: the encoder's last packet, and a little more.
    static let lengthSlack = Duration.milliseconds(100)

    /// Whether `kept` holds the whole of the spool's audio: both open, and
    /// as long as each other, give or take `lengthSlack`. False when either
    /// will not open.
    static func holdsAll(of spool: URL, in kept: URL) -> Bool {
        guard let original = try? AVAudioFile(forReading: spool),
              let copy = try? AVAudioFile(forReading: kept)
        else {
            return false
        }
        let originalSeconds = Double(original.length) / original.fileFormat.sampleRate
        let copySeconds = Double(copy.length) / copy.fileFormat.sampleRate
        return abs(originalSeconds - copySeconds) <= lengthSlack.totalSeconds
    }

    /// A spool whose meeting is written out, and whose audio was on its way
    /// here when the app stopped. Kept under the label it had been given;
    /// with none, until you delete it — not knowing how long it was meant to
    /// stay, it errs on keeping.
    @discardableResult
    func adopt(_ handle: MeetingSpool.Handle, manifest: MeetingSpool.Manifest) -> Bool {
        guard let transcript = manifest.transcript else { return false }
        let id = handle.folder.lastPathComponent
        let label = label(id) ?? Label(
            transcript: transcript, started: manifest.started, model: manifest.model,
            until: nil)
        return keep(handle, label: label)
    }

    // MARK: - what is kept

    /// Every meeting whose audio is here, oldest first.
    func all() -> [Entry] {
        labelled().compactMap { id, label in
            audioURL(id).map { Entry(id: id, audio: $0, label: label) }
        }
        .sorted { $0.label.started < $1.label.started }
    }

    /// The audio kept for `transcript`, if any is.
    func entry(for transcript: URL) -> Entry? {
        let path = transcript.standardizedFileURL.path
        return all().first { $0.label.transcript.standardizedFileURL.path == path }
    }

    // MARK: - changing the label

    /// The label after its transcript was made again: the model that wrote
    /// the transcript now, and the date it is kept until — the old date when
    /// the caller passes it back, none to keep it until you delete it. The
    /// audio is not touched.
    ///
    /// False when there is no audio here any more, or no label: it was
    /// deleted from history, or its day came, while the meeting was being
    /// read. A label written for audio that is gone would be a file nobody
    /// reads and nothing sweeps.
    @discardableResult
    func relabel(_ entry: Entry, model: MeetingModel, until: Date?) -> Bool {
        guard audioURL(entry.id) != nil, label(entry.id) != nil else { return false }
        do {
            try write(
                Label(
                    transcript: entry.label.transcript, started: entry.label.started,
                    model: model, until: until),
                to: labelURL(entry.id))
            return true
        } catch {
            Self.logger.error("could not relabel kept audio: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - letting go

    /// Gone now: the audio, then its label.
    func delete(_ entry: Entry) {
        delete(id: entry.id)
    }

    /// Whatever is kept for `transcript`, gone with it.
    func deleteAudio(of transcript: URL) {
        let path = transcript.standardizedFileURL.path
        for (id, label) in labelled() where label.transcript.standardizedFileURL.path == path {
            delete(id: id)
        }
    }

    /// Everything past its date, deleted without asking. Audio kept until
    /// you delete it has no date and is never touched. A look at one folder
    /// and the small files in it, so launch can afford it. Returns how many
    /// went.
    @discardableResult
    func sweep() -> Int {
        let now = now()
        var swept = 0
        for (id, label) in labelled() {
            guard let until = label.until, until <= now else { continue }
            delete(id: id)
            swept += 1
        }
        return swept
    }

    // MARK: -

    private func delete(id: String) {
        let fm = FileManager.default
        for ext in Self.audioExtensions {
            try? fm.removeItem(at: root.appendingPathComponent("\(id).\(ext)"))
        }
        try? fm.removeItem(at: labelURL(id))
    }

    /// Compressed first; the spool's own file when that is what was kept.
    private static let audioExtensions = ["m4a", "caf"]

    private func audioURL(_ id: String) -> URL? {
        Self.audioExtensions
            .map { root.appendingPathComponent("\(id).\($0)") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func labelURL(_ id: String) -> URL {
        root.appendingPathComponent("\(id).json")
    }

    /// Every label that reads, by id. One that does not is left alone: it
    /// may say a date this build cannot read, and guessing would be
    /// deleting someone's audio on a guess.
    private func labelled() -> [(id: String, label: Label)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.compactMap { name in
            let id = String(name.dropLast(".json".count))
            return label(id).map { (id, $0) }
        }
    }

    private func label(_ id: String) -> Label? {
        guard let data = try? Data(contentsOf: labelURL(id)) else { return nil }
        return try? Self.decoder.decode(Label.self, from: data)
    }

    private func makeRoot() throws {
        let private700: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: private700)
        try? FileManager.default.setAttributes(private700, ofItemAtPath: root.path)
    }

    private func write(_ label: Label, to url: URL) throws {
        try Self.encoder.encode(label).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

// MARK: - compressing

extension KeptAudio {
    /// Speech, not music: 32 kbps a channel keeps every word of a 16 kHz
    /// voice. An hour of both sides came to 25.4 mb, where the spool is 461,
    /// in about four seconds on an M4 (measured 2026-10-03).
    static let bitRate = 64_000

    /// The spool as AAC in an .m4a, at its own rate, the two sides still two
    /// channels — never mixed down, so each can be read again on its own.
    /// Read and written a block at a time: an hour of a meeting is never in
    /// memory at once.
    @Sendable
    static func aac(_ caf: URL, _ m4a: URL) throws {
        let input = try AVAudioFile(forReading: caf, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = input.processingFormat
        let output = try AVAudioFile(
            forWriting: m4a,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVEncoderBitRateKey: bitRate,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false)
        defer { output.close() }
        let block = AVAudioFrameCount(MeetingAudioChunk.sampleRate * 10)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: block) else {
            throw CocoaError(.featureUnsupported)
        }
        while input.framePosition < input.length {
            try input.read(into: buffer, frameCount: block)
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: m4a.path)
    }
}

// MARK: - the label on disk

/// Readable by whoever finds it: the transcript as a path, dates as ISO
/// 8601, and `until` written even when there is none, beside a plain
/// `untilDeleted`, so nobody has to know what a missing key means.
extension KeptAudio.Label: Codable {
    private enum CodingKeys: String, CodingKey {
        case transcript
        case started
        case model
        case until
        case untilDeleted
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            transcript: URL(fileURLWithPath: try container.decode(String.self, forKey: .transcript)),
            started: try container.decode(Date.self, forKey: .started),
            model: try container.decode(MeetingModel.self, forKey: .model),
            until: try container.decodeIfPresent(Date.self, forKey: .until))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(transcript.path, forKey: .transcript)
        try container.encode(started, forKey: .started)
        try container.encode(model, forKey: .model)
        try container.encode(until, forKey: .until)
        try container.encode(until == nil, forKey: .untilDeleted)
    }
}
