import Foundation

/// what a fix you made to text we inserted can teach the dictionary.
///
/// four rules, decided with Jass (ADR 0046): only our span is read (the
/// watcher's job, not this one's); only swaps — a few words the engine wrote
/// replaced by a few others; only sound-alikes; and only on the second
/// identical swap. one-off fixes teach nothing, and nothing here touches the
/// cleaner's rules (ADR 0020): what comes out is an ordinary dictionary
/// entry, yours like any other.
struct CorrectionLearner {
    /// one place where you replaced words we inserted with words that sound
    /// like them.
    struct Swap: Equatable, Sendable {
        let from: String
        let to: String
        /// what we inserted with this one swap made and nothing else: what
        /// an entry has to reproduce from the engine's words.
        let fixed: String
    }

    /// builds the cleaner a candidate entry is tried in: the app's own, with
    /// your cleanup setting, so the entry is checked against the pipeline
    /// that will run it.
    private let cleaner: ([DictionaryEntry]) -> DeterministicCleaner

    /// what the engine heard and what we inserted, for the dictation being
    /// watched. in memory only, and only while it is watched.
    private var watched: (heard: String, inserted: String)?

    /// how many dictations ended with each fix. in memory only: a restart
    /// forgets a one-off, so nothing taken from your text reaches the disk
    /// until it is an entry you can see.
    private var tally: [LearningKey: Int] = [:]

    /// the fixes the watched dictation stands at right now — its one vote.
    private var votes: Set<LearningKey> = []

    init(cleaner: @escaping ([DictionaryEntry]) -> DeterministicCleaner) {
        self.cleaner = cleaner
    }

    /// a delivered dictation, watched from now. whatever it ends as is one
    /// vote, cast for its last version.
    mutating func watch(heard: String, inserted: String) {
        watched = (heard, inserted)
        votes = []
    }

    /// the watched span as it reads now that you have paused. the answer is
    /// the entries to add — marked learned — and is usually nothing.
    mutating func settle(
        edited: String,
        dictionary: [DictionaryEntry],
        neverLearn: Set<LearningKey>
    ) -> [DictionaryEntry] {
        guard let watched else {
            return []
        }
        let fixes = Self.swaps(inserted: watched.inserted, edited: edited)
            .compactMap {
                Self.entry(
                    for: $0,
                    heard: watched.heard,
                    dictionary: dictionary,
                    cleaner: cleaner
                )
            }
            .filter { !neverLearn.contains(LearningKey($0)) }
        let now = Set(fixes.map(LearningKey.init))

        // a fix you have since changed or taken back is no longer this
        // dictation's vote.
        for withdrawn in votes.subtracting(now) {
            let left = (tally[withdrawn] ?? 1) - 1
            tally[withdrawn] = left > 0 ? left : nil
        }

        var learned: [DictionaryEntry] = []
        for fix in fixes {
            let key = LearningKey(fix)
            guard !votes.contains(key) else {
                continue
            }
            let count = (tally[key] ?? 0) + 1
            guard count >= 2 else {
                tally[key] = count
                continue
            }
            tally[key] = nil
            learned.append(
                DictionaryEntry(wrong: fix.wrong, right: fix.right, learned: true)
            )
        }
        votes = now
        return learned
    }

    /// three words a side, in one place. "cypher d" for "CypherD" is two,
    /// "jaz dot gg" is three; a fourth word changed in the same spot is a
    /// sentence being rewritten.
    static let mostWordsInASwap = 3

    /// every place the edit replaced our words with words that sound like
    /// them. insertions, deletions and rewrites are your writing and say
    /// nothing about what the engine heard.
    static func swaps(inserted: String, edited: String) -> [Swap] {
        let insertedWords = WordDiff.words(inserted)
        return regions(WordDiff.diff(inserted, edited)).compactMap { region in
            guard (1...mostWordsInASwap).contains(region.removed.count),
                  (1...mostWordsInASwap).contains(region.added.count) else {
                return nil
            }
            let from = trimmingEdges(region.removed.joined(separator: " "))
            let to = trimmingEdges(region.added.joined(separator: " "))
            guard !from.isEmpty, !to.isEmpty,
                  // case and punctuation are how you wanted it written, not
                  // what the engine heard.
                  spelling(from) != spelling(to),
                  !isGrammar(from, to),
                  !isInflection(from, to),
                  SoundAlike.soundsAlike(from, to) else {
                return nil
            }
            let fixed = insertedWords[..<region.start]
                + region.added
                + insertedWords[(region.start + region.removed.count)...]
            return Swap(
                from: from,
                to: to,
                fixed: fixed.joined(separator: " ")
            )
        }
    }

