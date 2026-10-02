import XCTest

final class HotkeyLogicTests: XCTestCase {
    func testHoldBeginsOnPressAndEndsOnRelease() {
        var detector = TapLockDetector()

        XCTAssertEqual(
            detector.modifierPressed(at: 1.0),
            [.begin]
        )
        XCTAssertEqual(
            detector.modifierReleased(at: 1.5),
            [.end]
        )
    }

    /// another key during a hold is a chord: the machine decides whether
    /// that was a shortcut or the end of a sentence, and the release after
    /// it does nothing either way.
    func testAChordDuringAHoldIsSaidAndReleaseDoesNothing() {
        var detector = TapLockDetector()

        XCTAssertEqual(
            detector.modifierPressed(at: 1.0),
            [.begin]
        )
        XCTAssertEqual(
            detector.keyDown(isEscape: false),
            [.chord]
        )
        XCTAssertEqual(
            detector.modifierReleased(at: 1.2),
            []
        )
    }

    func testTwoQuickTapsDiscardProvisionalCaptureAndBeginLockedCapture() {
        var detector = TapLockDetector()

        XCTAssertEqual(
            detector.modifierPressed(at: 1.0),
            [.begin]
        )
        XCTAssertEqual(
            detector.modifierReleased(at: 1.1),
            [.provisionalEnd]
        )
        XCTAssertEqual(
            detector.modifierPressed(at: 1.3),
            []
        )
        XCTAssertEqual(
            detector.modifierReleased(at: 1.4),
            [.cancel, .lockBegin]
        )
        XCTAssertEqual(detector.provisionalEndWindowExpired(), [])
    }

    func testSameKeyTapWhileLockedEndsLockedCapture() {
        var detector = lockedDetector()

        XCTAssertEqual(
            detector.modifierPressed(at: 1.6),
            []
        )
        XCTAssertEqual(
            detector.modifierReleased(at: 1.7),
            [.lockEnd]
        )
    }

    func testQuickSingleTapIsDiscardedWhenNoSecondTapArrives() {
        var detector = TapLockDetector()

        XCTAssertEqual(
            detector.modifierPressed(at: 1.0),
            [.begin]
        )
        XCTAssertEqual(
            detector.modifierReleased(at: 1.1),
            [.provisionalEnd]
        )
        XCTAssertEqual(
            detector.provisionalEndWindowExpired(),
            [.cancel]
        )

        XCTAssertEqual(
            detector.modifierPressed(at: 1.5),
            [.begin]
        )
        XCTAssertEqual(
            detector.modifierReleased(at: 1.6),
            [.provisionalEnd]
        )
        XCTAssertEqual(
            detector.provisionalEndWindowExpired(),
            [.cancel]
        )
    }

    /// the 300 ms line: either side of it the same gesture means something
    /// completely different, so both sides are pinned.
    func testJustUnderTheTapThresholdIsDiscardedAndJustOverEndsTheTake() {
        var brushed = TapLockDetector()
        _ = brushed.modifierPressed(at: 1.0)

        XCTAssertEqual(
            brushed.modifierReleased(at: 1.29),
            [.provisionalEnd]
        )
        XCTAssertEqual(
            brushed.provisionalEndWindowExpired(),
            [.cancel]
        )

        var held = TapLockDetector()
        _ = held.modifierPressed(at: 1.0)

        XCTAssertEqual(
            held.modifierReleased(at: 1.31),
            [.end]
        )
        XCTAssertEqual(held.provisionalEndWindowExpired(), [])
    }

    func testEscapeCancelsLockedCapture() {
        var detector = lockedDetector()

        XCTAssertEqual(
            detector.keyDown(isEscape: true),
            [.lockCancel]
        )
    }

    /// escape is consumed by the coordinator, which cancels the capture and
    /// then hands the detector a reset. the hold two seconds later has to be
    /// a whole capture, not a swallowed no-op.
    func testTheHoldAfterEscapingALockedCaptureStillRecords() {
        var detector = lockedDetector()

        XCTAssertEqual(
            detector.keyDown(isEscape: true),
            [.lockCancel]
        )
        _ = detector.reset()

        XCTAssertEqual(
            detector.modifierPressed(at: 2.0),
            [.begin]
        )
        XCTAssertEqual(
            detector.modifierReleased(at: 2.6),
            [.end]
        )
    }

