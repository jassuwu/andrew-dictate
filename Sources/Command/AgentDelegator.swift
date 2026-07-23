import AppKit
import Foundation

func shellEscapeSingleQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

enum AgentDelegationError: Error, Equatable {
    case templateMissingPrompt
    case unableToOpenScript
}

extension AgentCommandTemplate {
    static func compose(
        _ template: String,
        prompt: String
    ) throws -> String {
        let parsed: Parsed
        do {
            parsed = try parse(template)
        } catch {
            throw AgentDelegationError.templateMissingPrompt
        }

        let arguments = parsed.arguments(replacingPromptWith: prompt)
        return "exec " + arguments
            .map(shellEscapeSingleQuoted)
            .joined(separator: " ")
    }

    static func commandPreview(
        template: String,
        prompt: String
    ) -> String {
        let commandName = (try? parse(template))?
            .arguments
            .first?
            .split(separator: "/")
            .last
            .map(String.init)

        return "→ \(commandName ?? "agent"): \(prompt)"
    }
}

@MainActor
final class AgentDelegator {
    private static let scriptLifetime: TimeInterval = 60 * 60

    private let settings: AppSettings
    private let fileManager: FileManager
    private let workspace: NSWorkspace
    private let runDirectory: URL

    init(
        settings: AppSettings,
        fileManager: FileManager = .default,
        workspace: NSWorkspace = .shared,
        runDirectory: URL? = nil
    ) {
        self.settings = settings
        self.fileManager = fileManager
        self.workspace = workspace
        self.runDirectory = runDirectory
            ?? fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first?
                .appendingPathComponent("Andrew Dictate", isDirectory: true)
                .appendingPathComponent("run", isDirectory: true)
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    "Library/Application Support/Andrew Dictate/run",
                    isDirectory: true
                )

        prepareRunDirectoryForCleanup()
        cleanupExpiredScripts()
    }

    func launch(prompt: String) async throws {
        let commandLine = try AgentCommandTemplate.compose(
            settings.agentCommandTemplate,
            prompt: prompt
        )
        let scriptURL = try writeScript(commandLine: commandLine)

        if let terminalURL = terminalApplicationURL() {
            _ = try await workspace.open(
                [scriptURL],
                withApplicationAt: terminalURL,
                configuration: NSWorkspace.OpenConfiguration()
            )
        } else if !workspace.open(scriptURL) {
            throw AgentDelegationError.unableToOpenScript
        }

        cleanupExpiredScripts()
    }

    private func writeScript(commandLine: String) throws -> URL {
        try prepareRunDirectory()

        let timestamp = Int(Date().timeIntervalSince1970 * 1_000)
        let scriptURL = runDirectory.appendingPathComponent(
            "agent-\(timestamp).command",
            isDirectory: false
        )
        let script = Self.scriptContents(commandLine: commandLine)

        try Data(script.utf8).write(to: scriptURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: scriptURL.path
        )
        return scriptURL
    }

    static func scriptContents(commandLine: String) -> String {
        "#!/bin/zsh\nrm -- \"$0\"\n\(commandLine)\n"
    }

    private func prepareRunDirectory() throws {
        try fileManager.createDirectory(
            at: runDirectory,
            withIntermediateDirectories: true
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: runDirectory.path
        )
    }

    private func prepareRunDirectoryForCleanup() {
        do {
            try prepareRunDirectory()
        } catch {
            print(
                "agent run directory preparation failed: "
                    + error.localizedDescription
            )
        }
    }

    private func terminalApplicationURL() -> URL? {
        let configuredBundleID = settings.terminalBundleID
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let preferredBundleID = configuredBundleID.isEmpty
            ? AppSettings.defaultTerminalBundleID
            : configuredBundleID
        let bundleIDs = [
            preferredBundleID,
            AppSettings.defaultTerminalBundleID,
        ]

        var visited: Set<String> = []
        for bundleID in bundleIDs where visited.insert(bundleID).inserted {
            if let applicationURL = workspace.urlForApplication(
                withBundleIdentifier: bundleID
            ) {
                return applicationURL
            }
        }
        return nil
    }

    private func cleanupExpiredScripts(now: Date = Date()) {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: runDirectory,
            includingPropertiesForKeys: [
                .contentModificationDateKey,
                .isRegularFileKey,
            ],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for url in urls {
            guard url.pathExtension == "command",
                  let values = try? url.resourceValues(
                      forKeys: [
                          .contentModificationDateKey,
                          .isRegularFileKey,
                      ]
                  ),
                  values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate,
                  now.timeIntervalSince(modifiedAt) > Self.scriptLifetime else {
                continue
            }

            do {
                try fileManager.removeItem(at: url)
            } catch {
                print(
                    "agent script cleanup skipped \(url.lastPathComponent): "
                        + error.localizedDescription
                )
            }
        }
    }
}
