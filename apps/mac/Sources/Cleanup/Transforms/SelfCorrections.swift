import Foundation

struct SelfCorrections: TranscriptTransform {
    static let markerExpression = try! NSRegularExpression(
        pattern: #"""
        (?<![\p{L}\p{N}_])
        (?:no\s+wait|i\s+mean|make\s+that|scratch\s+that|actually|sorry|rather)
        (?![\p{L}\p{N}_])
        """#,
        options: [.caseInsensitive, .allowCommentsAndWhitespace]
    )

    private let wordExpression = try! NSRegularExpression(
        pattern: "[\\p{L}\\p{N}]+(?:['’-][\\p{L}\\p{N}]+)*"
    )
    private let maximumReplacementWords = 6

    static func containsMarker(in transcript: String) -> Bool {
        markerExpression.firstMatch(
            in: transcript,
            range: transcript.fullNSRange
        ) != nil
    }

    func apply(_ transcript: String) -> String {
        let trimmed = transcript.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if trimmed.range(
            of: #"^scratch\s+that[.!?]?$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return ""
        }

        let matches = Self.markerExpression.matches(
            in: transcript,
            range: transcript.fullNSRange
        )
        // More than one marker is a nested/ambiguous correction. ADR 0019
        // deliberately leaves that case for the optional model.
        guard matches.count == 1,
              let match = matches.first,
              let markerRange = Range(match.range, in: transcript) else {
            return transcript
        }

        let marker = String(transcript[markerRange]).lowercased()
        var prefix = String(transcript[..<markerRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var replacement = String(transcript[markerRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        replacement = replacement.trimmingCharacters(
            in: CharacterSet(charactersIn: ",;:")
                .union(.whitespacesAndNewlines)
        )

        guard !prefix.isEmpty, !replacement.isEmpty else {
            return transcript
        }
        let loweredReplacement = replacement.lowercased()
        if marker == "rather",
           loweredReplacement == "than"
            || loweredReplacement.hasPrefix("than ") {
            return transcript
        }

        let replacementWordCount = wordExpression.numberOfMatches(
            in: replacement,
            range: replacement.fullNSRange
        )
        guard replacementWordCount > 0,
              replacementWordCount <= maximumReplacementWords else {
            return transcript
        }

        let prefixWords = wordExpression.matches(
            in: prefix,
            range: prefix.fullNSRange
        )
        guard !prefixWords.isEmpty else {
            return transcript
        }
        let wordsToReplace = min(
            replacementWordCount,
            prefixWords.count,
            maximumReplacementWords
        )
        let firstReplacedWord = prefixWords[
            prefixWords.count - wordsToReplace
        ]
        guard let removalRange = Range(
            NSRange(
                location: firstReplacedWord.range.location,
                length: prefix.utf16.count
                    - firstReplacedWord.range.location
            ),
            in: prefix
        ) else {
            return transcript
        }
        prefix.removeSubrange(removalRange)
        prefix = prefix.trimmingCharacters(
            in: CharacterSet(charactersIn: " ,;:")
                .union(.whitespacesAndNewlines)
        )

        return [prefix, replacement]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
