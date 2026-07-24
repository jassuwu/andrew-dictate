import XCTest

@MainActor
final class AppSettingsTests: XCTestCase {
    func testDefaultsToColdCaptureAndExistingHotkeyDefaults() {
        let (userDefaults, suiteName) = makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(
            userDefaults: userDefaults,
            detectedAgents: [detectedAgent(.codex)]
        )

        XCTAssertFalse(settings.onboardingCompleted)
        XCTAssertFalse(settings.preRollEnabled)
        XCTAssertEqual(settings.dictationHotkey, .dictation)
        XCTAssertEqual(settings.commandHotkey, .command)
        XCTAssertEqual(settings.engineVersion, .v2)
        XCTAssertEqual(
            settings.agentCommandTemplate,
            "codex exec {prompt}"
        )
        XCTAssertEqual(settings.terminalBundleID, "com.apple.Terminal")
        XCTAssertEqual(settings.totalWordsDictated, 0)
    }

    func testChangesPersistAcrossSettingsInstances() {
        let (userDefaults, suiteName) = makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(
            userDefaults: userDefaults,
            detectedAgents: [detectedAgent(.codex)]
        )
        settings.onboardingCompleted = true
        settings.preRollEnabled = true
        settings.setHotkeyBinding(.leftCommand, for: .dictation)
        settings.setHotkeyBinding(.rightControl, for: .command)
        settings.engineVersion = .v3
        settings.agentCommandTemplate = "claude -p {prompt}"
        settings.terminalBundleID = "com.mitchellh.ghostty"
        settings.recordDictatedTranscript("two dictated words")

        let reloaded = AppSettings(userDefaults: userDefaults)

        XCTAssertTrue(reloaded.onboardingCompleted)
        XCTAssertTrue(reloaded.preRollEnabled)
        XCTAssertEqual(reloaded.dictationHotkey, .leftCommand)
        XCTAssertEqual(reloaded.commandHotkey, .rightControl)
        XCTAssertEqual(reloaded.engineVersion, .v3)
        XCTAssertEqual(
            reloaded.agentCommandTemplate,
            "claude -p {prompt}"
        )
        XCTAssertEqual(
            reloaded.terminalBundleID,
            "com.mitchellh.ghostty"
        )
        XCTAssertEqual(reloaded.totalWordsDictated, 3)
    }

    func testRejectsDuplicateHotkeyAndInvalidAgentTemplate() {
        let (userDefaults, suiteName) = makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(
            userDefaults: userDefaults,
            detectedAgents: [detectedAgent(.codex)]
        )

        XCTAssertFalse(
            settings.setHotkeyBinding(.command, for: .dictation)
        )
        XCTAssertEqual(settings.dictationHotkey, .dictation)

        settings.agentCommandTemplate = "codex exec without a placeholder"
        XCTAssertEqual(
            settings.agentCommandTemplate,
            "codex exec {prompt}"
        )
    }

    func testEmptyAgentTemplatePersistsAsNoConfiguration() {
        let (userDefaults, suiteName) = makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(
            userDefaults: userDefaults,
            detectedAgents: [detectedAgent(.codex)]
        )
        settings.agentCommandTemplate = ""

        let reloaded = AppSettings(
            userDefaults: userDefaults,
            detectedAgents: [detectedAgent(.codex)]
        )
        XCTAssertEqual(reloaded.agentCommandTemplate, "")
    }

    func testNoDetectedAgentDefaultsToNoneOnlyOnFirstRun() {
        let (userDefaults, suiteName) = makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(
            userDefaults: userDefaults,
            detectedAgents: []
        )
        XCTAssertEqual(settings.agentCommandTemplate, "")

        let reloaded = AppSettings(
            userDefaults: userDefaults,
            detectedAgents: [detectedAgent(.codex)]
        )
        XCTAssertEqual(reloaded.agentCommandTemplate, "")
    }

    func testCodexRemainsRecommendedAmongDetectedAgents() {
        let (userDefaults, suiteName) = makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(
            userDefaults: userDefaults,
            detectedAgents: [
                detectedAgent(.claude),
                detectedAgent(.codex),
            ]
        )

        XCTAssertEqual(
            settings.agentCommandTemplate,
            AgentCLI.codex.commandTemplate
        )
    }

    func testInvalidStoredTemplateMigratesToNone() {
        let (userDefaults, suiteName) = makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        userDefaults.set(
            #"codex exec "{prompt}""#,
            forKey: "AndrewDictate.agentCommandTemplate"
        )

        let settings = AppSettings(
            userDefaults: userDefaults,
            detectedAgents: [detectedAgent(.codex)]
        )

        XCTAssertEqual(settings.agentCommandTemplate, "")
    }

    func testActiveEngineVersionCannotBeRemoved() {
        XCTAssertFalse(
            ModelRemovalPolicy.allowsRemoval(
                of: .v2,
                activeVersion: .v2
            )
        )
        XCTAssertTrue(
            ModelRemovalPolicy.allowsRemoval(
                of: .v3,
                activeVersion: .v2
            )
        )
    }

    func testDictatedWordCountSplitsWhitespaceAndNewlines() {
        XCTAssertEqual(
            dictatedWordCount(in: "one  two\nthree\tfour"),
            4
        )
    }

    func testDictatedWordCountReturnsZeroForEmptyText() {
        XCTAssertEqual(dictatedWordCount(in: ""), 0)
        XCTAssertEqual(dictatedWordCount(in: " \n\t"), 0)
    }

    func testDictatedWordCountTreatsPunctuationAsAWord() {
        XCTAssertEqual(dictatedWordCount(in: "...?!"), 1)
    }

    private func makeUserDefaults() -> (UserDefaults, String) {
        let suiteName = "AndrewDictateTests.AppSettings.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
        return (userDefaults, suiteName)
    }

    private func detectedAgent(_ cli: AgentCLI) -> DetectedAgentCLI {
        DetectedAgentCLI(
            cli: cli,
            executableURL: URL(fileURLWithPath: "/usr/local/bin/\(cli.rawValue)")
        )
    }
}
