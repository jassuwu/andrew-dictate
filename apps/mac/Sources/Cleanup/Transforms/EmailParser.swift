import Foundation

struct EmailParser: TranscriptTransform {
    private let expression = try! NSRegularExpression(
        pattern: #"""
        (?<![\p{L}\p{N}@._%+\-])
        ([\p{L}\p{N}._%+\-]+(?:\s+(?:dot|underscore|dash|hyphen)\s+[\p{L}\p{N}]+)*)
        \s+at\s+
        ([\p{L}\p{N}\-]+(?:\s+dot\s+[\p{L}\p{N}\-]+)+)
        (?![\p{L}\p{N}@._%+\-])
        """#,
        options: [.caseInsensitive, .allowCommentsAndWhitespace]
    )

    func apply(_ transcript: String) -> String {
        expression.replacingMatches(in: transcript) { match in
            guard let local = transcript.substring(
                with: match.range(at: 1)
            ),
            let domain = transcript.substring(
                with: match.range(at: 2)
            ) else {
                return nil
            }

            let normalizedLocal = normalizeLocalPart(local)
            let normalizedDomain = domain.replacingOccurrences(
                of: "\\s+dot\\s+",
                with: ".",
                options: [.regularExpression, .caseInsensitive]
            )
            guard validDomain(normalizedDomain) else {
                return nil
            }
            return "\(normalizedLocal)@\(normalizedDomain)"
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
