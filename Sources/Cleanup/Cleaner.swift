import Foundation

protocol Cleaner {
    func clean(_ transcript: String) -> String
}

struct DeterministicCleaner: Cleaner {
    private let transforms: [any TranscriptTransform]

    init(entries: [DictionaryEntry] = []) {
        // ADR 0019 makes this order a behavior contract.
        transforms = [
            UnicodeWhitespaceNormalizer(),
            SpokenPunctuation(),
            EmailParser(),
            URLParser(),
            NumberParser(),
            SelfCorrections(),
            RepetitionCollapse(),
            FillerRemoval(),
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
