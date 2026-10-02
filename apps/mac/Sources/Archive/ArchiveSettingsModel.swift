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
    /// the press log fills even with history off, so an empty archive is
    /// not the same as nothing to delete.
    @Published private(set) var hasPressLog = false

    var hasAnythingToDelete: Bool {
        count > 0 || hasPressLog
    }

    private let archive: DictationArchive
    /// no words in it, but it says when you were at your mac, so it goes
    /// with the history rather than outliving it.
    private let pressLog: PressLogStore

    init(
        archive: DictationArchive = DictationArchive(),
        pressLog: PressLogStore = PressLogStore()
    ) {
        self.archive = archive
        self.pressLog = pressLog
        refresh()
    }

    func refresh() {
        hasPressLog = !((try? pressLog.recent(1)) ?? []).isEmpty
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

    /// the sentence on the dialog that guards `delete all`. deletion unlinks
    /// the file, so how much and how far back is the whole warning — and the
    /// date is lowercased because every other string in this app is.
    nonisolated static func wipeWarning(
        count: Int,
        oldest: Date?,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        guard count > 0, let oldest else {
            return "this can’t be undone."
        }

        let day = oldest
            .formatted(.dateTime.day().month(.abbreviated).locale(locale))
            .lowercased()

        if count == 1 {
            return "1 dictation, from \(day). this can’t be undone."
        }
        return "\(count) dictations, back to \(day). this can’t be undone."
    }

    func deleteEverything() {
        do {
            try archive.deleteAll()
            try pressLog.deleteAll()
            count = 0
            hasPressLog = false
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
