import Foundation

/// learning from your fixes, wired: a delivered dictation starts a watch on
/// the field it landed in, what you leave our words as goes to the learner,
/// and an entry it hands back goes into your dictionary, marked learned.
@MainActor
final class FixLearning {
    /// an entry was just learned and saved: say so, once.
    var onLearned: ((DictionaryEntry) -> Void)?

    private let store: DictionaryStore
    /// your cleanup setting, read when an entry is tried rather than when
    /// the app started.
    private let fullCleanup: @MainActor () -> Bool
    private var learner = CorrectionLearner()
    private var watcher: AXSpanWatcher?

    init(
        store: DictionaryStore,
        fullCleanup: @escaping @MainActor () -> Bool
    ) {
        self.store = store
        self.fullCleanup = fullCleanup
    }

    /// a dictation was pasted with focus where we left it. the field it
    /// went into is the one focused now; a password field, one of our own
    /// windows, or a field AX can't read is never watched.
    func delivered(heard: String, inserted: String) {
        stopWatching()
        guard let reader = AXSpanReader.focused() else {
            return
        }
        learner.watch(heard: heard, inserted: inserted)
        let watcher = AXSpanWatcher(
            reader: reader,
            inserted: inserted,
            onSettled: { [weak self] edited in
                self?.settled(edited)
            },
            onEnded: { [weak self] in
                self?.watcher = nil
            }
        )
        self.watcher = watcher
        watcher.start()
    }

    /// the next dictation starts: the last one's watch is over.
    func stopWatching() {
        watcher?.stop()
        watcher = nil
    }

    private func settled(_ edited: String) {
        let fullCleanup = fullCleanup()
        let learned = learner.settle(
            edited: edited,
            dictionary: store.entries,
            neverLearn: store.neverLearn,
            cleaner: { DeterministicCleaner(entries: $0, fullCleanup: fullCleanup) }
        )
        for entry in learned where store.add(entry) {
            onLearned?(entry)
        }
    }
}
