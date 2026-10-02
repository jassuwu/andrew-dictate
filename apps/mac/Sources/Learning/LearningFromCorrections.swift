import AppKit

/// learning from your corrections, wired: a delivered dictation starts a
/// watch on the field it landed in, what you leave our words as goes to the
/// learner, and an entry it hands back goes into your dictionary, marked
/// learned.
@MainActor
final class LearningFromCorrections {
    /// an entry was just learned and saved: say so, once.
    var onLearned: ((DictionaryEntry) -> Void)?

    private let store: DictionaryStore
    /// your cleanup setting, read when an entry is tried rather than when
    /// the app started.
    private let fullCleanup: @MainActor () -> Bool
    private var learner = CorrectionLearner()
    private var watcher: AXSpanWatcher?
    /// the field being looked up, off the main thread, before its watch.
    private var finding: Task<Void, Never>?

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
        // which app is in front is AppKit's, and free to ask here. its
        // focused field is a round trip to that app: asked off the main
        // thread, and the watch starts when it answers. the next press
        // cancels a look still out.
        guard let application = NSWorkspace.shared.frontmostApplication?
            .processIdentifier else {
            return
        }
        finding = Task { @MainActor [weak self] in
            let reader = await Task.detached(priority: .userInitiated) {
                AXSpanReader.focused(in: application)
            }.value
            guard let self, !Task.isCancelled else {
                return
            }
            self.finding = nil
            guard let reader else {
                return
            }
            self.watch(reader, heard: heard, inserted: inserted)
        }
    }

    private func watch(
        _ reader: AXSpanReader,
        heard: String,
        inserted: String
    ) {
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
        finding?.cancel()
        finding = nil
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
