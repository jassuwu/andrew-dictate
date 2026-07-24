import Foundation

struct PunctuationFinishing: TranscriptTransform {
    private let beforePunctuation = try! NSRegularExpression(
        pattern: "[ \\t]+([,.;:!?%])"
    )
    private let horizontalWhitespace = try! NSRegularExpression(
        pattern: "[ \\t]+"
    )
    private let afterSeparator = try! NSRegularExpression(
        pattern: "([,;:])(?=[\\p{L}\"])"
    )
    private let aroundLineBreak = try! NSRegularExpression(
        pattern: "[ \\t]*\\n[ \\t]*"
    )

    func apply(_ transcript: String) -> String {
        var result = horizontalWhitespace.stringByReplacingMatches(
            in: transcript,
            range: transcript.fullNSRange,
            withTemplate: " "
        )
        result = beforePunctuation.stringByReplacingMatches(
            in: result,
            range: result.fullNSRange,
            withTemplate: "$1"
        )
        result = afterSeparator.stringByReplacingMatches(
            in: result,
            range: result.fullNSRange,
            withTemplate: "$1 "
        )
        result = aroundLineBreak.stringByReplacingMatches(
            in: result,
            range: result.fullNSRange,
            withTemplate: "\n"
        )
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !result.isEmpty else {
            return result
        }
        if result.last == "\"" {
            let quoteIndex = result.index(before: result.endIndex)
            guard quoteIndex != result.startIndex else {
                return result
            }
            let beforeQuote = result.index(before: quoteIndex)
            if !isTerminal(result[beforeQuote]) {
                result.insert(".", at: quoteIndex)
            }
        } else if let last = result.last, !isTerminal(last) {
            result.append(".")
        }
        return result
    }

    private func isTerminal(_ character: Character) -> Bool {
        character == "." || character == "?"
            || character == "!" || character == ":"
            || character == ";"
    }
}
