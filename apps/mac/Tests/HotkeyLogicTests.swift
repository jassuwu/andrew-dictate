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

    func testChordCancelsHeldCaptureAndReleaseDoesNothing() {
        var detector = TapLockDetector()

        XCTAssertEqual(
            detector.modifierPressed(at: 1.0),
            [.begin]
        )
        XCTAssertEqual(
            detector.keyDown(isEscape: false),
            [.cancel]
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

    /// the lock is built out of two quick taps, so discarding a lone one
    /// must not have changed how the pair reads.
    func testDiscardingALoneTapLeavesTheDoubleTapLockIntact() {
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
    }

    func testEscapeCancelsLockedCapture() {
        var detector = lockedDetector()

        XCTAssertEqual(
            detector.keyDown(isEscape: true),
            [.lockCancel]
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
