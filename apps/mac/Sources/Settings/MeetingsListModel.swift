import Combine
import Foundation

/// the meetings half of history: what is on disk, and the only place inside
/// the app a single one can be thrown away.
///
/// it owns no store. the file *is* the artifact (SPEC §11), so `load` hands
/// back whatever is in the folder right now and `delete` moves that file to
/// the trash — recoverable, because the app is not entitled to shred an hour
/// of someone else's words on one click.
@MainActor
final class MeetingsListModel: ObservableObject {
    @Published private(set) var items: [MeetingSummary] = []
    /// what the field above the list holds. the pile is filtered from it in
    /// memory — the folder is the index.
    @Published var query = ""
    /// nil while everything is fine. otherwise a sentence to show verbatim.
    @Published private(set) var failure: String?

    private let load: () -> [MeetingSummary]
    private let fileManager: FileManager

    init(
        fileManager: FileManager = .default,
        load: @escaping () -> [MeetingSummary]
    ) {
        self.fileManager = fileManager
        self.load = load
        reload()
    }

    /// edges trimmed, so a stray space does not empty the list.
    var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isSearching: Bool { !trimmedQuery.isEmpty }

    /// what the list shows. the app and the date are the only two things a
    /// row says that anyone remembers — `zoom` or `sep 12` narrows the pile.
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
    }

    func delete(_ meeting: MeetingSummary) {
        do {
            try fileManager.trashItem(
                at: meeting.fileURL,
                resultingItemURL: nil
            )
            failure = nil
        } catch {
            // SPEC §4: a delete that did not happen must not look like one
            // that did, so the row comes back when the folder is re-read.
            failure = "couldn’t delete that one — it’s still on disk."
        }
        reload()
    }
}
