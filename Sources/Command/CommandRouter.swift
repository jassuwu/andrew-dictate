import Foundation

enum RoutedCommand: Equatable {
    case openApp(query: String)
    case switchToApp(query: String)
    case quitApp(query: String)
    case goTo(urlString: String)
    case typeLiteral(text: String)
    case template(url: URL, label: String)
    case delegate(prompt: String)
}

struct CommandRouter {
    private struct SiteTemplate {
        let baseURLString: String
        let queryItemName: String
    }

    private static let siteTemplates: [String: SiteTemplate] = [
        "chatgpt": SiteTemplate(
            baseURLString: "https://chatgpt.com/",
            queryItemName: "q"
        ),
        "claude": SiteTemplate(
            baseURLString: "https://claude.ai/new",
            queryItemName: "q"
        ),
        "perplexity": SiteTemplate(
            baseURLString: "https://www.perplexity.ai/search",
            queryItemName: "q"
        ),
        "google": SiteTemplate(
            baseURLString: "https://www.google.com/search",
            queryItemName: "q"
        ),
        "youtube": SiteTemplate(
            baseURLString: "https://www.youtube.com/results",
            queryItemName: "search_query"
        ),
    ]

    func route(_ transcript: String) -> RoutedCommand {
        if let query = remainder(after: ["open"], in: transcript) {
            return .openApp(query: query)
        }

        if let query = remainder(after: ["launch"], in: transcript) {
            return .openApp(query: query)
        }

        if let query = remainder(after: ["switch", "to"], in: transcript) {
            return .switchToApp(query: query)
        }

        if let query = remainder(after: ["quit"], in: transcript) {
            return .quitApp(query: query)
        }

        if let destination = remainder(after: ["go", "to"], in: transcript) {
            if looksLikeURL(destination) {
                return .goTo(urlString: normalizedURLString(destination))
            }
            return .switchToApp(query: destination)
        }

        if let text = remainder(
            after: ["type"],
            in: transcript,
            preservesTrailingWhitespace: true
        ) {
            return .typeLiteral(text: text)
        }

        if let command = routeTemplate(transcript) {
            return command
        }

        return .delegate(prompt: transcript)
    }

    private func routeTemplate(_ transcript: String) -> RoutedCommand? {
        guard let (siteName, rawQuery) = firstWordAndRemainder(transcript),
              let template = Self.siteTemplates[siteName.lowercased()] else {
            return nil
        }

        let query: String
        if let searchQuery = remainder(after: ["search"], in: rawQuery) {
            query = searchQuery
        } else if rawQuery.compare(
            "search",
            options: [.caseInsensitive],
            range: nil,
            locale: Locale(identifier: "en_US_POSIX")
        ) == .orderedSame {
            return nil
        } else {
            query = rawQuery
        }

        let unreservedCharacters = CharacterSet(
            charactersIn:
                "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
                + "abcdefghijklmnopqrstuvwxyz"
                + "0123456789-._~"
        )
        guard !query.isEmpty,
              let encodedQuery = query.addingPercentEncoding(
                  withAllowedCharacters: unreservedCharacters
              ),
              let url = URL(
                  string: template.baseURLString
                      + "?"
                      + template.queryItemName
                      + "="
                      + encodedQuery
              ) else {
            return nil
        }

        return .template(
            url: url,
            label: "\(siteName.lowercased()): \(query)"
        )
    }

    private func remainder(
        after expectedWords: [String],
        in text: String,
        preservesTrailingWhitespace: Bool = false
    ) -> String? {
        var index = text.startIndex
        skipWhitespace(in: text, index: &index)

        for (wordIndex, expectedWord) in expectedWords.enumerated() {
            let wordStart = index
            while index < text.endIndex, !text[index].isWhitespace {
                text.formIndex(after: &index)
            }

            guard wordStart < index else {
                return nil
            }

            let actualWord = String(text[wordStart..<index])
            guard actualWord.compare(
                expectedWord,
                options: [.caseInsensitive],
                range: nil,
                locale: Locale(identifier: "en_US_POSIX")
            ) == .orderedSame else {
                return nil
            }

            guard index < text.endIndex else {
                return nil
            }

            let whitespaceStart = index
            skipWhitespace(in: text, index: &index)
            guard whitespaceStart < index else {
                return nil
            }

            if wordIndex < expectedWords.count - 1,
               index == text.endIndex {
                return nil
            }
        }

        let rawRemainder = String(text[index...])
        let content = rawRemainder.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !content.isEmpty else {
            return nil
        }

        return preservesTrailingWhitespace ? rawRemainder : content
    }

    private func firstWordAndRemainder(
        _ text: String
    ) -> (word: String, remainder: String)? {
        var index = text.startIndex
        skipWhitespace(in: text, index: &index)

        let wordStart = index
        while index < text.endIndex, !text[index].isWhitespace {
            text.formIndex(after: &index)
        }

        guard wordStart < index, index < text.endIndex else {
            return nil
        }

        let word = String(text[wordStart..<index])
        skipWhitespace(in: text, index: &index)

        let remainder = String(text[index...]).trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !remainder.isEmpty else {
            return nil
        }

        return (word, remainder)
    }

    private func skipWhitespace(
        in text: String,
        index: inout String.Index
    ) {
        while index < text.endIndex, text[index].isWhitespace {
            text.formIndex(after: &index)
        }
    }

    private func looksLikeURL(_ value: String) -> Bool {
        value.contains(".") || hasScheme(value)
    }

    private func normalizedURLString(_ value: String) -> String {
        hasScheme(value) ? value : "https://\(value)"
    }

    private func hasScheme(_ value: String) -> Bool {
        guard let colonIndex = value.firstIndex(of: ":"),
              colonIndex > value.startIndex else {
            return false
        }

        let scheme = value[..<colonIndex]
        guard let first = scheme.first, first.isLetter else {
            return false
        }

        return scheme.dropFirst().allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "."
        }
    }
}
