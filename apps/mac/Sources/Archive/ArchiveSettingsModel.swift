import Combine
import Foundation

/// What the settings pane knows about the archive: how much is in it, and how
/// to empty it.
///
/// ADR 0022 made keeping conditional on deletion actually working. This is that
/// condition — the count is read from disk rather than tracked, so the number
/// shown is the number of things that exist.
@MainActor
final class ArchiveSettingsModel: ObservableObject {
    @Published private(set) var count = 0
    /// nil while everything is fine. Otherwise a sentence to show verbatim.
    @Published private(set) var failure: String?

    private let archive: DictationArchive

    init(archive: DictationArchive = DictationArchive()) {
        self.archive = archive
        refresh()
    }

    func refresh() {
        do {
            count = try archive.all().count
            failure = nil
        } catch {
            // An unreadable archive is not an empty one, and showing zero
            // would be a lie with a delete button next to it.
            count = 0
            failure = "couldn’t read what’s kept."
        }
    }

    func deleteEverything() {
        do {
            try archive.deleteAll()
            count = 0
            failure = nil
        } catch {
            failure = "couldn’t delete those — they’re still on disk."
            refreshCountOnly()
        }
    }

    private func refreshCountOnly() {
        count = (try? archive.all().count) ?? count
    }
}
