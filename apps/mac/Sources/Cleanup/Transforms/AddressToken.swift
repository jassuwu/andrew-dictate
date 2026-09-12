import Foundation

/// one answer to "is this token an address?", for the four stages that each
/// used to guess: a dot inside example.com is not the end of a sentence, and
/// the "seven" in seven.com is part of a domain, not a count.
enum AddressToken {
    /// the tlds a person could plausibly dictate, kept here rather than
    /// inside EmailParser so the stage that builds an address and the stages
    /// that read one back agree on what a domain looks like. it is the
    /// arbiter: a .gg link is recognised because gg is on the list, and
    /// anything exotic still reads as prose.
    static let knownTopLevelDomains: Set<String> = [
        "com", "org", "net", "edu", "gov", "io", "ai", "app", "dev",
        "co", "uk", "us", "in", "me", "gg", "tv", "fm", "cc", "sh",
        "so", "to", "xyz", "info", "biz", "email", "page", "site",
    ]

    /// a whitespace-delimited token, sentence punctuation trimmed off the
    /// end: an email, a url with a scheme, a www host, or a bare
    /// domain.tld with an optional path.
    static func isAddress(_ token: String) -> Bool {
        let core = sentencePunctuationTrimmed(token)
        guard !core.isEmpty else {
            return false
        }
        if core.contains("@") || core.contains("://") {
            return true
        }

        let lowered = core.lowercased()
        if lowered.hasPrefix("www.") {
            return true
        }
        let host = lowered.prefix { $0 != "/" }
        let labels = host.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard labels.count >= 2,
              let topLevelDomain = labels.last,
              knownTopLevelDomains.contains(String(topLevelDomain)) else {
            return false
        }
        return labels.allSatisfy { label in
            !label.isEmpty && label.allSatisfy(isLabelCharacter)
        }
    }

    /// the whitespace-delimited token a range sits inside — what a stage
    /// needs before it can ask whether it is about to edit an address.
    static func enclosingToken(
        _ range: Range<String.Index>,
        in text: String
    ) -> String {
        var start = range.lowerBound
        while start > text.startIndex {
            let previous = text.index(before: start)
            guard !text[previous].isWhitespace else {
                break
            }
            start = previous
        }
        var end = range.upperBound
        while end < text.endIndex, !text[end].isWhitespace {
            end = text.index(after: end)
        }
        return String(text[start..<end])
    }

    private static func sentencePunctuationTrimmed(
        _ token: String
    ) -> String {
        var core = token
        while let last = core.last, ".,;:!?\"".contains(last) {
            core.removeLast()
        }
        return core
    }

    private static func isLabelCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "-"
    }
}
