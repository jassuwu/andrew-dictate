import Foundation

protocol Cleaner {
    func clean(_ transcript: String) -> String
}

struct DeterministicCleaner: Cleaner {
    private let transforms: [any TranscriptTransform]

    /// `fullCleanup: false` is the user's "cleanup off": the words come
    /// through as parakeet heard them, and only the dictionary still runs —
    /// a word you taught it is yours regardless (ADR 0038).
    init(entries: [DictionaryEntry] = [], fullCleanup: Bool = true) {
        guard fullCleanup else {
            transforms = [DictionarySubstitutions(entries: entries)]
            return
        }
        // ADR 0019 makes this order a behavior contract. ADR 0020 removed
        // the three stages that guessed at intent — self-corrections,
        // repetition collapse, filler removal — leaving only stages that
        // render what you said into how it is written.
        transforms = [
            UnicodeWhitespaceNormalizer(),
            SpokenPunctuation(),
            EmailParser(),
            URLParser(),
            NumberParser(),
            DictionarySubstitutions(entries: entries),
            Capitalization(),
            PunctuationFinishing(),
        ]
    }

    func clean(_ transcript: String) -> String {
        transforms.reduce(transcript) { partial, transform in
            transform.apply(partial)
        }
    }
}
