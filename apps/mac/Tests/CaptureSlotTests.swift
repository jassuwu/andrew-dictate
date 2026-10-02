import XCTest

/// which capture a press is handed, and when one is thrown away: a device
/// change makes it stale, the next press gets a fresh one, and once the
/// hardware has been quiet the stale one goes — never from under a take.
@MainActor
final class CaptureSlotTests: XCTestCase {
    private var clock: FakeUtteranceClock!
    private var made: [FakeCapture] = []
    private var inUse = false
    private var preRoll = false

    override func setUp() async throws {
        clock = FakeUtteranceClock()
        made = []
        inUse = false
        preRoll = false
    }

    private func slot() -> CaptureSlot {
        CaptureSlot(
            clock: clock,
            isInUse: { [weak self] in self?.inUse ?? false },
            keepsListening: { [weak self] in self?.preRoll ?? false },
            make: { [weak self] in
                let capture = FakeCapture()
                self?.made.append(capture)
                return capture
            }
        )
    }

    /// building an engine is the slow part of a first press, so one capture
    /// serves press after press while nothing moves.
    func testPressesShareOneCaptureWhileNothingMoves() {
        let slot = slot()

        let first = slot.captureForPress()
        let second = slot.captureForPress()

        XCTAssertTrue(first === second)
        XCTAssertEqual(made.count, 1)
    }

    /// a monitor, the lid, airpods: the press after any of them is handed a
    /// capture built after it, bound to whatever the mac says is the mic now.
    func testAChangeBetweenPressesHandsTheNextPressAFreshCapture() {
        let slot = slot()
        let before = slot.captureForPress()

        slot.deviceChanged()
        let after = slot.captureForPress()

        XCTAssertFalse(before === after)
        XCTAssertEqual(made.count, 2)
        XCTAssertEqual(made[0].discards, 1)
        XCTAssertEqual(made[1].discards, 0)
    }

    /// nobody pressing: the stale capture goes once nothing has moved for
    /// half a second, and a fresh one is built in its place, ready.
    func testTheStaleCaptureGoesOnceTheHardwareHasSettled() async {
        let slot = slot()
        _ = slot.captureForPress()

        slot.deviceChanged()
        await pass(.milliseconds(400))
        slot.deviceChanged()
        await pass(.milliseconds(400))
        XCTAssertEqual(made[0].discards, 0)
        await pass(.milliseconds(100))

        XCTAssertEqual(made[0].discards, 1)
        XCTAssertEqual(made.count, 2)
        XCTAssertEqual(made[1].prepares, 1)
    }

    /// with pre-roll on a capture is always listening, so the fresh one is
    /// built and started as soon as the hardware has settled.
    func testWithPreRollAFreshCaptureListensOnceTheHardwareHasSettled() async {
        preRoll = true
        let slot = slot()
        slot.prepare()
        XCTAssertEqual(made.count, 1)
        XCTAssertEqual(made[0].prepares, 1)

        slot.deviceChanged()
        await pass(.milliseconds(500))

        XCTAssertEqual(made[0].discards, 1)
        XCTAssertEqual(made.count, 2)
        XCTAssertEqual(made[1].prepares, 1)
        XCTAssertTrue(slot.captureForPress() === made[1])
    }

    /// a take still holding the capture keeps it: the stale one goes once
    /// the take has let go, not from under it.
    func testACaptureATakeIsHoldingIsNotThrownAwayUnderIt() async {
        let slot = slot()
        _ = slot.captureForPress()
        inUse = true

        slot.deviceChanged()
        await pass(.milliseconds(500))
        await pass(.milliseconds(500))
        XCTAssertEqual(made[0].discards, 0)

        inUse = false
        await pass(.milliseconds(500))
        XCTAssertEqual(made[0].discards, 1)
    }

    /// the machine gave up on a capture that would not answer: it is never
    /// handed out again.
    func testADroppedCaptureIsNeverHandedOutAgain() {
        let slot = slot()
        let wedged = slot.captureForPress()

        slot.drop()
        let next = slot.captureForPress()

        XCTAssertEqual(made[0].discards, 1)
        XCTAssertFalse(wedged === next)
    }

    /// going to sleep takes the listening capture down; waking is a change
    /// like any other, and with pre-roll on the next one listens once the
    /// hardware has settled.
    func testSleepTakesThePreRollCaptureDownAndWakeBringsAFreshOne() async {
        preRoll = true
        let slot = slot()
        slot.prepare()

        slot.suspend()
        XCTAssertEqual(made[0].discards, 1)
        XCTAssertEqual(made.count, 1)

        slot.deviceChanged()
        await pass(.milliseconds(500))
        XCTAssertEqual(made.count, 2)
        XCTAssertEqual(made[1].prepares, 1)
    }

    /// pre-roll switched either way: the capture was built for the other
    /// mode, so it goes, and the new one is built ready for this one.
    func testSwitchingPreRollRebuildsTheCapture() {
        let slot = slot()
        _ = slot.captureForPress()

        preRoll = true
        slot.listeningChanged()
        XCTAssertEqual(made[0].discards, 1)
        XCTAssertEqual(made.count, 2)
        XCTAssertEqual(made[1].prepares, 1)

        preRoll = false
        slot.listeningChanged()
        XCTAssertEqual(made[1].discards, 1)
        XCTAssertEqual(made.count, 3)
        XCTAssertEqual(made[2].prepares, 1)
    }

    /// pre-roll switched under a take: only you throw an utterance away, so
    /// the take keeps the capture it started with, and the switch lands
    /// once it has let go — or at the next press, whichever is first.
    func testSwitchingPreRollUnderATakeWaitsForTheTake() async {
        let slot = slot()
        let holding = slot.captureForPress()
        inUse = true

        preRoll = true
        slot.listeningChanged()
        await pass(.milliseconds(500))
        await pass(.milliseconds(500))
        XCTAssertEqual(made[0].discards, 0)
        XCTAssertEqual(made.count, 1)

        inUse = false
        await pass(.milliseconds(500))
        XCTAssertEqual(made[0].discards, 1)
        XCTAssertEqual(made.count, 2)
        XCTAssertEqual(made[1].prepares, 1)
        XCTAssertFalse(holding === slot.captureForPress())
    }

    /// a press before the switch has landed is handed a capture built for
    /// the new mode, not the one the last take held.
    func testAPressAfterASwitchUnderATakeGetsAFreshCapture() {
        let slot = slot()
        let holding = slot.captureForPress()
        inUse = true

        slot.listeningChanged()
        inUse = false
        let next = slot.captureForPress()

        XCTAssertFalse(holding === next)
        XCTAssertEqual(made[0].discards, 1)
    }

    // MARK: - helpers

    private func pass(_ duration: Duration) async {
        try? await Task.sleep(for: .milliseconds(10))
        clock.advance(by: duration)
        try? await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
private final class FakeCapture: DisposableMicCapture {
    let deviceDescription: MicDescription? = nil
    private(set) var prepares = 0
    private(set) var discards = 0

    func start(
        onFirstBuffer: @escaping @MainActor @Sendable (
            ContinuousClock.Instant
        ) -> Void
    ) async throws {}

    func stop() async throws -> [Float] {
        []
    }

    func cancel() {}

    func prepare() {
        prepares += 1
    }

    func discard() {
        discards += 1
    }
}
