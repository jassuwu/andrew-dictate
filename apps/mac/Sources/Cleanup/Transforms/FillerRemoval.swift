import Foundation

struct FillerRemoval: TranscriptTransform {
    private let fillerExpression = CleanupRegex.compile(
        #"""
        (?<![\p{L}\p{N}_])(?:um|uh|erm|uhm)(?![\p{L}\p{N}_]),?
        """#,
        options: [.caseInsensitive]
    )
    private let horizontalWhitespace = CleanupRegex.compile("[ \\t]+")

    func apply(_ transcript: String) -> String {
        // both passes or neither: removing fillers without re-collapsing
        // the gaps they leave would be worse than not removing them.
        guard let fillerExpression = fillerExpression,
              let horizontalWhitespace = horizontalWhitespace else {
            return transcript
        }
        var result = fillerExpression.stringByReplacingMatches(
            in: transcript,
            range: transcript.fullNSRange,
            withTemplate: ""
        )
        result = horizontalWhitespace.stringByReplacingMatches(
            in: result,
            range: result.fullNSRange,
            withTemplate: " "
        )
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
