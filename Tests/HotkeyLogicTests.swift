import XCTest

final class HotkeyLogicTests: XCTestCase {
    func testHoldBeginsOnPressAndEndsOnRelease() {
        var detector = TapLockDetector()

        XCTAssertEqual(
            detector.modifierPressed(.dictation, at: 1.0),
            [.begin(.dictation)]
        )
        XCTAssertEqual(
            detector.modifierReleased(.dictation, at: 1.5),
            [.end(.dictation)]
        )
    }

    func testChordCancelsHeldCaptureAndReleaseDoesNothing() {
        var detector = TapLockDetector()

        XCTAssertEqual(
            detector.modifierPressed(.command, at: 1.0),
            [.begin(.command)]
        )
        XCTAssertEqual(
            detector.keyDown(isEscape: false),
            [.cancel(.command)]
        )
        XCTAssertEqual(
            detector.modifierReleased(.command, at: 1.2),
            []
        )
    }

    func testTwoQuickTapsDiscardProvisionalCaptureAndBeginLockedCapture() {
        var detector = TapLockDetector()

        XCTAssertEqual(
            detector.modifierPressed(.dictation, at: 1.0),
            [.begin(.dictation)]
        )
        XCTAssertEqual(
            detector.modifierReleased(.dictation, at: 1.1),
            [.provisionalEnd(.dictation)]
        )
        XCTAssertEqual(
            detector.modifierPressed(.dictation, at: 1.3),
            []
        )
        XCTAssertEqual(
            detector.modifierReleased(.dictation, at: 1.4),
            [.cancel(.dictation), .lockBegin(.dictation)]
        )
        XCTAssertEqual(detector.provisionalEndWindowExpired(), [])
    }

    func testSameKeyTapWhileLockedEndsLockedCapture() {
        var detector = lockedDetector(mode: .command)

        XCTAssertEqual(
            detector.modifierPressed(.command, at: 1.6),
            []
        )
        XCTAssertEqual(
            detector.modifierReleased(.command, at: 1.7),
            [.lockEnd(.command)]
        )
    }

    func testQuickSingleTapDefersEndUntilDoubleTapWindowExpires() {
        var detector = TapLockDetector()

        XCTAssertEqual(
            detector.modifierPressed(.dictation, at: 1.0),
            [.begin(.dictation)]
        )
        XCTAssertEqual(
            detector.modifierReleased(.dictation, at: 1.1),
            [.provisionalEnd(.dictation)]
        )
        XCTAssertEqual(
            detector.provisionalEndWindowExpired(),
            [.end(.dictation)]
        )

        XCTAssertEqual(
            detector.modifierPressed(.dictation, at: 1.5),
            [.begin(.dictation)]
        )
        XCTAssertEqual(
            detector.modifierReleased(.dictation, at: 1.6),
            [.provisionalEnd(.dictation)]
        )
        XCTAssertEqual(
            detector.provisionalEndWindowExpired(),
            [.end(.dictation)]
        )
    }

    func testEscapeCancelsLockedCapture() {
        var detector = lockedDetector(mode: .dictation)

        XCTAssertEqual(
            detector.keyDown(isEscape: true),
            [.lockCancel(.dictation)]
        )
    }

    func testOtherModeAndOrdinaryKeysAreIgnoredWhileLocked() {
        var detector = lockedDetector(mode: .dictation)

        XCTAssertEqual(
            detector.modifierPressed(.command, at: 1.6),
            []
        )
        XCTAssertEqual(
            detector.modifierReleased(.command, at: 1.7),
            []
        )
        XCTAssertEqual(detector.keyDown(isEscape: false), [])

        XCTAssertEqual(
            detector.modifierPressed(.dictation, at: 1.8),
            []
        )
        XCTAssertEqual(
            detector.modifierReleased(.dictation, at: 1.9),
            [.lockEnd(.dictation)]
        )
    }

    func testResetCancelsHeldAndLockedCaptures() {
        var heldDetector = TapLockDetector()
        _ = heldDetector.modifierPressed(.dictation, at: 1.0)

        XCTAssertEqual(heldDetector.reset(), [.cancel(.dictation)])
        XCTAssertEqual(
            heldDetector.modifierPressed(.dictation, at: 1.1),
            [.begin(.dictation)]
        )

        var locked = lockedDetector(mode: .command)

        XCTAssertEqual(locked.reset(), [.lockCancel(.command)])
        XCTAssertEqual(
            locked.modifierPressed(.command, at: 1.5),
            [.begin(.command)]
        )
    }

    private func lockedDetector(mode: DictationMode) -> TapLockDetector {
        var detector = TapLockDetector()
        _ = detector.modifierPressed(mode, at: 1.0)
        _ = detector.modifierReleased(mode, at: 1.1)
        _ = detector.modifierPressed(mode, at: 1.3)
        _ = detector.modifierReleased(mode, at: 1.4)
        return detector
    }
}
