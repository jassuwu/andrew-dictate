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

    func testTwoQuickTapsBeginLockedCapture() {
        var detector = TapLockDetector()

        XCTAssertEqual(
            detector.modifierPressed(.dictation, at: 1.0),
            [.begin(.dictation)]
        )
        XCTAssertEqual(
            detector.modifierReleased(.dictation, at: 1.1),
            [.end(.dictation)]
        )
        XCTAssertEqual(
            detector.modifierPressed(.dictation, at: 1.3),
            [.begin(.dictation)]
        )
        XCTAssertEqual(
            detector.modifierReleased(.dictation, at: 1.4),
            [.lockBegin(.dictation)]
        )
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

    func testQuickSingleTapStillBeginsAndEnds() {
        var detector = TapLockDetector()

        XCTAssertEqual(
            detector.modifierPressed(.dictation, at: 1.0),
            [.begin(.dictation)]
        )
        XCTAssertEqual(
            detector.modifierReleased(.dictation, at: 1.1),
            [.end(.dictation)]
        )

        XCTAssertEqual(
            detector.modifierPressed(.dictation, at: 1.5),
            [.begin(.dictation)]
        )
        XCTAssertEqual(
            detector.modifierReleased(.dictation, at: 1.6),
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

    private func lockedDetector(mode: DictationMode) -> TapLockDetector {
        var detector = TapLockDetector()
        _ = detector.modifierPressed(mode, at: 1.0)
        _ = detector.modifierReleased(mode, at: 1.1)
        _ = detector.modifierPressed(mode, at: 1.3)
        _ = detector.modifierReleased(mode, at: 1.4)
        return detector
    }
}
