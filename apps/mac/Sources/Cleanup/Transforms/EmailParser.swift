import Foundation

struct EmailParser: TranscriptTransform {
    private let expression = CleanupRegex.compile(
        #"""
        (?<![\p{L}\p{N}@._%+\-])
        ([\p{L}\p{N}._%+\-]+(?:\s+(?:dot|underscore|dash|hyphen)\s+[\p{L}\p{N}]+)*)
        \s+at\s+
        ([\p{L}\p{N}\-]+(?:(?:\s+dot\s+|\s*\.\s*)[\p{L}\p{N}\-]+)+)
        (?![\p{L}\p{N}@._%+\-])
        """#,
        options: [.caseInsensitive, .allowCommentsAndWhitespace]
    )

    func apply(_ transcript: String) -> String {
        // no pattern, no spoken-email rewriting — the transcript passes
        // through as dictated.
        guard let expression = expression else {
            return transcript
        }
        return expression.replacingMatches(in: transcript) { match in
            guard let local = transcript.substring(
                with: match.range(at: 1)
            ),
            let domain = transcript.substring(
                with: match.range(at: 2)
            ) else {
                return nil
            }

            let normalizedLocal = normalizeLocalPart(local)
            let spokenDot = domain.range(
                of: "\\s+dot\\s+",
                options: [.regularExpression, .caseInsensitive]
            ) != nil
            let normalizedDomain = domain
                .replacingOccurrences(
                    of: "\\s+dot\\s+",
                    with: ".",
                    options: [.regularExpression, .caseInsensitive]
                )
                .replacingOccurrences(
                    of: "\\s*\\.\\s*",
                    with: ".",
                    options: [.regularExpression]
                )
            // a spoken "dot" keeps the casing you dictated; a literal period
            // means the speech model wrote the domain itself, and it shouts
            // tlds — "jass. GG". that shouting is not something you said.
            let canonicalDomain = spokenDot
                ? normalizedDomain
                : normalizedDomain.lowercased()
            guard validDomain(canonicalDomain),
                  spokenDot || endsInKnownTLD(canonicalDomain) else {
                return nil
            }
            return "\(normalizedLocal)@\(canonicalDomain)"
        }
    }

    private func normalizeLocalPart(_ local: String) -> String {
        local
            .replacingOccurrences(
                of: "\\s+dot\\s+",
                with: ".",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(
                of: "\\s+underscore\\s+",
                with: "_",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(
                of: "\\s+(?:dash|hyphen)\\s+",
                with: "-",
                options: [.regularExpression, .caseInsensitive]
            )
    }

    /// speech models often render a spoken "dot" as a real period, so
    /// "jass at jass dot gg" can reach us as "jass at jass. GG". that form is
    /// worth catching — but a bare period is also just a sentence ending, and
    /// "i met him at home. Great to see him" must never become an address.
    /// so the literal-dot spelling is only trusted when it ends in a tld
    /// someone could plausibly have dictated.
    private static let knownTLDs: Set<String> = [
        "com", "org", "net", "edu", "gov", "io", "ai", "app", "dev",
        "co", "uk", "us", "in", "me", "gg", "tv", "fm", "cc", "sh",
        "so", "to", "xyz", "info", "biz", "email", "page", "site",
    ]

    private func endsInKnownTLD(_ domain: String) -> Bool {
        guard let tld = domain.split(separator: ".").last else {
            return false
        }
        return Self.knownTLDs.contains(String(tld))
    }

    private func validDomain(_ domain: String) -> Bool {
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2,
              let topLevelDomain = labels.last,
              (2...24).contains(topLevelDomain.count),
              topLevelDomain.allSatisfy(\.isLetter) else {
            return false
        }
        return labels.allSatisfy {
            !$0.isEmpty
                && !$0.hasPrefix("-")
                && !$0.hasSuffix("-")
        }
    }
}
