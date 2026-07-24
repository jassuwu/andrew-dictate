import Foundation

extension URL {
    var isHTTPOrHTTPS: Bool {
        guard let scheme = scheme?.lowercased() else {
            return false
        }
        return scheme == "http" || scheme == "https"
    }
}

enum RoutedCommand: Equatable {
    case custom(action: CustomAction, capturedArgument: String?)
    case openApp(query: String)
    case switchToApp(query: String)
    case quitApp(query: String)
    case goTo(urlString: String)
    case typeLiteral(text: String)
    case template(url: URL, label: String)
    case delegate(prompt: String)
    case ask(prompt: String)
    case screenAsk(prompt: String, scope: ScreenAskScope)
}

enum ScreenAskScope: Equatable, Sendable {
    case frontWindow
    case activeDisplay
}

struct CommandRouter {
    private struct SiteTemplate {
        let baseURLString: String
        let queryItemName: String
    }

    static let imperativeLeadingTokens: Set<String> = [
        "add",
        "brew",
        "build",
        "bun",
        "cargo",
        "checkout",
        "commit",
        "configure",
        "copy",
        "create",
        "debug",
        "delete",
        "deploy",
        "docker",
        "edit",
        "execute",
        "fix",
        "format",
        "git",
        "go",
        "install",
        "kill",
        "launch",
        "lint",
        "make",
        "merge",
        "move",
        "npm",
        "open",
        "pnpm",
        "publish",
        "pull",
        "push",
        "quit",
        "rebuild",
        "refactor",
        "remove",
        "rename",
        "restart",
        "run",
        "set",
        "ship",
        "start",
        "stop",
        "switch",
        "test",
        "type",
        "uninstall",
        "update",
        "upgrade",
        "write",
        "yarn",
    ]

    static let questionLeadingTokens: Set<String> = [
        "are",
        "can",
        "could",
        "does",
        "explain",
        "how",
        "is",
        "summarize",
        "tell",
        "what",
        "when",
        "where",
        "which",
        "who",
        "why",
        "would",
    ]

    static let frontWindowScreenCues: [[String]] = [
        ["this"],
        ["this", "error"],
        ["this", "page"],
        ["this", "window"],
        ["here"],
    ]

    static let activeDisplayScreenCues: [[String]] = [
        ["my", "screen"],
        ["the", "screen"],
        ["everything"],
        ["this", "display"],
    ]

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

    func route(
        _ transcript: String,
        customActions: [CustomAction] = []
    ) -> RoutedCommand {
        if let match = CustomActionMatcher.match(
            transcript,
            actions: customActions
        ) {
            return .custom(
                action: match.action,
                capturedArgument: match.capturedArgument
            )
        }

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
            if let scheme = urlScheme(in: destination) {
                guard scheme.caseInsensitiveCompare("http") == .orderedSame
                        || scheme.caseInsensitiveCompare("https")
                            == .orderedSame else {
                    return .delegate(prompt: transcript)
                }
                return .goTo(urlString: destination)
            }
            if looksLikeURL(destination) {
                return .goTo(urlString: "https://\(destination)")
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

        if let scope = Self.screenAskScope(in: transcript) {
            return .screenAsk(prompt: transcript, scope: scope)
        }

        if Self.isQuestionShape(transcript) {
            return .ask(prompt: transcript)
        }

        if Self.isImperativeShape(transcript) {
            return .delegate(prompt: transcript)
        }

        return .ask(prompt: transcript)
    }

    static func isImperativeShape(_ transcript: String) -> Bool {
        guard let token = normalizedLeadingToken(in: transcript) else {
            return false
        }
        return imperativeLeadingTokens.contains(token)
    }

    static func isQuestionShape(_ transcript: String) -> Bool {
        guard let token = normalizedLeadingToken(in: transcript) else {
            return false
        }
        return questionLeadingTokens.contains(token)
    }

    static func screenAskScope(
        in transcript: String
    ) -> ScreenAskScope? {
        let tokens = normalizedTokens(in: transcript)

        // A display cue is more specific than the overlapping "this" window
        // cue, so display always wins when both are present.
        if activeDisplayScreenCues.contains(where: {
            tokens.containsPhrase($0)
        }) {
            return .activeDisplay
        }
        if frontWindowScreenCues.contains(where: {
            tokens.containsPhrase($0)
        }) {
            return .frontWindow
        }
        return nil
    }

    private static func normalizedLeadingToken(
        in transcript: String
    ) -> String? {
        guard let rawToken = transcript
            .split(whereSeparator: \.isWhitespace)
            .first else {
            return nil
        }

        let token = rawToken
            .drop(while: { !$0.isLetter && !$0.isNumber })
            .reversed()
            .drop(while: { !$0.isLetter && !$0.isNumber })
            .reversed()
        guard !token.isEmpty else {
            return nil
        }
        return String(token).lowercased()
    }

    private static func normalizedTokens(
        in transcript: String
    ) -> [String] {
        transcript
            .split {
                !$0.isLetter && !$0.isNumber
            }
            .map { $0.lowercased() }
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
        value.contains(".")
    }

    private func urlScheme(in value: String) -> String? {
        guard let colonIndex = value.firstIndex(of: ":"),
              colonIndex > value.startIndex else {
            return nil
        }

        let scheme = value[..<colonIndex]
        guard let first = scheme.first, first.isLetter else {
            return nil
        }

        guard scheme.dropFirst().allSatisfy({
            $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "."
        }) else {
            return nil
        }
        return String(scheme)
    }
}

private extension Array where Element == String {
    func containsPhrase(_ phrase: [String]) -> Bool {
        guard !phrase.isEmpty, phrase.count <= count else {
            return false
        }

        return indices.contains { startIndex in
            let endIndex = startIndex + phrase.count
            guard endIndex <= count else {
                return false
            }
            return Array(self[startIndex..<endIndex]) == phrase
        }
    }
}
