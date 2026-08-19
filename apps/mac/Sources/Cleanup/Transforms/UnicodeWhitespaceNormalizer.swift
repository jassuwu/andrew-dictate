import Foundation

struct UnicodeWhitespaceNormalizer: TranscriptTransform {
    private let whitespace = CleanupRegex.compile("[\\s\\p{Z}]+")

    func apply(_ transcript: String) -> String {
        // a rule that failed to compile degrades to identity: a missing
        // cleanup beats a mangled transcript.
        guard let whitespace = whitespace else {
            return transcript
        }
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
