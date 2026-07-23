import Foundation

protocol Cleaner {
    func clean(_ transcript: String) -> String
}

struct DeterministicCleaner: Cleaner {
    private struct Substitution {
        let expression: NSRegularExpression
        let replacementTemplate: String
    }

    private let substitutions: [Substitution]
    private let fillerExpression: NSRegularExpression
    private let whitespaceExpression: NSRegularExpression
    private let spaceBeforePunctuationExpression: NSRegularExpression

    init(entries: [DictionaryEntry] = []) {
        substitutions = entries.compactMap { entry in
            guard !entry.wrong.isEmpty else {
                return nil
            }

            let escapedWrong = NSRegularExpression.escapedPattern(
                for: entry.wrong
            )
            let pattern = """
            (?<![\\p{L}\\p{N}_])\(escapedWrong)(?![\\p{L}\\p{N}_])
            """

            guard let expression = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) else {
                return nil
            }

            return Substitution(
                expression: expression,
                replacementTemplate: NSRegularExpression.escapedTemplate(
                    for: entry.right
                )
            )
        }

        fillerExpression = try! NSRegularExpression(
            pattern: """
            (?<![\\p{L}\\p{N}_])(?:um|uh|erm|uhm)(?![\\p{L}\\p{N}_]),?
            """,
            options: [.caseInsensitive]
        )
        whitespaceExpression = try! NSRegularExpression(
            pattern: "\\s+"
        )
        spaceBeforePunctuationExpression = try! NSRegularExpression(
            pattern: "\\s+([,.;:!?])"
        )
    }

    func clean(_ transcript: String) -> String {
        var result = transcript

        for substitution in substitutions {
            result = substitution.expression.stringByReplacingMatches(
                in: result,
                range: result.fullNSRange,
                withTemplate: substitution.replacementTemplate
            )
        }

        result = fillerExpression.stringByReplacingMatches(
            in: result,
            range: result.fullNSRange,
            withTemplate: ""
        )
        result = whitespaceExpression.stringByReplacingMatches(
            in: result,
            range: result.fullNSRange,
            withTemplate: " "
        )
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        result = spaceBeforePunctuationExpression.stringByReplacingMatches(
            in: result,
            range: result.fullNSRange,
            withTemplate: "$1"
        )

        guard let firstCharacter = result.first else {
            return result
        }

        result.replaceSubrange(
            result.startIndex...result.startIndex,
            with: String(firstCharacter).uppercased()
        )
        return result
    }
}

private extension String {
    var fullNSRange: NSRange {
        NSRange(startIndex..<endIndex, in: self)
    }
}
