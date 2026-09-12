import Combine
import Foundation

/// The list of kept dictations, and the only place a single one can be deleted.
///
/// ADR 0026 shipped `delete all` and said per-item deletion had to wait for
/// something to delete *from*. This is that something, kept deliberately small:
/// it lists, it filters and it deletes. What the accumulation surface
/// eventually becomes — a stat line, a home for meeting recordings — is still
/// open, and this does not try to answer it.
@MainActor
final class ArchiveBrowserViewModel: ObservableObject {
    @Published private(set) var items: [Dictation] = []
    /// What the field above the list holds. The list is filtered from it in
    /// memory: an archive the user chose to keep needs no index to search.
    @Published var query = ""
    /// nil while everything is fine. Otherwise a sentence to show verbatim.
    @Published private(set) var failure: String?

    private let archive: DictationArchive

    init(archive: DictationArchive = DictationArchive()) {
        self.archive = archive
        reload()
    }

    /// Where the file is. A pane that can only say "couldn’t read what’s
    /// kept." has to be able to point at the thing it could not read — and
    /// read it from the archive, so a dev build names its own folder.
    var archiveURL: URL { archive.fileURL }

    var archivePath: String {
        (archive.fileURL.path(percentEncoded: false) as NSString)
            .abbreviatingWithTildeInPath
    }

    /// Edges trimmed, so a stray space does not empty the list.
    var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isSearching: Bool { !trimmedQuery.isEmpty }

    /// What the list shows. Both sides are matched: the misspelling you are
    /// hunting for often exists only in the raw text.
    /// `localizedStandardContains` is how Finder compares — case- and
    /// diacritic-insensitive — and a substring scan over rows already in
    /// memory is too fast to be worth debouncing.
    var filtered: [Dictation] {
        guard isSearching else { return items }
        let needle = trimmedQuery
        return items.filter {
            $0.inserted.localizedStandardContains(needle)
                || $0.heard.localizedStandardContains(needle)
        }
    }

    func reload() {
        do {
            // Newest first: the thing you just said should not be at the
            // bottom of a list that grows for years.
            items = try archive.all().reversed()
            failure = nil
        } catch {
            failure = "couldn’t read what’s kept."
        }
    }

    func delete(_ dictation: Dictation) {
        do {
            try archive.delete(id: dictation.id)
            items.removeAll { $0.id == dictation.id }
            failure = nil
        } catch {
            // SPEC §4: a delete that did not happen must not look like one
            // that did, so the row stays where it is.
            failure = "couldn’t delete that one — it’s still on disk."
        }
    }
}
