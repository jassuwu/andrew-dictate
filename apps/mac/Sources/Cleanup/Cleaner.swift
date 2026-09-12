import Foundation

protocol Cleaner {
    func clean(_ transcript: String, continuingASentence: Bool) -> String
}

struct DeterministicCleaner: Cleaner {
    private let entries: [DictionaryEntry]
    private let fullCleanup: Bool

    /// `fullCleanup: false` is the user's "cleanup off": the words come
    /// through as parakeet heard them, and only the dictionary still runs —
    /// a word you taught it is yours regardless (ADR 0038).
    init(entries: [DictionaryEntry] = [], fullCleanup: Bool = true) {
        self.entries = entries
        self.fullCleanup = fullCleanup
    }

    /// `continuingASentence` is the one thing the pipeline knows about the
    /// place the words are going: the caret sits mid-sentence, so the first
    /// word keeps the case it was said in. nowhere to read it (the fix-a-word
    /// playground, a field that refused the question) means false, which is
    /// what the cleaner has always done.
    func clean(
        _ transcript: String,
        continuingASentence: Bool = false
    ) -> String {
        transforms(continuingASentence: continuingASentence)
            .reduce(transcript) { partial, transform in
                transform.apply(partial)
            }
    }

    private func transforms(
        continuingASentence: Bool
    ) -> [any TranscriptTransform] {
        guard fullCleanup else {
            return [DictionarySubstitutions(entries: entries)]
        }
        // ADR 0019 makes this order a behavior contract. ADR 0020 removed
        // the three stages that guessed at intent — self-corrections,
        // repetition collapse, filler removal — leaving only stages that
        // render what you said into how it is written.
        return [
            UnicodeWhitespaceNormalizer(),
            SpokenPunctuation(),
            EmailParser(),
            URLParser(),
            NumberParser(),
            DictionarySubstitutions(entries: entries),
            Capitalization(continuingASentence: continuingASentence),
            PunctuationFinishing(),
        ]
    }
}
