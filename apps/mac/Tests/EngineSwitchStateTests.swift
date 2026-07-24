import XCTest

final class EngineSwitchStateTests: XCTestCase {
    func testPreparingAlongsideLeavesCurrentVersionActive() {
        var state = EngineSwitchState(activeVersion: .v2)

        XCTAssertTrue(state.beginPreparing(.v3))
        XCTAssertEqual(state.activeVersion, .v2)
        XCTAssertEqual(state.targetVersion, .v3)
        XCTAssertNil(state.failureMessage)
    }

    func testReadyPreparationSwapsAtomically() {
        var state = EngineSwitchState(activeVersion: .v2)
        state.beginPreparing(.v3)

        let resolution = state.resolvePreparation(
            for: .v3,
            outcome: .ready
        )

        XCTAssertEqual(
            resolution,
            .swapped(from: .v2, to: .v3)
        )
        XCTAssertEqual(state.activeVersion, .v3)
        XCTAssertNil(state.targetVersion)
        XCTAssertNil(state.failureMessage)
    }

    func testFailedPreparationKeepsCurrentAndRequestsRevert() {
        var state = EngineSwitchState(activeVersion: .v2)
        state.beginPreparing(.v3)

        let resolution = state.resolvePreparation(
            for: .v3,
            outcome: .failed
        )

        XCTAssertEqual(
            resolution,
            .reverted(
                to: .v2,
                message:
                    "couldn't switch — still on parakeet v2"
            )
        )
        XCTAssertEqual(state.activeVersion, .v2)
        XCTAssertNil(state.targetVersion)
        XCTAssertEqual(
            state.failureMessage,
            "couldn't switch — still on parakeet v2"
        )
    }

    func testStalePreparationOutcomeCannotReplaceNewerTarget() {
        var state = EngineSwitchState(activeVersion: .v2)
        state.beginPreparing(.v3)
        state.beginPreparing(.v2)

        XCTAssertEqual(
            state.resolvePreparation(for: .v3, outcome: .ready),
            .ignored
        )
        XCTAssertEqual(state.activeVersion, .v2)
        XCTAssertNil(state.targetVersion)
    }

    func testSelectingCurrentVersionCancelsPendingSwitch() {
        var state = EngineSwitchState(activeVersion: .v2)
        state.beginPreparing(.v3)

        XCTAssertFalse(state.beginPreparing(.v2))
        XCTAssertEqual(state.activeVersion, .v2)
        XCTAssertNil(state.targetVersion)
    }
}