    func testTheHoldAfterEscapingAnOrdinaryHoldStillRecords() {
        var detector = TapLockDetector()

        XCTAssertEqual(
            detector.modifierPressed(at: 1.0),
            [.begin]
        )
        _ = detector.reset()

        // the key is still physically down, so its release must not read as
        // the end of a capture that was already thrown away.
        XCTAssertEqual(
            detector.modifierReleased(at: 1.2),
            []
        )
        XCTAssertEqual(
            detector.modifierPressed(at: 1.5),
            [.begin]
        )
    }

    func testOrdinaryKeysAreIgnoredWhileLocked() {
        var detector = lockedDetector()

        XCTAssertEqual(detector.keyDown(isEscape: false), [])

        XCTAssertEqual(
            detector.modifierPressed(at: 1.8),
            []
        )
        XCTAssertEqual(
            detector.modifierReleased(at: 1.9),
            [.lockEnd]
        )
    }

    func testResetCancelsHeldAndLockedCaptures() {
        var heldDetector = TapLockDetector()
        _ = heldDetector.modifierPressed(at: 1.0)

        XCTAssertEqual(heldDetector.reset(), [.cancel])
        XCTAssertEqual(
            heldDetector.modifierPressed(at: 1.1),
            [.begin]
        )

        var locked = lockedDetector()

        XCTAssertEqual(locked.reset(), [.lockCancel])
        XCTAssertEqual(
            locked.modifierPressed(at: 1.5),
            [.begin]
        )
    }

    /// the settings row draws this on one line at a fixed 800 px, so the
    /// sentence has to stay lowercase, stay one sentence, and stay short
    /// enough that a later edit cannot quietly truncate it to an ellipsis.
    func testTheGestureSentenceStaysOneLowercaseLine() {
        let sentence = HotkeyBinding.gestureExplanation

        XCTAssertEqual(sentence, sentence.lowercased())
        XCTAssertTrue(sentence.hasSuffix("."))
        XCTAssertLessThanOrEqual(sentence.count, 90)
    }

    // MARK: - the meeting shortcut

    /// one key, both ways: a press starts a meeting when none is recording
    /// and stops the one that is. a meeting still writing out its file is
    /// not recording, so a press then starts the next one.
    func testTheMeetingShortcutStartsWhenNothingRecordsAndStopsWhenAMeetingDoes() {
        XCTAssertEqual(MeetingShortcut.press(whileRecording: false), .start)
        XCTAssertEqual(MeetingShortcut.press(whileRecording: true), .stop)
    }

    /// the dictation key begins a take the moment it goes down, and any key
    /// pressed with it ends that take as a chord. a shortcut with that
    /// modifier in it would start a dictation and cancel it, every time, so
    /// settings do not take one. left and right are one modifier to a
    /// shortcut, so either side's key rules it out.
    func testAShortcutThatHoldsTheDictationKeyIsRefusedAndSaysWhy() {
        let optionCommandM = MeetingShortcut(
            keyCode: 46, modifiers: [.option, .command], keyName: "M")

        let refusal = optionCommandM.refusal(againstDictationKey: .rightOption)

        XCTAssertEqual(refusal, .includesTheDictationKey(.rightOption))
        XCTAssertEqual(refusal?.message, "includes your dictation key, right ⌥")
        XCTAssertEqual(
            optionCommandM.refusal(againstDictationKey: .leftOption),
            .includesTheDictationKey(.leftOption))
        XCTAssertEqual(
            optionCommandM.refusal(againstDictationKey: .rightCommand),
            .includesTheDictationKey(.rightCommand))
    }

    /// the key alone, or with only shift, would fire in the middle of
    /// typing: control or command has to be held too.
    func testAShortcutNeedsControlOrCommand() {
        let bare = MeetingShortcut(keyCode: 46, modifiers: [], keyName: "M")
        let shifted = MeetingShortcut(keyCode: 46, modifiers: [.shift], keyName: "M")

        XCTAssertEqual(bare.refusal(againstDictationKey: .fn), .needsAModifier)
        XCTAssertEqual(shifted.refusal(againstDictationKey: .fn), .needsAModifier)
        XCTAssertEqual(
            bare.refusal(againstDictationKey: .fn)?.message,
            "needs ⌃ or ⌘ held with it")
    }

    /// option is how a mac types its other characters, and since macOS 15
    /// the system will not register a hot key held with option alone, or
    /// option and shift: settings would keep a shortcut that never fires.
    func testOptionAloneOrWithShiftIsRefused() {
        let optionM = MeetingShortcut(keyCode: 46, modifiers: [.option], keyName: "M")
        let optionShiftM = MeetingShortcut(
            keyCode: 46, modifiers: [.option, .shift], keyName: "M")

        XCTAssertEqual(optionM.refusal(againstDictationKey: .fn), .optionAlone)
        XCTAssertEqual(optionShiftM.refusal(againstDictationKey: .fn), .optionAlone)
        XCTAssertEqual(
            optionM.refusal(againstDictationKey: .fn)?.message,
            "macos won't take ⌥ without ⌃ or ⌘")
        XCTAssertNil(
            MeetingShortcut(keyCode: 46, modifiers: [.option, .command], keyName: "M")
                .refusal(againstDictationKey: .fn))
    }

