import Foundation

/// Flags spoken self-corrections. Does not act on them.
///
/// This transform used to rewrite corrections inline: find a marker, delete
/// the words before it, keep the words after. Ticket 004 measured what that
/// did to ordinary English and the answer was that every marker in the list is
/// also a common word, so the transform deleted the subject of correct
/// sentences and left no trace — `"we should actually ship this today"` came
/// out as `"Ship this today."`, a statement turned into an imperative that
/// reads perfectly. SPEC §4 forbids precisely that: a failure that cannot be
/// told from a success.
///
/// There is no safe subset of markers. `no wait`, `make that` and
/// `scratch that` damage ordinary speech just as `actually` does — the signal
/// that separates a correction from an adverb is prosodic, and prosody is not
/// in the text. So the rewrite is gone.
///
/// The capability is not. `containsMarker` still reports every marker, and
/// `MessyGate` still routes a flagged transcript to the optional model, which
/// has the context this never had. ADR 0019 already sent ambiguous corrections
/// there; the measurement widened "ambiguous" to "all of them".
struct SelfCorrections: TranscriptTransform {
    static let markerExpression = CleanupRegex.compile(
        #"""
        (?<![\p{L}\p{N}_])
        (?:no\s+wait|i\s+mean|make\s+that|scratch\s+that|actually|sorry|rather)
        (?![\p{L}\p{N}_])
        """#,
        options: [.caseInsensitive, .allowCommentsAndWhitespace]
    )

    /// Whole-utterance `scratch that`, and nothing shorter. Anchored at both
    /// ends, which is what makes it unambiguous: there is no surrounding
    /// sentence for the words to be an ordinary part of.
    private static let discardExpression = #"^scratch\s+that[.!?]?$"#

    static func containsMarker(in transcript: String) -> Bool {
        // without the pattern nothing can be flagged, and an unflagged
        // transcript is left exactly as dictated.
        guard let markerExpression = markerExpression else {
            return false
        }
        return markerExpression.firstMatch(
            in: transcript,
            range: transcript.fullNSRange
        ) != nil
    }

    func apply(_ transcript: String) -> String {
        let trimmed = transcript.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if trimmed.range(
            of: Self.discardExpression,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return ""
        }

        return transcript
    }
}
