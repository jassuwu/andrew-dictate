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
        // the dictionary runs second, ahead of the parsers: it has to read
        // the engine's own words, because that is what "fix a word" points
        // at. an entry keyed on parsed text — "7" where the engine heard
        // "seven" — stops firing (this amends ADR 0019's order).
        transforms = [
            UnicodeWhitespaceNormalizer(),
            DictionarySubstitutions(entries: entries),
            SpokenPunctuation(),
            EmailParser(),
            URLParser(),
            NumberParser(),
            Capitalization(),
            PunctuationFinishing(),
        ]
    }

    func clean(_ transcript: String) -> String {
        transforms.reduce(transcript) { partial, transform in
            transform.apply(partial)
        }
    }

    /// the text the dictionary itself matches against: every transform up to
    /// `DictionarySubstitutions` and none after it. "fix a word" builds an
    /// entry's `wrong` side out of this string, so pointing at a word cannot
    /// produce an entry that never fires. the boundary is found in
    /// `transforms` rather than copied into a second list, because two lists
    /// drift. with `fullCleanup: false` it is the transcript untouched, which
    /// is already all the dictionary sees there.
    func asHeard(_ transcript: String) -> String {
        guard let boundary = transforms.firstIndex(where: {
            $0 is DictionarySubstitutions
        }) else {
            return transcript
        }
        return transforms[..<boundary].reduce(transcript) { partial, transform in
            transform.apply(partial)
        }
    }
}
