import Foundation

struct DictionarySubstitutions: TranscriptTransform {
    private struct Substitution {
        let expression: NSRegularExpression
        let replacementTemplate: String
    }

    private let substitutions: [Substitution]

    init(entries: [DictionaryEntry] = []) {
        substitutions = entries.compactMap { entry in
            // both sides. an entry whose right side is empty compiles to an
            // empty replacement template, and then the rule deletes the word
            // from every dictation — the cleaner renders, it never removes
            // (ADR 0020). rows already on disk are covered here too.
            guard !entry.wrong.isEmpty,
                  !entry.right
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty else {
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
