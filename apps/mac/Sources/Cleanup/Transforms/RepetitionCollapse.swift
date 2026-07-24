import Foundation

struct RepetitionCollapse: TranscriptTransform {
    private struct Word {
        let value: String
        let range: Range<String.Index>
    }

    private let wordExpression = try! NSRegularExpression(
        pattern: "[\\p{L}\\p{N}_]+(?:['’-][\\p{L}\\p{N}_]+)*"
    )
    private let maximumPhraseWords = 6

    static func containsImmediateDuplicate(in transcript: String) -> Bool {
        RepetitionCollapse().duplicateRemovalRange(in: transcript) != nil
    }

    func apply(_ transcript: String) -> String {
        var result = transcript
        while let range = duplicateRemovalRange(in: result) {
            result.removeSubrange(range)
        }
        return result
    }

    private func duplicateRemovalRange(
        in transcript: String
    ) -> Range<String.Index>? {
        let words = wordExpression.matches(
            in: transcript,
            range: transcript.fullNSRange
        ).compactMap { match -> Word? in
            guard let range = Range(match.range, in: transcript) else {
                return nil
            }
            return Word(
                value: transcript[range].lowercased(),
                range: range
            )
        }
        guard words.count >= 2 else {
            return nil
        }

        for start in words.indices {
            let remaining = words.count - start
            let maximumLength = min(
                maximumPhraseWords,
                remaining / 2
            )
            guard maximumLength > 0 else {
                continue
            }
            for length in stride(
                from: maximumLength,
                through: 1,
                by: -1
            ) {
                let first = words[start..<(start + length)]
                let second = words[
                    (start + length)..<(start + 2 * length)
                ]
                guard zip(first, second).allSatisfy({
                    $0.0.value == $0.1.value
                }),
                separatorsAreWhitespace(
                    words: words,
                    from: start,
                    through: start + 2 * length - 1,
                    in: transcript
                ) else {
                    continue
                }

                let removalStart =
                    words[start + length - 1].range.upperBound
                let removalEnd =
                    words[start + 2 * length - 1].range.upperBound
                return removalStart..<removalEnd
            }
        }
        return nil
    }

    private func separatorsAreWhitespace(
        words: [Word],
        from start: Int,
        through end: Int,
        in transcript: String
    ) -> Bool {
        guard end > start else {
            return true
        }
        for index in start..<end {
            let separatorStart = words[index].range.upperBound
            let separatorEnd = words[index + 1].range.lowerBound
            let separatorRange = separatorStart..<separatorEnd
            let separator = transcript[separatorRange]
            guard !separator.isEmpty,
                  separator.allSatisfy(\.isWhitespace) else {
                return false
            }
        }
        return true
    }
}
