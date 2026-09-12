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
            // "look at github dot com" is a website, not a mailbox. the
            // refusal comes before any domain work, so the whole span goes
            // on to URLParser exactly as it was dictated.
            guard !Self.isCommonWord(normalizedLocal) else {
                return nil
            }
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
    ///
    /// the same question, asked of the other side of the @: the domain is
    /// trusted only when it ends in a dictatable tld, and the local part
    /// only when it is not an ordinary english word. "at" is how everyone
    /// names a website out loud, so "look at github dot com" has to come
    /// back as the sentence it is.
    private static let knownTLDs: Set<String> = [
        "com", "org", "net", "edu", "gov", "io", "ai", "app", "dev",
        "co", "uk", "us", "in", "me", "gg", "tv", "fm", "cc", "sh",
        "so", "to", "xyz", "info", "biz", "email", "page", "site",
    ]

    /// closed, english, and deliberately blunt: a word on this list is never
    /// a mailbox, so `office@` and `sign@` are refused too. every error it
    /// makes leaves a sentence alone, which is the side ADR 0018 chose.
    private static let commonWords: Set<String> = [
        "a", "about", "after", "again", "all", "also", "always", "am",
        "an", "and", "another", "any", "anything", "are", "around", "as",
        "ask", "asked", "at", "available", "away", "back", "based", "be",
        "because", "been", "before", "being", "below", "best", "better",
        "both", "bring", "but", "by", "call", "called", "can", "come",
        "comes", "coming", "could", "did", "do", "does", "doing", "done",
        "down", "during", "each", "either", "else", "even", "ever",
        "every", "everything", "far", "few", "find", "first", "for",
        "found", "from", "get", "gets", "getting", "give", "go", "goes",
        "going", "gone", "good", "got", "great", "had", "has", "have",
        "having", "he", "her", "here", "hers", "him", "his", "hold",
        "home", "host", "hosted", "how", "i", "if", "in", "into", "is",
        "it", "its", "just", "keep", "kept", "know", "known", "last",
        "later", "least", "left", "less", "let", "like", "live", "living",
        "look", "looked", "looking", "made", "make", "makes", "making",
        "many", "maybe", "me", "mean", "means", "meet", "meeting", "met",
        "might", "mine", "more", "most", "much", "must", "my", "need",
        "needs", "never", "new", "next", "no", "none", "not", "note",
        "now", "of", "off", "ok", "okay", "on", "once", "one", "only",
        "onto", "or", "other", "ought", "our", "ours", "out", "over",
        "own", "past", "put", "puts", "ran", "read", "really", "right",
        "run", "running", "said", "same", "saw", "say", "says", "see",
        "seen", "sell", "send", "sent", "set", "share", "shared", "she",
        "should", "show", "shown", "sign", "signed", "since", "so",
        "some", "something", "soon", "start", "started", "still", "stop",
        "such", "sure", "take", "taken", "talk", "tell", "than", "that",
        "the", "their", "theirs", "them", "then", "there", "these",
        "they", "thing", "things", "think", "this", "those", "though",
        "through", "to", "together", "told", "too", "took", "try",
        "under", "until", "up", "upon", "us", "use", "used", "uses",
        "using", "very", "wait", "want", "wants", "was", "watch", "we",
        "well", "went", "were", "what", "when", "where", "which",
        "while", "who", "why", "will", "with", "within", "without",
        "work", "worked", "working", "works", "would", "write", "writes",
        "yes", "yet", "you", "your", "yours",
    ]

    /// lowercased is load-bearing: this stage runs before Capitalization,
    /// so a local part arrives in whatever case it was dictated in.
    private static func isCommonWord(_ local: String) -> Bool {
        commonWords.contains(local.lowercased())
    }

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
