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
    }

    /// three words a side, in one place. "cypher d" for "CypherD" is two,
    /// "jaz dot gg" is three; a fourth word changed in the same spot is a
    /// sentence being rewritten.
    static let mostWordsInASwap = 3

    /// every place the edit replaced our words with words that sound like
    /// them. insertions, deletions and rewrites are your writing and say
    /// nothing about what the engine heard.
    static func swaps(inserted: String, edited: String) -> [Swap] {
        regions(WordDiff.diff(inserted, edited)).compactMap { region in
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
            return Swap(from: from, to: to)
        }
    }

    // MARK: - pieces

    private struct Region {
        var removed: [String] = []
        var added: [String] = []
    }

    /// the diff's runs of change between unchanged words.
    private static func regions(_ tokens: [WordDiff.Token]) -> [Region] {
        var regions: [Region] = []
        var current = Region()
        for token in tokens {
            switch token.change {
            case .same:
                if !current.removed.isEmpty || !current.added.isEmpty {
                    regions.append(current)
                }
                current = Region()
            case .removed:
                current.removed.append(token.text)
            case .added:
                current.added.append(token.text)
            }
        }
        if !current.removed.isEmpty || !current.added.isEmpty {
            regions.append(current)
        }
        return regions
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
