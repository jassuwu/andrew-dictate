import Foundation

/// whether two spellings are one sound: what separates a mishearing you
/// fixed from a word you changed your mind about.
///
/// a cut-down metaphone over the whole phrase, then edit distance between
/// the keys. the phrase and not each word, because a mishearing does not
/// keep the word breaks — "Android dictates" is two words and so is "Andrew
/// Tate's", but not the same two. vowels after the first letter are dropped:
/// the engine gets vowels wrong far more often than consonants, and a vowel
/// is where accents differ most.
enum SoundAlike {
    /// "Android dictates" against "Andrew Tate's" is 0.75; "big" against
    /// "large" is 0.
    static let threshold = 0.7

    static func soundsAlike(_ a: String, _ b: String) -> Bool {
        let first = key(a)
        let second = key(b)
        guard !first.isEmpty, !second.isEmpty else {
            return false
        }
        return similarity(first, second) >= threshold
    }

    /// one minus the edit distance over the longer key: 1 is the same
    /// sound, 0 is nothing in common.
    static func similarity(_ a: String, _ b: String) -> Double {
        let longer = max(a.count, b.count)
        guard longer > 0 else {
            return 1
        }
        return 1 - Double(distance(Array(a), Array(b))) / Double(longer)
    }

    /// letters and digits only, so case, spaces and punctuation never count
    /// as sound: "jaz.gg" keys as "jazgg" would.
    static func key(_ text: String) -> String {
        var letters = Array(
            text
                .folding(options: [.diacriticInsensitive], locale: nil)
                .lowercased()
                .filter { ("a"..."z").contains($0) || $0.isASCII && $0.isNumber }
        )
        letters = Self.trimmingSilentStart(letters)

        var key = ""
        for index in letters.indices {
            let letter = letters[index]
            let previous = index > 0 ? letters[index - 1] : nil
            // a doubled letter is one sound.
            if letter == previous {
                continue
            }
            let next = index + 1 < letters.count ? letters[index + 1] : nil
            let afterNext = index + 2 < letters.count ? letters[index + 2] : nil
            key += code(
                letter,
                at: index,
                previous: previous,
                next: next,
                afterNext: afterNext
            )
        }

        var collapsed = ""
        for code in key where collapsed.last != code {
            collapsed.append(code)
        }
        return collapsed
    }

    // MARK: - pieces

    private static let vowels: Set<Character> = ["a", "e", "i", "o", "u"]
    private static let softeners: Set<Character> = ["e", "i", "y"]

    /// "knight", "gnome", "pneumatic", "write": the first letter is not
    /// said. an "x" up front is said as "s", and "wh" as "w".
    private static func trimmingSilentStart(
        _ letters: [Character]
    ) -> [Character] {
        guard letters.count > 1 else {
            return letters
        }
        let start = String(letters.prefix(2))
        if ["kn", "gn", "pn", "wr", "ae"].contains(start) {
            return Array(letters.dropFirst())
        }
        if letters[0] == "x" {
            return ["s"] + letters.dropFirst()
        }
        if start == "wh" {
            return ["w"] + letters.dropFirst(2)
        }
        return letters
    }

    private static func code(
        _ letter: Character,
        at index: Int,
        previous: Character?,
        next: Character?,
        afterNext: Character?
    ) -> String {
        let nextIsVowel = next.map { vowels.contains($0) } ?? false
        let softened = next.map { softeners.contains($0) } ?? false

        switch letter {
        case "a", "e", "i", "o", "u":
            // only a word's opening vowel is kept, and as one sound.
            return index == 0 ? "A" : ""
        case "b":
            // "dumb", "climb".
            return previous == "m" && next == nil ? "" : "B"
        case "c":
            if previous == "s", softened {
                return ""
            }
            if next == "h" || (next == "i" && afterNext == "a") {
                return "X"
            }
            return softened ? "S" : "K"
        case "d":
            return next == "g" && afterNext.map { softeners.contains($0) } == true
                ? "J"
                : "T"
        case "g":
            if next == "h", afterNext.map({ !vowels.contains($0) }) ?? true {
                return ""
            }
            if next == "n", afterNext == nil {
                return ""
            }
            return softened ? "J" : "K"
        case "h":
            if let previous, "csptg".contains(previous) {
                return ""
            }
            return nextIsVowel ? "H" : ""
        case "k":
            return previous == "c" ? "" : "K"
        case "p":
            return next == "h" ? "F" : "P"
        case "q":
            return "K"
        case "s":
            if next == "h" {
                return "X"
            }
            if next == "i", afterNext == "o" || afterNext == "a" {
                return "X"
            }
            return "S"
        case "t":
            if next == "i", afterNext == "o" || afterNext == "a" {
                return "X"
            }
            if next == "h" {
                return "0"
            }
            if next == "c", afterNext == "h" {
                return ""
            }
            return "T"
        case "v":
            return "F"
        case "w", "y":
            // a consonant only where a vowel follows: "will", but not "new".
            return nextIsVowel ? String(letter).uppercased() : ""
        case "x":
            return "KS"
        case "z":
            return "S"
        default:
            // the rest are themselves: f j l m n r, and digits.
            return String(letter).uppercased()
        }
    }

    private static func distance(_ a: [Character], _ b: [Character]) -> Int {
        guard !a.isEmpty else {
            return b.count
        }
        guard !b.isEmpty else {
            return a.count
        }
        var previousRow = Array(0...b.count)
        for i in 1...a.count {
            var row = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                row[j] = min(
                    previousRow[j] + 1,
                    row[j - 1] + 1,
                    previousRow[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                )
            }
            previousRow = row
        }
        return previousRow[b.count]
    }
}
