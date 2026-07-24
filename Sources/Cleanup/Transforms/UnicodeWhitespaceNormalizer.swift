import Foundation

struct UnicodeWhitespaceNormalizer: TranscriptTransform {
    private let whitespace = try! NSRegularExpression(
        pattern: "[\\s\\p{Z}]+"
    )

    func apply(_ transcript: String) -> String {
        let normalized = transcript
            .precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\u{200B}", with: "")
        let collapsed = whitespace.stringByReplacingMatches(
            in: normalized,
            range: normalized.fullNSRange,
            withTemplate: " "
        )
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