    /// ⌘W pressed to close settings would close nothing ever again: it
    /// would start a meeting, everywhere. and the app's own ⌘V, pressed
    /// for every paste, would start or stop one after every dictation.
    /// command alone or with shift, on the keys every mac app answers, is
    /// refused; with control or option as well it is the user's to have.
    func testTheChordsEveryMacAppAnswersAreRefused() {
        let letters: [(UInt16, String)] = [
            (0, "A"), (8, "C"), (3, "F"), (4, "H"), (46, "M"), (45, "N"), (31, "O"),
            (35, "P"), (12, "Q"), (1, "S"), (17, "T"), (9, "V"), (13, "W"), (7, "X"),
            (6, "Z"),
        ]
        let keys: [(UInt16, String)] = [(48, "⇥"), (49, "space"), (36, "↩"), (51, "⌫")]
        for (keyCode, name) in letters + keys {
            for modifiers: MeetingShortcut.Modifiers in [[.command], [.command, .shift]] {
                let chord = MeetingShortcut(keyCode: keyCode, modifiers: modifiers, keyName: name)
                XCTAssertEqual(
                    chord.refusal(againstDictationKey: .fn), .everyAppUsesIt,
                    chord.displayName)
            }
        }
        XCTAssertEqual(
            MeetingShortcut(keyCode: 13, modifiers: [.command], keyName: "W")
                .refusal(againstDictationKey: .fn)?.message,
            "every app already uses that one")

        XCTAssertNil(
            MeetingShortcut(keyCode: 13, modifiers: [.control, .command], keyName: "W")
                .refusal(againstDictationKey: .fn))
        XCTAssertNil(
            MeetingShortcut(keyCode: 37, modifiers: [.command, .shift], keyName: "L")
                .refusal(againstDictationKey: .fn))
    }

    /// a menu matches the character the key typed; the paste and the
    /// system match where the key sits. a layout that moves the letters
    /// is refused either way.
    func testAChordIsRefusedByItsCharacterAndByItsKey() {
        // azerty: the key where a us keyboard has Q types A.
        XCTAssertEqual(
            MeetingShortcut(keyCode: 12, modifiers: [.command], keyName: "A")
                .refusal(againstDictationKey: .fn),
            .everyAppUsesIt)
        // dvorak: the key where a us keyboard has . types V.
        XCTAssertEqual(
            MeetingShortcut(keyCode: 47, modifiers: [.command], keyName: "V")
                .refusal(againstDictationKey: .fn),
            .everyAppUsesIt)
    }

    /// ⌘⇧3, 4 and 5 are the mac's screenshots. ⌘3 alone is an app's to
    /// give, and is not refused for it.
    func testTheScreenshotKeysAreRefused() {
        for keyCode: UInt16 in [20, 21, 23] {
            let chord = MeetingShortcut(
                keyCode: keyCode, modifiers: [.command, .shift], keyName: "#")
            XCTAssertEqual(chord.refusal(againstDictationKey: .fn), .takesAScreenshot)
        }
        XCTAssertEqual(
            MeetingShortcut(keyCode: 20, modifiers: [.command, .shift], keyName: "#")
                .refusal(againstDictationKey: .fn)?.message,
            "that's the mac's screenshot key")
        XCTAssertNil(
            MeetingShortcut(keyCode: 20, modifiers: [.command], keyName: "3")
                .refusal(againstDictationKey: .fn))
        XCTAssertNil(
            MeetingShortcut(keyCode: 22, modifiers: [.command, .shift], keyName: "^")
                .refusal(againstDictationKey: .fn))
    }

    /// while the row listens, ⌘W and ⌘Q on their own are a hand leaving:
    /// the row lets them through to the window instead of taking them.
    func testABareCommandWOrQIsHowYouLeaveNotAShortcut() {
        XCTAssertTrue(
            MeetingShortcut(keyCode: 13, modifiers: [.command], keyName: "W").closesOrQuits)
        XCTAssertTrue(
            MeetingShortcut(keyCode: 12, modifiers: [.command], keyName: "Q").closesOrQuits)
        XCTAssertFalse(
            MeetingShortcut(keyCode: 13, modifiers: [.command, .shift], keyName: "W")
                .closesOrQuits)
        XCTAssertFalse(
            MeetingShortcut(keyCode: 12, modifiers: [.control, .command], keyName: "Q")
                .closesOrQuits)
        XCTAssertFalse(
            MeetingShortcut(keyCode: 9, modifiers: [.command], keyName: "V").closesOrQuits)
    }

