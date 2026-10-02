import Combine
import Foundation

/// the meetings half of history: what is on disk, and the only place inside
/// the app a single one can be thrown away.
///
/// it owns no store. the file *is* the artifact (SPEC §11), so `load` hands
/// back whatever is in the folder right now and `delete` moves that file to
/// the trash — recoverable, because the app is not entitled to shred an hour
/// of someone else's words on one click.
///
/// a meeting's audio, while it is kept (ADR 0048), is the other thing a row
/// can let go of: `delete audio now`, or the transcript going with it.
@MainActor
final class MeetingsListModel: ObservableObject {
    @Published private(set) var items: [MeetingSummary] = []
    /// what the field above the list holds. the pile is filtered from it in
    /// memory — the folder is the index.
    @Published var query = ""
    /// nil while everything is fine. otherwise a sentence to show verbatim.
    @Published private(set) var failure: String?
    /// recordings the app tried twice to write out and could not, or could
    /// not read at all. it keeps them rather than deleting them, so
    /// something has to say they exist — and offer another try.
    @Published private(set) var setAsideCount = 0
    /// the audio kept for each meeting that still has some, by the path of
    /// its transcript.
    @Published private(set) var audio: [String: KeptAudio.Entry] = [:]

    /// a retry of those is running. it can take a quarter of an hour a
    /// recording, so the line says so instead of offering the button again.
    @Published private(set) var tryingAgain = false

    private let load: () -> [MeetingSummary]
    private let countSetAside: () -> Int
    private let retrySetAside: (@MainActor () async -> Void)?
    private let keptAudio: KeptAudio?
    private let now: () -> Date
    private let locale: Locale
    private let timeZone: TimeZone
    private let trash: (URL) throws -> Void

    /// where the ones it could not read are kept, for the row's button.
    let setAsideFolder: URL?

    init(
        fileManager: FileManager = .default,
        setAsideFolder: URL? = nil,
        countSetAside: @escaping () -> Int = { 0 },
        tryAgain: (@MainActor () async -> Void)? = nil,
        keptAudio: KeptAudio? = nil,
        now: @escaping () -> Date = { Date() },
        locale: Locale = .current,
        timeZone: TimeZone = .current,
        trash: ((URL) throws -> Void)? = nil,
        load: @escaping () -> [MeetingSummary]
    ) {
        self.setAsideFolder = setAsideFolder
        self.countSetAside = countSetAside
        self.retrySetAside = tryAgain
        self.keptAudio = keptAudio
        self.now = now
        self.locale = locale
        self.timeZone = timeZone
        self.trash = trash ?? { try fileManager.trashItem(at: $0, resultingItemURL: nil) }
        self.load = load
        reload()
    }

    /// edges trimmed, so a stray space does not empty the list.
    var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isSearching: Bool { !trimmedQuery.isEmpty }

    /// what the list shows. the app and the date are the only two things a
    /// row says that anyone remembers, so `zoom` or the date exactly as the
    /// row writes it — whatever locale that is — narrows the pile.
    var filtered: [MeetingSummary] {
        guard isSearching else { return items }
        let needle = trimmedQuery
        return items.filter {
            $0.app.localizedStandardContains(needle)
                || $0.started
                    .formatted(date: .abbreviated, time: .shortened)
                    .localizedStandardContains(needle)
        }
    }

    func reload() {
        items = load()
        setAsideCount = countSetAside()
        audio = Dictionary(
            (keptAudio?.all() ?? []).map { (Self.key($0.label.transcript), $0) },
            uniquingKeysWith: { first, _ in first })
    }

    // MARK: - recordings that could not be transcribed

    /// whether this pane was given a way to try them again.
    var canTryAgain: Bool { retrySetAside != nil }

    /// the set-aside recordings, tried once more, and then the pane reads
    /// the count and the meetings again: what worked is a meeting now, and
    /// what did not is still counted.
    func tryAgain() async {
        guard let retrySetAside, !tryingAgain else { return }
        tryingAgain = true
        await retrySetAside()
        tryingAgain = false
        reload()
    }

    func delete(_ meeting: MeetingSummary) {
        do {
            try trash(meeting.fileURL)
            failure = nil
            // nothing to check it against any more, and no reason to keep
            // someone's voice past the words they said.
            keptAudio?.deleteAudio(of: meeting.fileURL)
        } catch {
            // SPEC §4: a delete that did not happen must not look like one
            // that did, so the row comes back when the folder is re-read.
            failure = "couldn’t delete that one — it’s still on disk."
        }
        reload()
    }

    // MARK: - kept audio

    /// what the row says about the meeting's audio, or nil when it has
    /// none: `audio until fri 14:02`, or `audio kept` for a thin meeting's,
    /// which waits for you to delete it.
    func audioNote(for meeting: MeetingSummary) -> String? {
        guard let entry = audio[Self.key(meeting.fileURL)] else { return nil }
        guard let until = entry.label.until else { return "audio kept" }
        return "audio until \(when(until))"
    }

    /// `delete audio now`: gone, the transcript left as it is.
    func deleteAudio(of meeting: MeetingSummary) {
        keptAudio?.deleteAudio(of: meeting.fileURL)
        reload()
    }

    /// the day and the time, in the row's own locale and side by side: a
    /// locale that joins them with a word would make the note a sentence.
    /// within the week a weekday is enough; further out it would read as
    /// this week's, so the date.
    private func when(_ date: Date) -> String {
        let withinTheWeek = date.timeIntervalSince(now()) < 6 * 86_400
        let day = format(date, withinTheWeek ? "EEE" : "dMMM")
        return "\(day) \(format(date, "jmm"))".lowercased()
    }

    private func format(_ date: Date, _ template: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    private static func key(_ transcript: URL) -> String {
        transcript.standardizedFileURL.path
    }
}
