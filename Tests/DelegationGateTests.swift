import XCTest

final class DelegationGateTests: XCTestCase {
    func testQuickCommandTapConfirmsPendingPrompt() {
        var now: TimeInterval = 10
        var gate = DelegationGate(now: { now })
        gate.present(
            prompt: "brew install arc",
            commandPreview: "→ codex: brew install arc"
        )

        XCTAssertTrue(gate.isPending)
        XCTAssertEqual(gate.commandKeyPressed(), .none)

        now += 0.1
        XCTAssertEqual(
            gate.commandKeyReleased(),
            .confirmed(prompt: "brew install arc")
        )
        XCTAssertEqual(gate.state, .idle)
    }

    func testCancelMovesPendingGateToIdle() {
        var gate = DelegationGate(now: { 20 })
        gate.present(
            prompt: "delete old files",
            commandPreview: "→ codex: delete old files"
        )

        XCTAssertEqual(gate.cancel(), .cancelled)
        XCTAssertEqual(gate.state, .idle)
        XCTAssertEqual(gate.cancel(), .none)
    }

    func testInjectedClockDrivesTimeoutCancellation() {
        var now: TimeInterval = 30
        var gate = DelegationGate(now: { now })
        gate.present(
            prompt: "update dependencies",
            commandPreview: "→ codex: update dependencies"
        )

        now += DelegationGate.defaultTimeout - 0.001
        XCTAssertEqual(gate.cancelIfTimedOut(), .none)
        XCTAssertTrue(gate.isPending)

        now += 0.001
        XCTAssertEqual(gate.cancelIfTimedOut(), .cancelled)
        XCTAssertEqual(gate.state, .idle)
    }

    func testLongCommandPressDoesNotConfirm() {
        var now: TimeInterval = 40
        var gate = DelegationGate(now: { now })
        gate.present(
            prompt: "commit changes",
            commandPreview: "→ codex: commit changes"
        )

        XCTAssertEqual(gate.commandKeyPressed(), .none)
        now += DelegationGate.maximumConfirmationTapDuration + 0.001
        XCTAssertEqual(gate.commandKeyReleased(), .none)
        XCTAssertTrue(gate.isPending)
    }
}