    /// esc is the dictation key's own cancel, heard everywhere: a shortcut
    /// on it would end a take every time it started or stopped a meeting.
    func testAShortcutCannotBeOnEscape() {
        let controlEscape = MeetingShortcut(
            keyCode: 53, modifiers: [.control], keyName: "esc")

        XCTAssertEqual(controlEscape.refusal(againstDictationKey: .fn), .isEscape)
        XCTAssertEqual(
            controlEscape.refusal(againstDictationKey: .fn)?.message,
            "esc cancels a dictation")
    }

    /// what is allowed stays allowed: fn is not a modifier a shortcut can
    /// hold, and another family's modifier is no clash.
    func testAShortcutThatDoesNotHoldTheDictationKeyIsAccepted() {
        let controlOptionM = MeetingShortcut(
            keyCode: 46, modifiers: [.control, .option], keyName: "M")
        let controlCommandM = MeetingShortcut(
            keyCode: 46, modifiers: [.control, .command], keyName: "M")

        XCTAssertNil(controlOptionM.refusal(againstDictationKey: .fn))
        XCTAssertNil(controlCommandM.refusal(againstDictationKey: .rightOption))
        XCTAssertNil(controlOptionM.refusal(againstDictationKey: .leftCommand))
    }

    func testTheShortcutIsWrittenTheWayTheMacWritesIt() {
        XCTAssertEqual(
            MeetingShortcut(
                keyCode: 46, modifiers: [.command, .control, .shift, .option], keyName: "M"
            ).displayName,
            "⌃⌥⇧⌘M")
        XCTAssertEqual(
            MeetingShortcut(keyCode: 49, modifiers: [.control, .option], keyName: "space")
                .displayName,
            "⌃⌥space")
    }

    /// a letter reads as its capital; the keys with no character worth
    /// showing — space, the arrows, the function row — read as what they are.
    func testAKeyIsNamedByItsCharacterOrByWhatItIs() {
        XCTAssertEqual(MeetingShortcut.keyName(forKeyCode: 46, characters: "m"), "M")
        XCTAssertEqual(MeetingShortcut.keyName(forKeyCode: 47, characters: "."), ".")
        XCTAssertEqual(MeetingShortcut.keyName(forKeyCode: 49, characters: " "), "space")
        XCTAssertEqual(MeetingShortcut.keyName(forKeyCode: 36, characters: "\r"), "↩")
        XCTAssertEqual(MeetingShortcut.keyName(forKeyCode: 123, characters: "\u{F702}"), "←")
        XCTAssertEqual(MeetingShortcut.keyName(forKeyCode: 126, characters: "\u{F700}"), "↑")
        XCTAssertEqual(MeetingShortcut.keyName(forKeyCode: 96, characters: "\u{F708}"), "F5")
        XCTAssertEqual(MeetingShortcut.keyName(forKeyCode: 53, characters: "\u{1B}"), "esc")
    }

    private func lockedDetector() -> TapLockDetector {
        var detector = TapLockDetector()
        _ = detector.modifierPressed(at: 1.0)
        _ = detector.modifierReleased(at: 1.1)
        _ = detector.modifierPressed(at: 1.3)
        _ = detector.modifierReleased(at: 1.4)
        return detector
    }
}

final class WaveLevelTests: XCTestCase {
    func testShaperGatesResidualHum() {
        XCTAssertEqual(WaveLevelShaper.shape(0), 0)
        XCTAssertEqual(WaveLevelShaper.shape(0.03), 0)
        XCTAssertEqual(WaveLevelShaper.shape(0.05), 0)
    }

    func testMidSpeechFillsMeaningfulHeight() {
        // conversational speech (~mid-window) should render clearly visible
        let mid = WaveLevelShaper.shape(0.5)
        XCTAssertGreaterThan(mid, 0.38)
        XCTAssertLessThan(mid, 0.62)
    }

    func testShaperIsMonotonicAndReachesOne() {
        let a = WaveLevelShaper.shape(0.3)
        let b = WaveLevelShaper.shape(0.6)
        let c = WaveLevelShaper.shape(1.0)
        XCTAssertLessThan(a, b)
        XCTAssertLessThan(b, c)
        XCTAssertEqual(c, 1.0, accuracy: 0.0001)
    }
}
