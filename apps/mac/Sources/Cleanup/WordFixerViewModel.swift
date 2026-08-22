import Combine
import Foundation

/// "fix a word" — the surface ticket 011 chose, reachable from the menu bar for
/// the dictation you just did and (once the archive is wired) for any dictation
/// you kept.
///
/// It shows the transcript **as the engine heard it** and asks you to point at
/// what is wrong. That is the entire point: the current flow asks you to retype
/// a misspelling from memory, and an entry whose `wrong` side is off by one
/// character silently never fires. Pointing cannot be off by one character.
///
/// Saving is deliberate rather than instant. You see `heard "x" → y` before it
/// is written, because a dictionary that quietly learns a wrong mapping is the
/// same class of defect ADR 0020 removed from the cleaner.
@MainActor
final class WordFixerViewModel: ObservableObject {
    let correction: TranscriptCorrection

    @Published var first: Int?
    @Published var last: Int?
    @Published var replacement = ""
    @Published private(set) var saved: [Int: String] = [:]
    @Published private(set) var failure: String?

    private let store: DictionaryStore

    init(transcript: String, store: DictionaryStore) {
        correction = TranscriptCorrection(transcript: transcript)
        self.store = store
    }

    var selectedPhrase: String? {
        guard let first, let last else {
            return nil
        }
        return correction.phrase(from: first, through: last)
    }

    var canSave: Bool {
        selectedPhrase != nil
            && !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Click a word to select it; click one next to the selection to grow it,
    /// which is how "cypher d" becomes a single entry.
    func tap(_ index: Int) {
        guard saved[index] == nil else {
            return
        }
        if let first, let last {
            if index == first - 1 {
                self.first = index
                return
            }
            if index == last + 1 {
                self.last = index
                return
            }
        }
        first = index
        last = index
        replacement = ""
        failure = nil
    }

    func save() {
        guard let first, let last,
              let entry = correction.entry(
                from: first,
                through: last,
                right: replacement
              ) else {
            return
        }

        guard store.add(entry) else {
            // SPEC §4: a save that did not happen must not look like one that
            // did. The store already has the sentence; surface it.
            failure = store.lastFailure ?? "couldn’t save that one."
            return
        }

        for index in first...last {
            saved[index] = entry.right
        }
        self.first = nil
        self.last = nil
        replacement = ""
        failure = nil
    }
}
