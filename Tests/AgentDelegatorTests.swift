import XCTest

@MainActor
final class AgentDelegatorTests: XCTestCase {
    func testShellEscapeSingleQuotedEscapesQuotes() {
        XCTAssertEqual(
            shellEscapeSingleQuoted("it's Andrew's"),
            "'it'\\''s Andrew'\\''s'"
        )
    }

    func testShellEscapeSingleQuotedPreservesBackslashes() {
        XCTAssertEqual(
            shellEscapeSingleQuoted(#"C:\Users\andrew"#),
            #"'C:\Users\andrew'"#
        )
    }

    func testShellEscapeSingleQuotedPreservesNewlines() {
        XCTAssertEqual(
            shellEscapeSingleQuoted("first\nsecond"),
            "'first\nsecond'"
        )
    }

    func testShellEscapeSingleQuotedPreservesUnicode() {
        XCTAssertEqual(
            shellEscapeSingleQuoted("नमस्ते 👋"),
            "'नमस्ते 👋'"
        )
    }

    func testShellEscapeSingleQuotedHandlesEmptyPrompt() {
        XCTAssertEqual(shellEscapeSingleQuoted(""), "''")
    }

    func testTemplateCompositionEscapesEveryArgument() throws {
        XCTAssertEqual(
            try AgentCommandTemplate.compose(
                #"codex exec --model "gpt 5" {prompt}"#,
                prompt: "it's ready"
            ),
            "exec 'codex' 'exec' '--model' 'gpt 5' "
                + "'it'\\''s ready'"
        )
    }

    func testInjectionAttemptIsOneLiteralArgument() throws {
        let markerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AndrewDictateInjection-\(UUID().uuidString)"
            )
        let prompt = "$(/usr/bin/touch \(markerURL.path))"
        let command = try AgentCommandTemplate.compose(
            "/usr/bin/printf %s {prompt}",
            prompt: prompt
        )
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.standardOutput = output
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(String(decoding: data, as: UTF8.self), prompt)
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: markerURL.path)
        )
    }

    func testTemplateCompositionRejectsMissingPromptPlaceholder() {
        XCTAssertFalse(
            AgentCommandTemplate.isValid("codex exec without placeholder")
        )
        XCTAssertThrowsError(
            try AgentCommandTemplate.compose(
                "codex exec without placeholder",
                prompt: "hello"
            )
        ) { error in
            XCTAssertEqual(
                error as? AgentDelegationError,
                .templateMissingPrompt
            )
        }
    }

    func testScriptDeletesItselfBeforeExecutingCommand() {
        XCTAssertEqual(
            AgentDelegator.scriptContents(
                commandLine: "exec 'codex' 'exec' 'hello'"
            ),
            "#!/bin/zsh\n"
                + "rm -- \"$0\"\n"
                + "cd \"$HOME\"\n"
                + "exec 'codex' 'exec' 'hello'\n"
        )
    }

    func testDelegatorCreatesPrivateRunDirectory() throws {
        let parentURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AndrewDictateRunDirectory-\(UUID().uuidString)",
                isDirectory: true
            )
        let runURL = parentURL.appendingPathComponent(
            "run",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: parentURL) }

        let (userDefaults, suiteName) = makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(
            userDefaults: userDefaults,
            detectedAgents: []
        )
        _ = AgentDelegator(
            settings: settings,
            runDirectory: runURL
        )

        let attributes = try FileManager.default.attributesOfItem(
            atPath: runURL.path
        )
        let permissions = try XCTUnwrap(
            attributes[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(permissions.intValue & 0o777, 0o700)
    }

    private func makeUserDefaults() -> (UserDefaults, String) {
        let suiteName =
            "AndrewDictateTests.AgentDelegator.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
        return (userDefaults, suiteName)
    }
}
