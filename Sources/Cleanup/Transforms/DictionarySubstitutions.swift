import Foundation

struct DictionarySubstitutions: TranscriptTransform {
    private struct Substitution {
        let expression: NSRegularExpression
        let replacementTemplate: String
    }

    private let substitutions: [Substitution]

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
    }

    func apply(_ transcript: String) -> String {
        substitutions.reduce(transcript) { result, substitution in
            substitution.expression.stringByReplacingMatches(
                in: result,
                range: result.fullNSRange,
                withTemplate: substitution.replacementTemplate
            )
        }
    }
}

struct DictionarySubstituter {
    private let transform: DictionarySubstitutions

    init(entries: [DictionaryEntry] = []) {
        transform = DictionarySubstitutions(entries: entries)
    }

    func apply(to transcript: String) -> String {
        transform.apply(transcript)
    }
}
