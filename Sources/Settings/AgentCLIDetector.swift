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
            "codex exec {prompt}"
        case .claude:
            "claude -p {prompt}"
        case .opencode:
            "opencode run {prompt}"
        }
    }
}

enum AgentCommandTemplate {
    static let promptPlaceholder = "{prompt}"

    static func isValid(_ template: String) -> Bool {
        template.contains(promptPlaceholder)
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
