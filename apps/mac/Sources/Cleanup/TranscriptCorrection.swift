import Foundation

/// A raw transcript, split into the pieces a person can point at.
///
/// Ticket 011: the app's most frequent failure is the engine mishearing a name
/// or an identifier, and the cure — a dictionary entry — already works. It is
/// barely used because the only way to add one is to retype, from memory, the
/// misspelling the engine produced. Get a character wrong and the entry
/// silently never fires, which is a failure indistinguishable from success.
///
/// Building the entry from a span of the transcript removes that failure by
/// construction. `DictionarySubstitutions` matches the `wrong` side literally,
/// case-insensitively, bounded by non-word characters — so a `wrong` side taken
/// from the transcript's own words cannot fail to match it.
struct TranscriptCorrection {
    struct Span: Equatable, Identifiable, Sendable {
        /// Position among the transcript's words, which is also what makes a
        /// contiguous multi-word selection expressible as a range.
        let id: Int
        let text: String
        let range: Range<String.Index>
    }

    let transcript: String
    let spans: [Span]

    init(transcript: String) {
        self.transcript = transcript

        // Words only. Punctuation is excluded rather than trimmed, because a
        // `wrong` side that starts or ends with punctuation fights the word
        // boundaries the substitution relies on.
        let word = CleanupRegex.compile(
            "[\\p{L}\\p{N}]+(?:['’-][\\p{L}\\p{N}]+)*"
        )
        guard let word else {
            spans = []
            return
        }

        spans = word.matches(
            in: transcript,
            range: transcript.fullNSRange
        ).enumerated().compactMap { index, match in
            guard let range = Range(match.range, in: transcript) else {
                return nil
            }
            return Span(id: index, text: String(transcript[range]), range: range)
        }
    }

    /// The transcript's own text from the first word through the last, so the
    /// whitespace between them is whatever was really there.
    func phrase(from first: Int, through last: Int) -> String? {
        guard first <= last,
              spans.indices.contains(first),
              spans.indices.contains(last) else {
            return nil
        }
        return String(
            transcript[spans[first].range.lowerBound..<spans[last].range.upperBound]
        )
    }

    func entry(
        from first: Int,
        through last: Int,
        right: String
    ) -> DictionaryEntry? {
        let replacement = right.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !replacement.isEmpty, let wrong = phrase(from: first, through: last)
        else {
            return nil
        }
        return DictionaryEntry(wrong: wrong, right: replacement)
    }
}
