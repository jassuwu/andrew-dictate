import Combine
import Foundation

/// The list of kept dictations, and the only place a single one can be deleted.
///
/// ADR 0026 shipped `delete all` and said per-item deletion had to wait for
/// something to delete *from*. This is that something, kept deliberately small:
/// it lists and it deletes. What the accumulation surface eventually becomes —
/// searchable, a stat line, a home for meeting recordings — is still open, and
/// this does not try to answer it.
@MainActor
final class ArchiveBrowserViewModel: ObservableObject {
    @Published private(set) var items: [Dictation] = []
    /// nil while everything is fine. Otherwise a sentence to show verbatim.
    @Published private(set) var failure: String?

    private let archive: DictationArchive

    init(archive: DictationArchive = DictationArchive()) {
        self.archive = archive
        reload()
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
