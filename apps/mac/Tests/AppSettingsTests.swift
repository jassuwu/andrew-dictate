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
        XCTAssertEqual(settings.dictationModel, .parakeetV2)
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
        settings.dictationModel = .parakeetV3
        settings.recordDictatedTranscript("two dictated words")

        let reloaded = AppSettings(userDefaults: userDefaults)

        XCTAssertTrue(reloaded.onboardingDismissed)
        XCTAssertTrue(reloaded.preRollEnabled)
        XCTAssertFalse(reloaded.soundFeedbackEnabled)
        XCTAssertEqual(reloaded.dictationHotkey, .leftCommand)
        XCTAssertEqual(reloaded.dictationModel, .parakeetV3)
        XCTAssertEqual(reloaded.totalWordsDictated, 3)
    }

    /// before dictation could pick whisper, its two choices were stored as
    /// "v2" and "v3": an update keeps the pick it finds.
    func testADictationModelStoredByAnOlderBuildIsStillThePick() {
        let (userDefaults, suiteName) = makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        userDefaults.set("v3", forKey: "AndrewDictate.engineVersion")
        XCTAssertEqual(AppSettings(userDefaults: userDefaults).dictationModel, .parakeetV3)

        userDefaults.set("v2", forKey: "AndrewDictate.engineVersion")
        XCTAssertEqual(AppSettings(userDefaults: userDefaults).dictationModel, .parakeetV2)

        userDefaults.set("whisperLargeV3Turbo", forKey: "AndrewDictate.engineVersion")
        XCTAssertEqual(AppSettings(userDefaults: userDefaults).dictationModel, .whisperLargeV3Turbo)
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
            of: .parakeetV2,
            activeVersion: .parakeetV2
        )
        XCTAssertTrue(activeDecision.isAllowed)
        XCTAssertTrue(activeDecision.requiresRepreparation)

        let inactiveDecision = ModelRemovalPolicy.decision(
            of: .parakeetV3,
            activeVersion: .parakeetV2
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

    func testMeetingsDefaultToWhisperLargeOutsideDocumentsWithNoHook() {
        let (userDefaults, suiteName) = makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(
            userDefaults: userDefaults,
            unpickedMeetingsFolder: AppSettings.defaultMeetingsFolder
        )

        XCTAssertEqual(settings.meetingModel, .whisperLargeV3)
        XCTAssertEqual(
            settings.meetingsFolder,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("andrew-dictate", isDirectory: true)
        )
        XCTAssertFalse(settings.meetingsFolder.pathComponents.contains("Documents"))
        XCTAssertNil(settings.meetingHook)
        XCTAssertNil(settings.meetingHookLastRunAt)
        XCTAssertNil(settings.meetingHookLastRunLabel)
    }

    func testAnInstallThatAlreadyWroteUnderDocumentsKeepsItsFolder() throws {
        let home = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        ).appendingPathComponent(UUID().uuidString, isDirectory: true)
        let legacy = home
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("andrew-dictate", isDirectory: true)
        let fallback = home
            .appendingPathComponent("andrew-dictate", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        XCTAssertEqual(
            AppSettings.unpickedMeetingsFolder(legacy: legacy, fallback: fallback),
            fallback
        )

        try FileManager.default.createDirectory(
            at: legacy.appendingPathComponent("meetings", isDirectory: true),
            withIntermediateDirectories: true
        )

        XCTAssertEqual(
            AppSettings.unpickedMeetingsFolder(legacy: legacy, fallback: fallback),
            legacy
        )
    }

    /// the old folder is written down the first time it is resolved, so a
    /// later change of default cannot move anyone's transcripts again.
    func testTheOldFolderIsPinnedIntoDefaults() {
        let (userDefaults, suiteName) = makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let legacy = URL(fileURLWithPath: "/tmp/andrew-legacy", isDirectory: true)

        let settings = AppSettings(
            userDefaults: userDefaults,
            unpickedMeetingsFolder: legacy
        )

        XCTAssertEqual(settings.meetingsFolder, legacy)
        XCTAssertEqual(
            userDefaults.string(forKey: "AndrewDictate.meetingsFolder"),
            legacy.path(percentEncoded: false)
        )
    }

    /// the default is where meetings would go, not a choice anybody made;
    /// a pick, or the old folder pinned, is.
    func testOnlyAChosenOrPinnedFolderCountsAsChosen() {
        let (userDefaults, suiteName) = makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let untouched = AppSettings(
            userDefaults: userDefaults,
            unpickedMeetingsFolder: AppSettings.defaultMeetingsFolder
        )
        XCTAssertFalse(untouched.meetingsFolderWasChosen)

        untouched.meetingsFolder = URL(
            fileURLWithPath: "/tmp/meetings", isDirectory: true)
        XCTAssertTrue(untouched.meetingsFolderWasChosen)

        let (pinnedDefaults, pinnedSuite) = makeUserDefaults()
        defer { pinnedDefaults.removePersistentDomain(forName: pinnedSuite) }
        let pinned = AppSettings(
            userDefaults: pinnedDefaults,
            unpickedMeetingsFolder: URL(
                fileURLWithPath: "/tmp/andrew-legacy", isDirectory: true)
        )
        XCTAssertTrue(pinned.meetingsFolderWasChosen)
    }

    func testAFolderInsideMobileDocumentsIsKnownToSync() {
        let synced = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Mobile Documents", isDirectory: true)
            .appendingPathComponent("com~apple~CloudDocs", isDirectory: true)
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("andrew-dictate", isDirectory: true)

        XCTAssertTrue(AppSettings.syncsToICloud(synced))
        XCTAssertFalse(AppSettings.syncsToICloud(AppSettings.defaultMeetingsFolder))
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

    /// ⌃⌥M, stored the way settings keep it, so a mac can be set up from the
    /// command line and the hotkey comes back at launch.
    func testTheMeetingShortcutSurvivesARelaunch() throws {
        let (userDefaults, suiteName) = makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let shortcut = MeetingShortcut(
            keyCode: 46, modifiers: [.control, .option], keyName: "M")

        let settings = AppSettings(userDefaults: userDefaults)
        settings.setMeetingShortcut(shortcut)

        XCTAssertEqual(AppSettings(userDefaults: userDefaults).meetingShortcut, shortcut)
        let stored = try XCTUnwrap(userDefaults.data(forKey: "AndrewDictate.meetingShortcut"))
        XCTAssertEqual(
            try JSONDecoder().decode(MeetingShortcut.self, from: stored), shortcut)
    }

    /// the shape `defaults write … -data` can write by hand.
    func testAMeetingShortcutWrittenByHandLoadsAtLaunch() {
        let (userDefaults, suiteName) = makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        userDefaults.set(
            Data(#"{"keyCode":46,"keyName":"M","modifiers":3}"#.utf8),
            forKey: "AndrewDictate.meetingShortcut")

        XCTAssertEqual(
            AppSettings(userDefaults: userDefaults).meetingShortcut,
            MeetingShortcut(keyCode: 46, modifiers: [.control, .option], keyName: "M"))
    }

    /// ⌘W kept from a build that took it would go on closing nothing and
    /// starting meetings: a shortcut this build would refuse does not load.
    func testAStoredMeetingShortcutThisBuildWouldRefuseDoesNotLoad() {
        let (userDefaults, suiteName) = makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        userDefaults.set(
            Data(#"{"keyCode":13,"keyName":"W","modifiers":8}"#.utf8),
            forKey: "AndrewDictate.meetingShortcut")

        XCTAssertNil(AppSettings(userDefaults: userDefaults).meetingShortcut)
    }

    func testThereIsNoMeetingShortcutUntilOneIsSet() {
        let (userDefaults, suiteName) = makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        XCTAssertNil(AppSettings(userDefaults: userDefaults).meetingShortcut)
    }

    /// clearing it has to erase the stored value, not leave the old one
    /// behind for the next launch to register again.
    func testClearingTheMeetingShortcutForgetsIt() {
        let (userDefaults, suiteName) = makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(userDefaults: userDefaults)
        settings.setMeetingShortcut(
            MeetingShortcut(keyCode: 46, modifiers: [.control, .option], keyName: "M"))
        settings.setMeetingShortcut(nil)

        XCTAssertNil(AppSettings(userDefaults: userDefaults).meetingShortcut)
        XCTAssertNil(userDefaults.data(forKey: "AndrewDictate.meetingShortcut"))
    }

    func testSettingsRefuseAMeetingShortcutThatHoldsTheDictationKey() {
        let (userDefaults, suiteName) = makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(userDefaults: userDefaults)
        XCTAssertTrue(settings.setHotkeyBinding(.rightOption))

        let refusal = settings.setMeetingShortcut(
            MeetingShortcut(keyCode: 46, modifiers: [.option, .command], keyName: "M"))

        XCTAssertEqual(refusal, .includesTheDictationKey(.rightOption))
        XCTAssertNil(settings.meetingShortcut)
        XCTAssertNil(AppSettings(userDefaults: userDefaults).meetingShortcut)
    }

    /// a refused shortcut leaves the one already set alone.
    func testARefusedMeetingShortcutKeepsTheOneThatWasSet() {
        let (userDefaults, suiteName) = makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(userDefaults: userDefaults)
        let kept = MeetingShortcut(keyCode: 46, modifiers: [.control, .option], keyName: "M")
        XCTAssertNil(settings.setMeetingShortcut(kept))

        let refusal = settings.setMeetingShortcut(
            MeetingShortcut(keyCode: 46, modifiers: [.shift], keyName: "M"))

        XCTAssertEqual(refusal, .needsAModifier)
        XCTAssertEqual(settings.meetingShortcut, kept)
    }

    /// the other direction of the same rule: the dictation key cannot move
    /// onto a modifier the meeting shortcut holds.
    func testTheDictationKeyCannotMoveOntoAModifierTheMeetingShortcutHolds() {
        let (userDefaults, suiteName) = makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(userDefaults: userDefaults)
        XCTAssertNil(settings.setMeetingShortcut(
            MeetingShortcut(keyCode: 46, modifiers: [.control, .option], keyName: "M")))

        XCTAssertFalse(settings.setHotkeyBinding(.rightOption))
        XCTAssertEqual(settings.dictationHotkey, .fn)
        XCTAssertTrue(settings.setHotkeyBinding(.rightCommand))
        XCTAssertEqual(settings.dictationHotkey, .rightCommand)
    }

    /// a meeting model is stored by name in two places: settings, and the
    /// manifest of every spool a crash leaves behind. both names from
    /// before parakeet could listen to meetings still read back as what
    /// they were.
    func testMeetingModelsStoredBeforeParakeetStillLoad() throws {
        let (userDefaults, suiteName) = makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let key = "AndrewDictate.meetingModel"

        userDefaults.set("whisperLargeV3", forKey: key)
        XCTAssertEqual(AppSettings(userDefaults: userDefaults).meetingModel, .whisperLargeV3)
        userDefaults.set("whisperLargeV3Turbo", forKey: key)
        XCTAssertEqual(AppSettings(userDefaults: userDefaults).meetingModel, .whisperLargeV3Turbo)

        let manifest = Data(#"["whisperLargeV3","whisperLargeV3Turbo"]"#.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode([SpeechModel].self, from: manifest),
            [.whisperLargeV3, .whisperLargeV3Turbo])
    }

    /// parakeet is a choice like the other two, and kept like them; the
    /// default stays whisper large, the one that writes english.
    func testParakeetForMeetingsSurvivesARelaunchAndIsNotTheDefault() throws {
        let (userDefaults, suiteName) = makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(userDefaults: userDefaults)
        XCTAssertEqual(settings.meetingModel, .whisperLargeV3)
        settings.meetingModel = .parakeetV3

        XCTAssertEqual(AppSettings(userDefaults: userDefaults).meetingModel, .parakeetV3)
        let manifest = try JSONEncoder().encode(SpeechModel.parakeetV3)
        XCTAssertEqual(try JSONDecoder().decode(SpeechModel.self, from: manifest), .parakeetV3)
        XCTAssertEqual(SpeechModel.meetingDefault, .whisperLargeV3)
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

    /// ADR 0043: the daily update check ships on, and has never asked.
    func testTheUpdateCheckIsOnAndHasNeverAsked() {
        let (userDefaults, suiteName) = makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(userDefaults: userDefaults)

        XCTAssertTrue(settings.checksForUpdates)
        XCTAssertNil(settings.updateCheckedAt)
        XCTAssertNil(settings.newestVersionSeen)
    }

    /// the switch, and the last answer, survive a relaunch — otherwise
    /// "once a day" would be "once a launch".
    func testTheUpdateCheckSwitchAndItsLastAnswerPersist() {
        let (userDefaults, suiteName) = makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let checkedAt = Date(timeIntervalSince1970: 1_790_000_000)

        let settings = AppSettings(userDefaults: userDefaults)
        settings.checksForUpdates = false
        settings.updateCheckedAt = checkedAt
        settings.newestVersionSeen = "0.9.5"

        let reloaded = AppSettings(userDefaults: userDefaults)
        XCTAssertFalse(reloaded.checksForUpdates)
        XCTAssertEqual(reloaded.updateCheckedAt, checkedAt)
        XCTAssertEqual(reloaded.newestVersionSeen, "0.9.5")
        XCTAssertEqual(
            userDefaults.object(forKey: "AndrewDictate.checksForUpdates")
                as? Bool,
            false
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

    /// the other half of that ruling: pre-roll stays off, and the one row
    /// that offers it has to say when it is worth turning on and what it
    /// costs while it is. the cost is the half that gets edited out.
    func testPreRollNamesTheClippedWordAndTheOpenMic() {
        let explanation = DictationOption.preRoll.explanation

        XCTAssertTrue(explanation.contains("clipped"), explanation)
        XCTAssertTrue(
            explanation.contains("the whole time the app runs"),
            explanation
        )
    }

    func testTurningKeepingOffSurvivesARelaunch() {
        let suite = "keep-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!

        let settings = AppSettings(userDefaults: defaults)
        settings.keepDictations = false

        XCTAssertFalse(AppSettings(userDefaults: defaults).keepDictations)
    }
}
