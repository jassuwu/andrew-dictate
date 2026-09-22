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

    // hoisted out of formatExtractedSymbols: it runs on every utterance, so
    // these four are compiled once for the whole process. the markers below
    // are compiled once per cleaner — which is why the coordinator keeps one
    // instead of building a fresh one per dictation.
    private static let beforePunctuation = CleanupRegex.compile(
        "[ \\t]+([,.;:!?])"
    )
    private static let repeatedHorizontalSpace = CleanupRegex.compile(
        "[ \\t]+"
    )
    private static let aroundLineBreak = CleanupRegex.compile(
        "[ \\t]*\\n[ \\t]*"
    )
    // no \p{N} in the lookahead, the same narrowing PunctuationFinishing
    // already made: a digit after a separator is "1.5", "8:30", "20,000",
    // never a new word that needs a space.
    private static let afterPunctuation = CleanupRegex.compile(
        "([,.;:!?])(?=[\\p{L}\"])"
    )

    /// one row per spoken marker: the phrase you say, any other phrasing
    /// that means the same mark, and what it becomes. the patterns below and
    /// the list settings prints both read this table, so they cannot drift.
    private struct Row {
        let spoken: String
        var alternates: [String] = []
        let kind: Kind

        /// every way to say it, for one alternation in the pattern.
        var phrases: [String] { [spoken] + alternates }
    }

    /// reading order: the two line breaks first, because saying them is the
    /// only way to get one. the phrases are not substrings of one another,
    /// so the order the pass applies them in does not change the result.
    private static let rows: [Row] = [
        Row(spoken: "new paragraph", kind: .lineBreak("\n\n")),
        Row(spoken: "new line", kind: .lineBreak("\n")),
        Row(spoken: "comma", kind: .trailing(",")),
        Row(spoken: "period", kind: .trailing(".")),
        Row(spoken: "full stop", kind: .trailing(".")),
        Row(spoken: "question mark", kind: .trailing("?")),
        Row(
            spoken: "exclamation mark",
            alternates: ["exclamation point"],
            kind: .trailing("!")
        ),
        Row(spoken: "colon", kind: .trailing(":")),
        Row(spoken: "semicolon", kind: .trailing(";")),
        Row(spoken: "open quote", kind: .openQuote),
        Row(spoken: "close quote", kind: .closeQuote),
    ]

    /// the phrases alone, in reading order, for the line settings shows under
    /// the pipeline. what the screen lists is what the cleaner listens for.
    static let spokenMarkers: [String] = rows.map(\.spoken)

    private let markers: [Marker] = SpokenPunctuation.rows.compactMap { row in
        Marker(
            pattern: SpokenPunctuation.bounded(row.phrases),
            kind: row.kind
        )
    }

    /// a marker counts only as a phrase of its own — "comma" inside "comma
    /// support" is a word you said, not a mark you asked for.
    private static func bounded(_ phrases: [String]) -> String {
        let spoken = phrases.joined(separator: "|")
        return "(?<![\\p{L}\\p{N}_])(?:\(spoken))(?![\\p{L}\\p{N}_])"
    }

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

        // no marker fired, so there is no symbol of ours to space: the
        // punctuation in here is punctuation the speech model wrote, and
        // re-spacing it splits "7 p.m." and "20,000". whitespace is already
        // collapsed upstream and again in PunctuationFinishing.
        guard result != transcript else {
            return transcript
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
        result = afterPunctuation.replacingMatches(in: result) { match in
            guard let range = Range(match.range, in: result),
                  let symbol = result.substring(with: match.range) else {
                return nil
            }
            guard !isAbbreviationDot(
                symbol,
                at: range.lowerBound,
                in: result
            ) else {
                return nil
            }
            // an address is one word: the dot in example.com and the one in
            // john@cypher.io never take a space.
            guard !AddressToken.isAddress(
                AddressToken.enclosingToken(range, in: result)
            ) else {
                return nil
            }
            return symbol + " "
        }

        return normalizeQuoteSpacing(result)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// a dot after a single letter that itself follows a dot is an
    /// abbreviation, not a sentence: "7 p.m.", "e.g.", "the U.S. team". a
    /// space there cuts the word in half and shouts the next one.
    private func isAbbreviationDot(
        _ symbol: String,
        at index: String.Index,
        in text: String
    ) -> Bool {
        guard symbol == ".", index > text.startIndex else {
            return false
        }
        let letterIndex = text.index(before: index)
        guard text[letterIndex].isLetter,
              letterIndex > text.startIndex else {
            return false
        }
        return text[text.index(before: letterIndex)] == "."
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
