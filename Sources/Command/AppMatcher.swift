import Foundation

struct InstalledApp: Equatable, Sendable {
    let displayName: String
    let url: URL
    let bundleIdentifier: String?
}

struct AppMatcher {
    let applications: [InstalledApp]

    func match(_ query: String) -> InstalledApp? {
        let trimmedQuery = query.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmedQuery.isEmpty else {
            return nil
        }

        if let exactMatch = bestMatch(
            applications.filter {
                $0.displayName.compare(
                    trimmedQuery,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    range: nil,
                    locale: Locale(identifier: "en_US_POSIX")
                ) == .orderedSame
            }
        ) {
            return exactMatch
        }

        if let prefixMatch = bestMatch(
            applications.filter {
                $0.displayName.range(
                    of: trimmedQuery,
                    options: [
                        .anchored,
                        .caseInsensitive,
                        .diacriticInsensitive,
                    ],
                    locale: Locale(identifier: "en_US_POSIX")
                ) != nil
            }
        ) {
            return prefixMatch
        }

        let queryTokens = Set(tokens(in: trimmedQuery))
        if !queryTokens.isEmpty,
           let tokenMatch = bestMatch(
               applications.filter {
                   queryTokens.isSubset(of: Set(tokens(in: $0.displayName)))
               }
           ) {
            return tokenMatch
        }

        let normalizedQuery = normalizedForDistance(trimmedQuery)
        guard !normalizedQuery.isEmpty else {
            return nil
        }

        let threshold = maximumDistance(for: normalizedQuery.count)
        let ranked = applications.compactMap { application -> (
            application: InstalledApp,
            distance: Int
        )? in
            let candidate = normalizedForDistance(application.displayName)
            let distance = levenshteinDistance(
                between: normalizedQuery,
                and: candidate
            )
            guard distance <= threshold else {
                return nil
            }
            return (application, distance)
        }

        return ranked.min { lhs, rhs in
            if lhs.distance != rhs.distance {
                return lhs.distance < rhs.distance
            }
            return isPreferred(lhs.application, over: rhs.application)
        }?.application
    }

    private func bestMatch(_ matches: [InstalledApp]) -> InstalledApp? {
        matches.min { isPreferred($0, over: $1) }
    }

    private func isPreferred(
        _ lhs: InstalledApp,
        over rhs: InstalledApp
    ) -> Bool {
        if lhs.displayName.count != rhs.displayName.count {
            return lhs.displayName.count < rhs.displayName.count
        }

        let nameComparison = lhs.displayName.localizedCaseInsensitiveCompare(
            rhs.displayName
        )
        if nameComparison != .orderedSame {
            return nameComparison == .orderedAscending
        }

        return lhs.url.path < rhs.url.path
    }

    private func tokens(in value: String) -> [String] {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .split { character in
                !character.isLetter && !character.isNumber
            }
            .map(String.init)
    }

    private func normalizedForDistance(_ value: String) -> String {
        tokens(in: value).joined(separator: " ")
    }

    private func maximumDistance(for queryLength: Int) -> Int {
        switch queryLength {
        case ...4:
            1
        case 5...8:
            2
        default:
            3
        }
    }

    private func levenshteinDistance(
        between lhs: String,
        and rhs: String
    ) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)

        guard !left.isEmpty else {
            return right.count
        }
        guard !right.isEmpty else {
            return left.count
        }

        var previous = Array(0...right.count)
        var current = Array(repeating: 0, count: right.count + 1)

        for (leftIndex, leftCharacter) in left.enumerated() {
            current[0] = leftIndex + 1

            for (rightIndex, rightCharacter) in right.enumerated() {
                let insertion = current[rightIndex] + 1
                let deletion = previous[rightIndex + 1] + 1
                let substitution = previous[rightIndex]
                    + (leftCharacter == rightCharacter ? 0 : 1)

                current[rightIndex + 1] = min(
                    insertion,
                    deletion,
                    substitution
                )
            }

            swap(&previous, &current)
        }

        return previous[right.count]
    }
}
