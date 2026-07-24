import Foundation

struct FillerRemoval: TranscriptTransform {
    private let fillerExpression = try! NSRegularExpression(
        pattern: #"""
        (?<![\p{L}\p{N}_])(?:um|uh|erm|uhm)(?![\p{L}\p{N}_]),?
        """#,
        options: [.caseInsensitive]
    )
    private let horizontalWhitespace = try! NSRegularExpression(
        pattern: "[ \\t]+"
    )

    func apply(_ transcript: String) -> String {
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
