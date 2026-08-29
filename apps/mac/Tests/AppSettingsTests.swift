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
        settings.recordDictatedTranscript("two dictated words")

        let reloaded = AppSettings(userDefaults: userDefaults)

        XCTAssertTrue(reloaded.onboardingDismissed)
        XCTAssertTrue(reloaded.preRollEnabled)
        XCTAssertFalse(reloaded.soundFeedbackEnabled)
        XCTAssertEqual(reloaded.dictationHotkey, .leftCommand)
        XCTAssertEqual(reloaded.engineVersion, .v3)
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

    func testMeetingsDefaultToWhisperLargeInDocumentsWithNoHook() {
        let (userDefaults, suiteName) = makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(userDefaults: userDefaults)

        XCTAssertEqual(settings.meetingModel, .whisperLargeV3)
        XCTAssertEqual(
            settings.meetingsFolder,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent("andrew-dictate", isDirectory: true)
        )
        XCTAssertNil(settings.meetingHook)
        XCTAssertNil(settings.meetingHookLastRunAt)
        XCTAssertNil(settings.meetingHookLastRunLabel)
    }

    func testMeetingChoicesSurviveARelaunch() {
        let (userDefaults, suiteName) = makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let folder = URL(fileURLWithPath: "/tmp/meetings", isDirectory: true)
        let hook = URL(fileURLWithPath: "/usr/local/bin/on-meeting")
        let ranAt = Date(timeIntervalSince1970: 1_756_000_000)

        let settings = AppSettings(userDefaults: userDefaults)
        settings.meetingModel = .whisperLargeV3Turbo
        settings.meetingsFolder = folder
        settings.meetingHook = hook
        settings.meetingHookLastRunAt = ranAt
        settings.meetingHookLastRunLabel = "exit 3"

        let reloaded = AppSettings(userDefaults: userDefaults)

        XCTAssertEqual(reloaded.meetingModel, .whisperLargeV3Turbo)
        XCTAssertEqual(reloaded.meetingsFolder, folder)
        XCTAssertEqual(reloaded.meetingHook, hook)
        XCTAssertEqual(reloaded.meetingHookLastRunAt, ranAt)
        XCTAssertEqual(reloaded.meetingHookLastRunLabel, "exit 3")
    }

    /// clearing the hook has to erase the stored path, not leave the old
    /// one behind for the next launch to resurrect.
    func testClearingTheHookForgetsIt() {
        let (userDefaults, suiteName) = makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(userDefaults: userDefaults)
        settings.meetingHook = URL(fileURLWithPath: "/usr/bin/true")
        settings.meetingHook = nil

        XCTAssertNil(AppSettings(userDefaults: userDefaults).meetingHook)
    }

    func testUnknownMeetingModelFallsBackToWhisperLarge() {
        let (userDefaults, suiteName) = makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        userDefaults.set(
            "future-model",
            forKey: "AndrewDictate.meetingModel"
        )

        XCTAssertEqual(
            AppSettings(userDefaults: userDefaults).meetingModel,
            .whisperLargeV3
        )
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
