import XCTest

@MainActor
final class AppSettingsTests: XCTestCase {
    func testDefaultsToColdCaptureAndExistingHotkeyDefaults() {
        let (userDefaults, suiteName) = makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(userDefaults: userDefaults)

        XCTAssertFalse(settings.onboardingDismissed)
        XCTAssertFalse(settings.preRollEnabled)
        XCTAssertTrue(settings.soundFeedbackEnabled)
        XCTAssertEqual(settings.dictationHotkey, .dictation)
        XCTAssertEqual(settings.engineVersion, .v2)
        XCTAssertEqual(settings.cleanupMode, .off)
        XCTAssertEqual(settings.totalWordsDictated, 0)
    }

    func testChangesPersistAcrossSettingsInstances() {
        let (userDefaults, suiteName) = makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(userDefaults: userDefaults)
        settings.onboardingDismissed = true
        settings.preRollEnabled = true
        settings.soundFeedbackEnabled = false
        XCTAssertTrue(settings.setHotkeyBinding(.leftCommand))
        settings.engineVersion = .v3
        settings.cleanupMode = .always
        settings.recordDictatedTranscript("two dictated words")

        let reloaded = AppSettings(userDefaults: userDefaults)

        XCTAssertTrue(reloaded.onboardingDismissed)
        XCTAssertTrue(reloaded.preRollEnabled)
        XCTAssertFalse(reloaded.soundFeedbackEnabled)
        XCTAssertEqual(reloaded.dictationHotkey, .leftCommand)
        XCTAssertEqual(reloaded.engineVersion, .v3)
        XCTAssertEqual(reloaded.cleanupMode, .always)
        XCTAssertEqual(reloaded.totalWordsDictated, 3)
    }

    func testRejectsUnsupportedHotkey() {
        let (userDefaults, suiteName) = makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(userDefaults: userDefaults)

        XCTAssertFalse(
            settings.setHotkeyBinding(
                HotkeyBinding(keyCode: 0, displayName: "unsupported")
            )
        )
        XCTAssertEqual(settings.dictationHotkey, .dictation)
    }

    func testHotkeyRebindKeepsExistingDictationPersistenceKey() throws {
        let (userDefaults, suiteName) = makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let key = "AndrewDictate.hotkey.dictation"
        userDefaults.set(
            try JSONEncoder().encode(HotkeyBinding.leftOption),
            forKey: key
        )

        let settings = AppSettings(userDefaults: userDefaults)
        XCTAssertEqual(settings.dictationHotkey, .leftOption)

        XCTAssertTrue(settings.setHotkeyBinding(.rightControl))
        let persistedData = try XCTUnwrap(userDefaults.data(forKey: key))
        XCTAssertEqual(
            try JSONDecoder().decode(
                HotkeyBinding.self,
                from: persistedData
            ),
            .rightControl
        )
    }

    func testCleanupModePersistsOnAndFallsBackToOffForUnknownValue() {
        let (userDefaults, suiteName) = makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(userDefaults: userDefaults)
        settings.cleanupMode = .on

        XCTAssertEqual(
            AppSettings(userDefaults: userDefaults).cleanupMode,
            .on
        )

        userDefaults.set(
            "future-mode",
            forKey: "AndrewDictate.cleanupMode"
        )
        XCTAssertEqual(
            AppSettings(userDefaults: userDefaults).cleanupMode,
            .off
        )
    }

    func testActiveEngineVersionCanBeRemovedAndRequiresRepreparation() {
        let activeDecision = ModelRemovalPolicy.decision(
            of: .v2,
            activeVersion: .v2
        )
        XCTAssertTrue(activeDecision.isAllowed)
        XCTAssertTrue(activeDecision.requiresRepreparation)

        let inactiveDecision = ModelRemovalPolicy.decision(
            of: .v3,
            activeVersion: .v2
        )
        XCTAssertTrue(inactiveDecision.isAllowed)
        XCTAssertFalse(inactiveDecision.requiresRepreparation)
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
}

extension AppSettingsTests {
    @MainActor
    func testShadowModeMigratesToOn() {
        let (userDefaults, suiteName) = makeUserDefaults()
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        userDefaults.set("shadow", forKey: "AndrewDictate.cleanupMode")
        let settings = AppSettings(userDefaults: userDefaults)
        XCTAssertEqual(settings.cleanupMode, CleanupMode.on)
    }

    /// ADR 0026. The pre-roll ruling went the other way and this deliberately
    /// does not follow it: pre-roll opens a microphone, this keeps text the
    /// app already produced and already pasted.
    func testKeepingDictationsIsOnUntilTurnedOff() {
        let defaults = UserDefaults(
            suiteName: "keep-\(UUID().uuidString)"
        )!
        XCTAssertTrue(AppSettings(userDefaults: defaults).keepDictations)
    }

    func testTurningKeepingOffSurvivesARelaunch() {
        let suite = "keep-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!

        let settings = AppSettings(userDefaults: defaults)
        settings.keepDictations = false

        XCTAssertFalse(AppSettings(userDefaults: defaults).keepDictations)
    }
}