    /// the entry that makes this swap for you next time, keyed on the
    /// engine's own words — the dictionary reads those, before the parsers
    /// turn "jaz dot dev" into "jaz.dev". nil when no run of them does it.
    ///
    /// an entry is only offered if cleaning what was heard with it, beside
    /// the rules you already have, gives back the text you fixed: the
    /// guarantee fix-a-word makes (ADR 0024), that an entry built from a
    /// dictation fires on that dictation. a word one of your own entries
    /// wrote never matches, so the learner never writes over your rules.
    static func entry(
        for swap: Swap,
        heard: String,
        dictionary: [DictionaryEntry],
        cleaner: ([DictionaryEntry]) -> DeterministicCleaner
    ) -> DictionaryEntry? {
        let asHeard = TranscriptCorrection(
            transcript: cleaner(dictionary).asHeard(heard)
        )
        let taught = Set(dictionary.map { DictionaryStore.matchKey($0.wrong) })
        let wanted = spellingRuns(swap.fixed)
        let opening = spelling(swap.from).first

        // shortest first: "jaz" alone would leave "dot dev" behind, so the
        // run that works with the fewest words is the one the swap meant.
        for length in 1...mostHeardWordsInASwap {
            for first in asHeard.spans.indices {
                let last = first + length - 1
                guard last < asHeard.spans.count,
                      let wrong = asHeard.phrase(from: first, through: last)
                else {
                    break
                }
                // a parser can turn "seven" into "7", but never changes a
                // word's first letter: a cheap way past most of the runs.
                if let opening, opening.isLetter,
                   spelling(wrong).first != opening {
                    continue
                }
                guard !taught.contains(DictionaryStore.matchKey(wrong)) else {
                    continue
                }
                let candidate = DictionaryEntry(wrong: wrong, right: swap.to)
                let cleaned = cleaner(dictionary + [candidate]).clean(heard)
                if spellingRuns(cleaned) == wanted {
                    return candidate
                }
            }
        }
        return nil
    }

    // MARK: - pieces

    /// "jaz dot dev" is one written word and three heard ones, and an
    /// address can run longer: the most heard words one swap can stand for.
    private static let mostHeardWordsInASwap = 8

    private struct Region {
        /// where the removed words began, among the words we inserted.
        var start: Int
        var removed: [String] = []
        var added: [String] = []
    }

    /// the diff's runs of change between unchanged words.
    private static func regions(_ tokens: [WordDiff.Token]) -> [Region] {
        var regions: [Region] = []
        var current = Region(start: 0)
        var position = 0
        for token in tokens {
            switch token.change {
            case .same:
                if !current.removed.isEmpty || !current.added.isEmpty {
                    regions.append(current)
                }
                position += 1
                current = Region(start: position)
            case .removed:
                current.removed.append(token.text)
                position += 1
            case .added:
                current.added.append(token.text)
            }
        }
        if !current.removed.isEmpty || !current.added.isEmpty {
            regions.append(current)
        }
        return regions
    }

    /// the words as lowercased runs of letters and digits — what two texts
    /// share once case, spacing and punctuation are set aside.
    private static func spellingRuns(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// the stop, comma or bracket the cleaner put around a word is the
    /// sentence's, and an entry carrying it would never fire: the dictionary
    /// runs before punctuation is finished.
    private static let edgePunctuation = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: ".,;:!?…\"'“”‘’()[]{}"))

    private static func trimmingEdges(_ text: String) -> String {
        text.trimmingCharacters(in: edgePunctuation)
    }

    /// letters and digits, lowercased: what is left when case and
    /// punctuation are taken away.
    private static func spelling(_ text: String) -> String {
        String(
            text.lowercased().unicodeScalars
                .filter(CharacterSet.alphanumerics.contains)
                .map(Character.init)
        )
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" })
            .map { $0.replacingOccurrences(of: "’", with: "'") }
    }

    /// "there" for "their" sounds alike, and every word of it is one of the
    /// most common in english. that is grammar or a change of mind, and a
    /// rule that rewrote every "there" would wreck more than it fixed.
    private static func isGrammar(_ from: String, _ to: String) -> Bool {
        (words(from) + words(to)).allSatisfy(commonWords.contains)
    }

    /// "large" to "larger", "ship" to "shipped": the same word bent another
    /// way is you changing the sentence.
    private static func isInflection(_ from: String, _ to: String) -> Bool {
        let a = spelling(from)
        let b = spelling(to)
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        guard long.hasPrefix(short) else {
            return false
        }
        var ending = String(long.dropFirst(short.count))
        // "ship" → "shipped" doubles the last letter before the ending.
        if let last = short.last, ending.first == last {
            ending.removeFirst()
        }
        return inflections.contains(ending)
    }

    private static let inflections: Set<String> = [
        "s", "es", "d", "ed", "ing", "r", "er", "st", "est", "ly", "n", "en",
    ]

    /// the words english leans on most, and the homophones among them.
    private static let commonWords: Set<String> = [
        "a", "about", "accept", "affect", "after", "again", "all", "also",
        "am", "an", "and", "any", "are", "as", "at", "ate", "be", "bee",
        "been", "before", "being", "brake", "break", "but", "buy", "by",
        "bye", "can", "could", "day", "did", "do", "does", "done", "down",
        "effect", "eight", "even", "except", "few", "for", "four", "from",
        "get", "go", "good", "had", "has", "have", "he", "hear", "her",
        "here", "him", "his", "hole", "hour", "how", "i", "if", "in", "into",
        "is", "it", "it's", "its", "just", "knew", "know", "less", "like",
        "loose", "lose", "made", "make", "many", "me", "meat", "meet", "might",
        "more", "most", "much", "must", "my", "new", "no", "not", "now", "of",
        "off", "on", "one", "only", "or", "other", "our", "out", "over",
        "passed", "past", "peace", "piece", "plain", "plane", "right", "said",
        "same", "sea", "see", "she", "should", "so", "some", "son", "sun",
        "than", "that", "the", "their", "them", "then", "there", "these",
        "they", "they're", "this", "those", "though", "through", "threw",
        "to", "too", "two", "up", "us", "very", "was", "way", "we", "we're",
        "weak", "wear", "weather", "week", "well", "were", "what", "when",
        "where", "whether", "which", "while", "who", "who's", "whole", "whose",
        "why", "will", "witch", "with", "won", "wood", "would", "write",
        "yes", "you", "you're", "your",
    ]
}
