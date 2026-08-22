import Foundation

/// Evidence that a transcript might be messy, for the messy gate to weigh.
///
/// These two used to be static members on the transforms that acted on them.
/// ADR 0020 removed those transforms, and moving the detectors here keeps the
/// distinction the ADR turns on: **detecting** that speech may contain a
/// stumble is not the same act as **rewriting** it. The cleaner no longer does
/// the second. The gate still wants the first, so it can hand the transcript
/// to a model that has the context to judge.
enum MessyGateSignals {
    private static let correctionMarker = CleanupRegex.compile(
        #"""
        (?<![\p{L}\p{N}_])
        (?:no\s+wait|i\s+mean|make\s+that|scratch\s+that|actually|sorry|rather)
        (?![\p{L}\p{N}_])
        """#,
        options: [.caseInsensitive, .allowCommentsAndWhitespace]
    )

    private static let word = CleanupRegex.compile(
        "[\\p{L}\\p{N}_]+(?:['’-][\\p{L}\\p{N}_]+)*"
    )

    private static let maximumPhraseWords = 6

    /// Every one of these markers is also an ordinary English word, which is
    /// why acting on them was a defect (ADR 0019 amendment). As a *signal*
    /// the ambiguity is harmless: a false positive costs one model invocation,
    /// not a sentence.
    static func containsCorrectionMarker(in transcript: String) -> Bool {
        // without the pattern nothing can be flagged, and an unflagged
        // transcript is left exactly as dictated.
        guard let correctionMarker else {
            return false
        }
        return correctionMarker.firstMatch(
            in: transcript,
            range: transcript.fullNSRange
        ) != nil
    }

    /// An immediately repeated word or phrase — "we should we should ship".
    /// Only whitespace may separate the two halves, so "very, very" is
    /// emphasis rather than a stumble and does not fire.
    static func containsImmediateDuplicate(in transcript: String) -> Bool {
        guard let word else {
            return false
        }

        let words = word.matches(
            in: transcript,
            range: transcript.fullNSRange
        ).compactMap { match -> (value: String, range: Range<String.Index>)? in
            guard let range = Range(match.range, in: transcript) else {
                return nil
            }
            return (transcript[range].lowercased(), range)
        }
        guard words.count >= 2 else {
            return false
        }

        for start in words.indices {
            let maximumLength = min(
                maximumPhraseWords,
                (words.count - start) / 2
            )
            guard maximumLength > 0 else {
                continue
            }

            for length in stride(from: maximumLength, through: 1, by: -1) {
                let first = words[start..<(start + length)]
                let second = words[(start + length)..<(start + 2 * length)]
                guard zip(first, second).allSatisfy({
                    $0.0.value == $0.1.value
                }) else {
                    continue
                }
                if separatorsAreWhitespace(
                    words: words,
                    from: start,
                    through: start + 2 * length - 1,
                    in: transcript
                ) {
                    return true
                }
            }
        }
        return false
    }

    private static func separatorsAreWhitespace(
        words: [(value: String, range: Range<String.Index>)],
        from start: Int,
        through end: Int,
        in transcript: String
    ) -> Bool {
        guard end > start else {
            return true
        }
        for index in start..<end {
            let gap = words[index].range.upperBound
                ..< words[index + 1].range.lowerBound
            let separator = transcript[gap]
            guard !separator.isEmpty,
                  separator.allSatisfy(\.isWhitespace) else {
                return false
            }
        }
        return true
    }
}
