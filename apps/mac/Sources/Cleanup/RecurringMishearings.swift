import AppKit
import Foundation

/// Words the engine keeps getting wrong, read out of what it already kept.
///
/// The dictionary's only door in was remembering: a place name the engine
/// missed five times stayed missed, because noticing the pattern was the
/// user's job and the app had all the data to name it. This suggests and
/// never learns — nothing is added, nothing is scanned but your own kept
/// text, nothing leaves the machine, and the cure is still the same explicit
/// save the fixer does (ADR 0020, 0024).
///
/// Single words only. A multi-word mishearing ("cypher d") is what the fix a
/// word window's chips are for — you click two words — and a spell-checked
/// pair would have to flag both halves, which it never does for a single
/// letter.
enum RecurringMishearings {
    struct Candidate: Equatable, Identifiable, Sendable {
        /// lowercased, exactly as the engine heard it.
        let heard: String
        /// how many separate dictations it turned up in.
        let count: Int
        /// a word you spelled out loud near one of them, if you did.
        let spelledOut: String?

        var id: String { heard }
    }

    /// thirty days back, two dictations minimum, eight rows maximum.
    ///
    /// Pure, and the spell checker arrives as a closure: what counts as a
    /// word is the one part of this a test cannot be allowed to inherit from
    /// whatever the running mac happens to have learned.
    static func scan(
        _ dictations: [Dictation],
        dictionary: [DictionaryEntry],
        dismissed: Set<String>,
        isSuspect: (String) -> Bool,
        now: Date,
        limit: Int = 8
    ) -> [Candidate] {
        let cutoff = now.addingTimeInterval(-lookback)
        let taught = Set(dictionary.map { DictionaryStore.matchKey($0.wrong) })

        var occurrences: [String: [Date]] = [:]
        var spellings: [(word: String, at: Date)] = []

        for dictation in dictations where dictation.startedAt >= cutoff {
            let heardWords = words(in: dictation.heard)

            // a line that is nothing but single letters is you spelling
            // something out loud, not seven words it got wrong.
            if let spelled = spelledOutWord(heardWords) {
                spellings.append((spelled, dictation.startedAt))
                continue
            }

            // per dictation, not per occurrence: saying one word twice in a
            // sentence is not a pattern.
            for word in Set(heardWords) where isWorthCounting(word) {
                occurrences[word, default: []].append(dictation.startedAt)
            }
        }

        let candidates: [Candidate] = occurrences.compactMap { word, dates in
            guard dates.count >= 2,
                  !taught.contains(word),
                  !dismissed.contains(word),
                  isSuspect(word) else {
                return nil
            }
            return Candidate(
                heard: word,
                count: dates.count,
                spelledOut: spelling(for: word, near: dates, in: spellings)
            )
        }

        let ranked = candidates.sorted { left, right in
            // a word you spelled out loud is one you already tried to fix by
            // hand, so it goes first.
            if (left.spelledOut != nil) != (right.spelledOut != nil) {
                return left.spelledOut != nil
            }
            if left.count != right.count {
                return left.count > right.count
            }
            let leftSeen = occurrences[left.heard]?.max() ?? .distantPast
            let rightSeen = occurrences[right.heard]?.max() ?? .distantPast
            if leftSeen != rightSeen {
                return leftSeen > rightSeen
            }
            return left.heard < right.heard
        }
        return Array(ranked.prefix(limit))
    }

    /// The spell checker, on the main actor because AppKit is. Half of any
    /// first list is not a mistake — "swiggy" and "paneer" are spelled how
    /// they are spelled — which is why "not a mistake" has to stick.
    @MainActor
    static func isSuspect(_ word: String) -> Bool {
        NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0).length > 0
    }

    /// "C O O N O O R" — three or more single letters and nothing else.
    static func spelledOutWord(_ words: [String]) -> String? {
        guard words.count >= 3,
              words.allSatisfy({ $0.count == 1 && $0.first?.isLetter == true })
        else {
            return nil
        }
        return words.joined()
    }

    /// c→k, ph→f, z→s, then the consonants: "coonoor" and "kunur" come out
    /// the same, which is how one can pre-fill the other's row.
    static func skeleton(_ word: String) -> String {
        var folded = word
            .lowercased()
            .replacingOccurrences(of: "ph", with: "f")
            .replacingOccurrences(of: "c", with: "k")
            .replacingOccurrences(of: "z", with: "s")
        folded.removeAll { !$0.isLetter || "aeiou".contains($0) }

        var collapsed = ""
        for letter in folded where collapsed.last != letter {
            collapsed.append(letter)
        }
        return collapsed
    }

    // MARK: - pieces

    private static let lookback: TimeInterval = 30 * 24 * 60 * 60
    private static let pairingWindow: TimeInterval = 30 * 60

    private static func words(in transcript: String) -> [String] {
        transcript
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// two letters or a digit in it and it is not a name the engine missed.
    private static func isWorthCounting(_ word: String) -> Bool {
        word.count >= 3 && !word.contains { $0.isNumber }
    }

    private static func spelling(
        for word: String,
        near dates: [Date],
        in spellings: [(word: String, at: Date)]
    ) -> String? {
        let target = skeleton(word)
        return spellings.first { spelled in
            target == skeleton(spelled.word)
                && dates.contains {
                    abs($0.timeIntervalSince(spelled.at)) <= pairingWindow
                }
        }?.word
    }
}
