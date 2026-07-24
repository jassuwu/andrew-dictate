import Foundation

enum AgentCLI: String, CaseIterable, Identifiable, Sendable {
    case codex
    case claude
    case opencode

    var id: Self {
        self
    }

    var commandTemplate: String {
        switch self {
        case .codex:
            "codex exec --skip-git-repo-check {prompt}"
        case .claude:
            "claude -p {prompt}"
        case .opencode:
            "opencode run {prompt}"
        }
    }
}

enum AgentCommandTemplate {
    static let promptPlaceholder = "{prompt}"

    struct Parsed: Equatable, Sendable {
        let arguments: [String]
        let promptArgumentIndex: Int

        func arguments(replacingPromptWith prompt: String) -> [String] {
            var result = arguments
            result[promptArgumentIndex] = prompt
            return result
        }
    }

    enum ValidationError: Error, Equatable {
        case promptMustBeStandaloneWord
        case invalidShellQuoting
    }

    static func isValid(_ template: String) -> Bool {
        (try? parse(template)) != nil
    }

    static func parse(_ template: String) throws -> Parsed {
        let placeholderCount = template
            .components(separatedBy: promptPlaceholder)
            .count - 1
        guard placeholderCount == 1 else {
            throw ValidationError.promptMustBeStandaloneWord
        }

        let tokens = try lexicalTokens(template)
        let promptIndices = tokens.indices.filter {
            tokens[$0].value == promptPlaceholder
                && !tokens[$0].usedQuotingOrEscaping
        }
        guard promptIndices.count == 1,
              let promptArgumentIndex = promptIndices.first,
              promptArgumentIndex > 0 else {
            throw ValidationError.promptMustBeStandaloneWord
        }

        return Parsed(
            arguments: tokens.map(\.value),
            promptArgumentIndex: promptArgumentIndex
        )
    }

    static func tokenize(_ template: String) throws -> [String] {
        try lexicalTokens(template).map(\.value)
    }

    private struct LexicalToken {
        var value: String
        var usedQuotingOrEscaping: Bool
    }

    private enum Quote {
        case single
        case double
    }

    private static func lexicalTokens(
        _ template: String
    ) throws -> [LexicalToken] {
        var tokens: [LexicalToken] = []
        var value = ""
        var tokenStarted = false
        var usedQuotingOrEscaping = false
        var quote: Quote?
        var index = template.startIndex

        func appendToken() {
            tokens.append(
                LexicalToken(
                    value: value,
                    usedQuotingOrEscaping: usedQuotingOrEscaping
                )
            )
            value = ""
            tokenStarted = false
            usedQuotingOrEscaping = false
        }

        while index < template.endIndex {
            let character = template[index]

            if quote == .single {
                if character == "'" {
                    quote = nil
                } else {
                    value.append(character)
                }
                template.formIndex(after: &index)
                continue
            }

            if character == "\\" {
                let nextIndex = template.index(after: index)
                guard nextIndex < template.endIndex else {
                    throw ValidationError.invalidShellQuoting
                }

                let escapedCharacter = template[nextIndex]
                tokenStarted = true
                usedQuotingOrEscaping = true

                if quote == .double,
                   escapedCharacter != "$",
                   escapedCharacter != "`",
                   escapedCharacter != "\"",
                   escapedCharacter != "\\",
                   !escapedCharacter.isNewline {
                    value.append("\\")
                }
                if !escapedCharacter.isNewline {
                    value.append(escapedCharacter)
                }
                index = template.index(after: nextIndex)
                continue
            }

            if quote == .double {
                if character == "\"" {
                    quote = nil
                } else {
                    value.append(character)
                }
                template.formIndex(after: &index)
                continue
            }

            if character.isWhitespace {
                if tokenStarted {
                    appendToken()
                }
                template.formIndex(after: &index)
                continue
            }

            if character == "'" {
                tokenStarted = true
                usedQuotingOrEscaping = true
                quote = .single
                template.formIndex(after: &index)
                continue
            }

            if character == "\"" {
                tokenStarted = true
                usedQuotingOrEscaping = true
                quote = .double
                template.formIndex(after: &index)
                continue
            }

            tokenStarted = true
            value.append(character)
            template.formIndex(after: &index)
        }

        guard quote == nil else {
            throw ValidationError.invalidShellQuoting
        }
        if tokenStarted {
            appendToken()
        }
        return tokens
    }
}

struct DetectedAgentCLI: Identifiable, Equatable, Sendable {
    let cli: AgentCLI
    let executableURL: URL

    var id: AgentCLI {
        cli
    }
}

enum AgentCLIDetector {
    static func detect(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [DetectedAgentCLI] {
        let nvmVersions = nvmNodeVersions(
            fileManager: fileManager,
            homeDirectory: homeDirectory
        )

        return AgentCLI.allCases.compactMap { cli in
            let candidates = candidatePaths(
                for: cli,
                homeDirectory: homeDirectory,
                nvmNodeVersions: nvmVersions,
                pathFromWhich: pathFromWhich(for: cli)
            )
            guard let executableURL = candidates.first(where: {
                fileManager.isExecutableFile(atPath: $0.path)
            }) else {
                return nil
            }
            return DetectedAgentCLI(
                cli: cli,
                executableURL: executableURL
            )
        }
    }

    static func candidatePaths(
        for cli: AgentCLI,
        homeDirectory: URL,
        nvmNodeVersions: [String],
        pathFromWhich: URL?
    ) -> [URL] {
        let executable = cli.rawValue
        var paths = [
            homeDirectory.appendingPathComponent(".local/bin/\(executable)"),
            homeDirectory.appendingPathComponent(
                ".npm-global/bin/\(executable)"
            ),
            homeDirectory.appendingPathComponent(".bun/bin/\(executable)"),
            homeDirectory.appendingPathComponent(".volta/bin/\(executable)"),
            homeDirectory.appendingPathComponent(
                ".local/share/pnpm/\(executable)"
            ),
            homeDirectory.appendingPathComponent(
                "Library/pnpm/\(executable)"
            ),
            URL(fileURLWithPath: "/opt/homebrew/bin/\(executable)"),
            URL(fileURLWithPath: "/usr/local/bin/\(executable)"),
        ]

        paths.append(contentsOf: nvmNodeVersions.sorted().map {
            homeDirectory.appendingPathComponent(
                ".nvm/versions/node/\($0)/bin/\(executable)"
            )
        })

        if let pathFromWhich {
            paths.append(pathFromWhich)
        }

        var seenPaths: Set<String> = []
        return paths.filter {
            seenPaths.insert($0.standardizedFileURL.path).inserted
        }
    }

    private static func nvmNodeVersions(
        fileManager: FileManager,
        homeDirectory: URL
    ) -> [String] {
        let versionsURL = homeDirectory.appendingPathComponent(
            ".nvm/versions/node",
            isDirectory: true
        )
        return (try? fileManager.contentsOfDirectory(
            atPath: versionsURL.path
        )) ?? []
    }

    private static func pathFromWhich(for cli: AgentCLI) -> URL? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", cli.rawValue]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8),
              let firstLine = text.split(whereSeparator: \.isNewline).first else {
            return nil
        }

        return URL(fileURLWithPath: String(firstLine))
    }
}
