import Foundation

struct URLParser: TranscriptTransform {
    private static let recognizedTopLevelDomains: Set<String> = [
        "ai", "app", "co", "com", "dev", "edu", "gov", "info", "io",
        "ly", "me", "net", "org", "tech", "uk",
    ]

    private let expression = try! NSRegularExpression(
        pattern: #"""
        (?<![@\p{L}\p{N}._\-])
        ((?:www\s+dot\s+)?[\p{L}\p{N}\-]+(?:\s+dot\s+[\p{L}\p{N}\-]+)+)
        (
          (?:\s+slash(?:\s+[\p{L}\p{N}]+
            (?:\s+(?:dash|hyphen|underscore)\s+[\p{L}\p{N}]+)*
          )?)*
        )
        (?![\p{L}\p{N}._\-])
        """#,
        options: [.caseInsensitive, .allowCommentsAndWhitespace]
    )

    func apply(_ transcript: String) -> String {
        expression.replacingMatches(in: transcript) { match in
            guard let spokenDomain = transcript.substring(
                with: match.range(at: 1)
            ),
            let spokenPath = transcript.substring(
                with: match.range(at: 2)
            ) else {
                return nil
            }

            let domain = spokenDomain.replacingOccurrences(
                of: "\\s+dot\\s+",
                with: ".",
                options: [.regularExpression, .caseInsensitive]
            )
            guard validDomain(domain) else {
                return nil
            }
            return domain + normalizePath(spokenPath)
        }
    }

    private func validDomain(_ domain: String) -> Bool {
        let labels = domain.split(separator: ".")
        guard labels.count >= 2,
              let topLevelDomain = labels.last,
              Self.recognizedTopLevelDomains.contains(
                topLevelDomain.lowercased()
              ) else {
            return false
        }
        return labels.allSatisfy {
            !$0.isEmpty
                && !$0.hasPrefix("-")
                && !$0.hasSuffix("-")
        }
    }

    private func normalizePath(_ spokenPath: String) -> String {
        guard !spokenPath.isEmpty else {
            return ""
        }
        let components = spokenPath.components(
            separatedBy: try! NSRegularExpression(
                pattern: "\\s+slash(?:\\s+|$)",
                options: [.caseInsensitive]
            )
        )
        return components.dropFirst().reduce(into: "") { path, component in
            path += "/"
            path += component
                .replacingOccurrences(
                    of: "\\s+(?:dash|hyphen)\\s+",
                    with: "-",
                    options: [.regularExpression, .caseInsensitive]
                )
                .replacingOccurrences(
                    of: "\\s+underscore\\s+",
                    with: "_",
                    options: [.regularExpression, .caseInsensitive]
                )
        }
    }
}

private extension String {
    func components(
        separatedBy expression: NSRegularExpression
    ) -> [String] {
        var components: [String] = []
        var cursor = startIndex
        for match in expression.matches(in: self, range: fullNSRange) {
            guard let range = Range(match.range, in: self) else {
                continue
            }
            components.append(String(self[cursor..<range.lowerBound]))
            cursor = range.upperBound
        }
        components.append(String(self[cursor...]))
        return components
    }
}
