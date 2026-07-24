import Foundation

struct MessyGate {
    static let lengthThreshold = 24
    static let nonDictionaryDensityThreshold = 0.30

    private let tokenExpression = try! NSRegularExpression(
        pattern: "[\\p{L}\\p{N}_@/%+\\-]+(?:\\.[\\p{L}\\p{N}_@/%+\\-]+)*"
    )

    func shouldPolish(
        _ cleaned: String,
        rawHadCorrections: Bool,
        rawHadDuplicates: Bool,
        dictionaryTerms: [String] = []
    ) -> Bool {
        if rawHadCorrections || rawHadDuplicates {
            return true
        }

        let tokens = tokenExpression.matches(
            in: cleaned,
            range: cleaned.fullNSRange
        ).compactMap {
            cleaned.substring(with: $0.range)
        }
        if tokens.count > Self.lengthThreshold {
            return true
        }
        guard tokens.count >= 3 else {
            return false
        }

        let protectedTokens = Set(
            dictionaryTerms.flatMap {
                $0.lowercased().split {
                    !$0.isLetter && !$0.isNumber
                }
            }.map(String.init)
        )
        let unknownCount = tokens.lazy.filter {
            !isDictionaryLike($0, protectedTokens: protectedTokens)
        }.count
        let density = Double(unknownCount) / Double(tokens.count)
        return density > Self.nonDictionaryDensityThreshold
    }

    private func isDictionaryLike(
        _ token: String,
        protectedTokens: Set<String>
    ) -> Bool {
        let lowered = token.lowercased()
        if protectedTokens.contains(lowered)
            || token.allSatisfy(\.isNumber)
            || token.contains("@")
            || token.contains(".")
            || token.allSatisfy({ $0.isLetter && $0.isUppercase }) {
            return true
        }

        guard token.allSatisfy(\.isLetter) else {
            return false
        }
        if token.count <= 3 {
            return true
        }

        // This is intentionally a deterministic, lexicon-free proxy rather
        // than NSSpellChecker: vowel-less ASR fragments are "unknown", while
        // ordinary words and explicit dictionary terms stay local and stable
        // across OS versions and user language settings.
        return lowered.contains {
            "aeiouy".contains($0)
        }
    }
}
