import XCTest

final class DelegationGateTests: XCTestCase {
    func testQuickCommandTapConfirmsPendingPrompt() {
        var now: TimeInterval = 10
        var gate = DelegationGate(now: { now })
        gate.present(
            prompt: "brew install arc",
            commandPreview: "→ codex: brew install arc",
            generation: 1
        )

        XCTAssertTrue(gate.isPending(generation: 1))
        now += DelegationGate.minimumArmingDelay
        XCTAssertEqual(
            gate.commandKeyPressed(generation: 1),
            .none
        )

        now += 0.1
        XCTAssertEqual(
            gate.commandKeyReleased(generation: 1),
            .confirmed(prompt: "brew install arc")
        )
        XCTAssertEqual(gate.state, .idle)
    }

    func testCancelMovesPendingGateToIdle() {
        var gate = DelegationGate(now: { 20 })
        gate.present(
            prompt: "delete old files",
            commandPreview: "→ codex: delete old files",
            generation: 2
        )

        XCTAssertEqual(
            gate.cancel(generation: 2),
            .cancelled
        )
        XCTAssertEqual(gate.state, .idle)
        XCTAssertEqual(gate.cancel(generation: 2), .none)
    }

    func testInjectedClockDrivesTimeoutCancellation() {
        var now: TimeInterval = 30
        var gate = DelegationGate(now: { now })
        gate.present(
            prompt: "update dependencies",
            commandPreview: "→ codex: update dependencies",
            generation: 3
        )

        now += DelegationGate.defaultTimeout - 0.001
        XCTAssertEqual(
            gate.cancelIfTimedOut(generation: 3),
            .none
        )
        XCTAssertTrue(gate.isPending(generation: 3))

        now += 0.001
        XCTAssertEqual(
            gate.cancelIfTimedOut(generation: 3),
            .cancelled
        )
        XCTAssertEqual(gate.state, .idle)
    }

    func testLongCommandPressDoesNotConfirm() {
        var now: TimeInterval = 40
        var gate = DelegationGate(now: { now })
        gate.present(
            prompt: "commit changes",
            commandPreview: "→ codex: commit changes",
            generation: 4
        )

        now += DelegationGate.minimumArmingDelay
        XCTAssertEqual(
            gate.commandKeyPressed(generation: 4),
            .none
        )
        now += DelegationGate.maximumConfirmationTapDuration + 0.001
        XCTAssertEqual(
            gate.commandKeyReleased(generation: 4),
            .none
        )
        XCTAssertTrue(gate.isPending(generation: 4))
    }

    func testCommandTapBeforeMinimumArmingDelayDoesNotConfirm() {
        var now: TimeInterval = 50
        var gate = DelegationGate(now: { now })
        gate.present(
            prompt: "delete cache",
            commandPreview: "→ codex: delete cache",
            generation: 5
        )

        now += DelegationGate.minimumArmingDelay - 0.001
        XCTAssertEqual(
            gate.commandKeyPressed(generation: 5),
            .none
        )
        now += 0.1
        XCTAssertEqual(
            gate.commandKeyReleased(generation: 5),
            .none
        )
        XCTAssertTrue(gate.isPending(generation: 5))

        XCTAssertEqual(
            gate.commandKeyPressed(generation: 5),
            .none
        )
        now += 0.1
        XCTAssertEqual(
            gate.commandKeyReleased(generation: 5),
            .confirmed(prompt: "delete cache")
        )
    }

    func testGenerationMismatchRejectsConfirmation() {
        var now: TimeInterval = 60
        var gate = DelegationGate(now: { now })
        gate.present(
            prompt: "publish release",
            commandPreview: "→ codex: publish release",
            generation: 6
        )
        now += DelegationGate.minimumArmingDelay

        XCTAssertEqual(
            gate.commandKeyPressed(generation: 7),
            .none
        )
        now += 0.1
        XCTAssertEqual(
            gate.commandKeyReleased(generation: 7),
            .none
        )
        XCTAssertTrue(gate.isPending(generation: 6))
    }

    func testStateReplacementCancelsPendingGate() {
        var gate = DelegationGate(now: { 70 })
        gate.present(
            prompt: "restart service",
            commandPreview: "→ codex: restart service",
            generation: 8
        )

        XCTAssertEqual(
            gate.cancelForStateReplacement(),
            .cancelled
        )
        XCTAssertEqual(gate.state, .idle)
        XCTAssertEqual(
            gate.cancelForStateReplacement(),
            .none
        )
    }

    func testOldTimeoutAfterReplacementDoesNotCancelNewGate() {
        var now: TimeInterval = 80
        var gate = DelegationGate(now: { now })
        gate.present(
            prompt: "old prompt",
            commandPreview: "→ codex: old prompt",
            generation: 9
        )

        now += 1
        gate.present(
            prompt: "new prompt",
            commandPreview: "→ codex: new prompt",
            generation: 10
        )
        now += DelegationGate.defaultTimeout - 1

        XCTAssertEqual(
            gate.cancelIfTimedOut(generation: 9),
            .none
        )
        XCTAssertTrue(gate.isPending(generation: 10))
    }
}
