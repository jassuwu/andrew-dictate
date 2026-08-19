import Foundation

struct SpokenPunctuation: TranscriptTransform {
    private enum Kind {
        case trailing(String)
        case lineBreak(String)
        case openQuote
        case closeQuote
    }

    private struct Marker {
        let expression: NSRegularExpression
        let kind: Kind

        /// nil for a malformed pattern, so one mistyped marker drops out of
        /// the list and the other ten keep working.
        init?(pattern: String, kind: Kind) {
            guard let expression = CleanupRegex.compile(
                pattern,
                options: [.caseInsensitive]
            ) else {
                return nil
            }
            self.expression = expression
            self.kind = kind
        }
    }

    // hoisted out of formatExtractedSymbols: it runs on every utterance,
    // so the patterns are compiled once, not per transcript.
    private static let beforePunctuation = CleanupRegex.compile(
        "[ \\t]+([,.;:!?])"
    )
    private static let repeatedHorizontalSpace = CleanupRegex.compile(
        "[ \\t]+"
    )
    private static let aroundLineBreak = CleanupRegex.compile(
        "[ \\t]*\\n[ \\t]*"
    )
    private static let afterPunctuation = CleanupRegex.compile(
        "([,.;:!?])(?=[\\p{L}\\p{N}\"])"
    )

    private let markers: [Marker] = [
        Marker(
            pattern: "(?<![\\p{L}\\p{N}_])new paragraph(?![\\p{L}\\p{N}_])",
            kind: .lineBreak("\n\n")
        ),
        Marker(
            pattern: "(?<![\\p{L}\\p{N}_])new line(?![\\p{L}\\p{N}_])",
            kind: .lineBreak("\n")
        ),
        Marker(
            pattern: "(?<![\\p{L}\\p{N}_])question mark(?![\\p{L}\\p{N}_])",
            kind: .trailing("?")
        ),
        Marker(
            pattern: "(?<![\\p{L}\\p{N}_])exclamation (?:mark|point)(?![\\p{L}\\p{N}_])",
            kind: .trailing("!")
        ),
        Marker(
            pattern: "(?<![\\p{L}\\p{N}_])full stop(?![\\p{L}\\p{N}_])",
            kind: .trailing(".")
        ),
        Marker(
            pattern: "(?<![\\p{L}\\p{N}_])open quote(?![\\p{L}\\p{N}_])",
            kind: .openQuote
        ),
        Marker(
            pattern: "(?<![\\p{L}\\p{N}_])close quote(?![\\p{L}\\p{N}_])",
            kind: .closeQuote
        ),
        Marker(
            pattern: "(?<![\\p{L}\\p{N}_])comma(?![\\p{L}\\p{N}_])",
            kind: .trailing(",")
        ),
        Marker(
            pattern: "(?<![\\p{L}\\p{N}_])period(?![\\p{L}\\p{N}_])",
            kind: .trailing(".")
        ),
        Marker(
            pattern: "(?<![\\p{L}\\p{N}_])colon(?![\\p{L}\\p{N}_])",
            kind: .trailing(":")
        ),
        Marker(
            pattern: "(?<![\\p{L}\\p{N}_])semicolon(?![\\p{L}\\p{N}_])",
            kind: .trailing(";")
        ),
    ].compactMap { $0 }

    func apply(_ transcript: String) -> String {
        var result = transcript
        for marker in markers {
            result = marker.expression.replacingMatches(in: result) { match in
                guard let range = Range(match.range, in: result) else {
                    return nil
                }
                let before = result[..<range.lowerBound]
                let after = result[range.upperBound...]
                guard isPlausible(
                    marker.kind,
                    before: before,
                    after: after
                ) else {
                    return nil
                }

                switch marker.kind {
                case let .trailing(symbol):
                    return symbol
                case let .lineBreak(lineBreak):
                    return lineBreak
                case .openQuote, .closeQuote:
                    return "\""
                }
            }
        }

        // symbols dropped in without their spacing fixed would read worse
        // than the spoken words, so an unusable formatter voids the stage.
        guard let formatted = formatExtractedSymbols(result) else {
            return transcript
        }
        return formatted
    }

    private func isPlausible(
        _ kind: Kind,
        before: Substring,
        after: Substring
    ) -> Bool {
        let hasContentBefore = before.contains {
            $0.isLetter || $0.isNumber || $0 == "\""
        }
        let hasContentAfter = after.contains {
            $0.isLetter || $0.isNumber || $0 == "\""
        }

        switch kind {
        case .openQuote:
            return hasContentAfter
        case .closeQuote:
            return hasContentBefore
        case .trailing, .lineBreak:
            // A spoken marker must follow content, which keeps command-like
            // phrases such as "comma support" unchanged. Natural dictation
            // still cannot distinguish "the word comma"; that v1 limitation
            // is explicitly accepted by ADR 0019.
            return hasContentBefore
        }
    }

    private func formatExtractedSymbols(_ input: String) -> String? {
        guard let beforePunctuation = Self.beforePunctuation,
              let repeatedHorizontalSpace = Self.repeatedHorizontalSpace,
              let aroundLineBreak = Self.aroundLineBreak,
              let afterPunctuation = Self.afterPunctuation else {
            return nil
        }

        var result = input
        result = beforePunctuation.stringByReplacingMatches(
            in: result,
            range: result.fullNSRange,
            withTemplate: "$1"
        )
        result = repeatedHorizontalSpace.stringByReplacingMatches(
            in: result,
            range: result.fullNSRange,
            withTemplate: " "
        )
        result = aroundLineBreak.stringByReplacingMatches(
            in: result,
            range: result.fullNSRange,
            withTemplate: "\n"
        )
        result = afterPunctuation.stringByReplacingMatches(
            in: result,
            range: result.fullNSRange,
            withTemplate: "$1 "
        )

        return normalizeQuoteSpacing(result)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizeQuoteSpacing(_ input: String) -> String {
        let characters = Array(input)
        var output = ""
        var cursor = 0
        var quoteIsOpening = true

        while cursor < characters.count {
            let character = characters[cursor]
            guard character == "\"" else {
                output.append(character)
                cursor += 1
                continue
            }

            if quoteIsOpening {
                output.append(character)
                cursor += 1
                while cursor < characters.count,
                      characters[cursor] == " " {
                    cursor += 1
                }
            } else {
                while output.last == " " {
                    output.removeLast()
                }
                output.append(character)
                cursor += 1
            }
            quoteIsOpening.toggle()
        }
        return output
    }
}
