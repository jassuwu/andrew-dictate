import Foundation

/// finds the words we inserted again, inside a bounded read around where we
/// put them.
///
/// the anchors are our first and last words: whatever you fixed between
/// them, they hold still. a fix to an anchor itself falls back to what is
/// still known — where we put the first word, or the end of the field after
/// the last — and with neither anchor found the dictation is given up on.
/// everything outside the anchors is looked at here and dropped; only our
/// words come back.
enum SpanLocator {
    struct Located: Equatable, Sendable {
        /// our words as they read now, first word to last.
        let text: String
        /// where they start in the window, in utf-16 units like AX ranges.
        let start: Int
    }

    /// - expectedStart: where the inserted text began in the window, in
    ///   utf-16 units.
    /// - reachesFieldEnd: the window runs to the end of the field, so
    ///   nothing of yours can follow its last word.
    static func locate(
        _ inserted: String,
        in window: String,
        expectedStart: Int,
        reachesFieldEnd: Bool
    ) -> Located? {
        let ours = runs(in: inserted)
        guard let firstWord = ours.first, let lastWord = ours.last else {
            return nil
        }
        let theirs = runs(in: window)
        let coreLength = lastWord.range.upperBound - firstWord.range.location
        let expectedCoreStart = expectedStart + firstWord.range.location

        // the first word nearest where we put it; failing that, whatever
        // word now starts exactly there — the one you fixed.
        let startByWord = nearest(
            theirs.indices.filter { theirs[$0].matches(firstWord) },
            in: theirs,
            to: expectedCoreStart,
            by: \.location
        )
        guard let startIndex = startByWord
            ?? theirs.firstIndex(where: {
                $0.range.location == expectedCoreStart
            }) else {
            return nil
        }
        let start = theirs[startIndex].range.location

        // the last word nearest where it should end. one word is its own
        // last word; otherwise it comes after the first.
        let endByWord = nearest(
            theirs.indices.filter {
                theirs[$0].matches(lastWord)
                    && (ours.count == 1
                        ? $0 == startIndex && startByWord != nil
                        : $0 > startIndex)
            },
            in: theirs,
            to: start + coreLength,
            by: \.upperBound
        )

        // both anchors gone: nothing of ours is left to be sure of.
        guard startByWord != nil || endByWord != nil else {
            return nil
        }

        let endIndex: Int
        if let endByWord {
            endIndex = endByWord
        } else if reachesFieldEnd, let last = theirs.indices.last {
            endIndex = last
        } else {
            // your own text may follow the word you fixed, and there is no
            // telling where ours stopped.
            return nil
        }

        let range = NSRange(
            location: start,
            length: theirs[endIndex].range.upperBound - start
        )
        return Located(
            text: (window as NSString).substring(with: range),
            start: start
        )
    }

    // MARK: - pieces

    private struct Run {
        let text: String
        let range: NSRange

        func matches(_ other: Run) -> Bool {
            text.lowercased() == other.text.lowercased()
        }
    }

    /// the words a person points at, as fix-a-word splits them: "jaz.gg"
    /// is two, so a fix to "jaz" leaves "gg" standing as an anchor.
    private static let word = CleanupRegex.compile(
        "[\\p{L}\\p{N}]+(?:['’-][\\p{L}\\p{N}]+)*"
    )

    private static func runs(in text: String) -> [Run] {
        guard let word else {
            return []
        }
        let nsText = text as NSString
        return word.matches(
            in: text,
            range: NSRange(location: 0, length: nsText.length)
        ).map { Run(text: nsText.substring(with: $0.range), range: $0.range) }
    }

    private static func nearest(
        _ indices: [Int],
        in runs: [Run],
        to target: Int,
        by position: KeyPath<NSRange, Int>
    ) -> Int? {
        indices.min {
            abs(runs[$0].range[keyPath: position] - target)
                < abs(runs[$1].range[keyPath: position] - target)
        }
    }
}
