import XCTest

final class EngineSwitchStateTests: XCTestCase {
    func testPreparingAlongsideLeavesCurrentVersionActive() {
        var state = EngineSwitchState(activeVersion: .parakeetV2)

        XCTAssertTrue(state.beginPreparing(.parakeetV3))
        XCTAssertEqual(state.activeVersion, .parakeetV2)
        XCTAssertEqual(state.targetVersion, .parakeetV3)
        XCTAssertNil(state.failureMessage)
    }

    func testReadyPreparationSwapsAtomically() {
        var state = EngineSwitchState(activeVersion: .parakeetV2)
        state.beginPreparing(.parakeetV3)

        let resolution = state.resolvePreparation(
            for: .parakeetV3,
            outcome: .ready
        )

        XCTAssertEqual(
            resolution,
            .swapped(from: .parakeetV2, to: .parakeetV3)
        )
        XCTAssertEqual(state.activeVersion, .parakeetV3)
        XCTAssertNil(state.targetVersion)
        XCTAssertNil(state.failureMessage)
    }

    func testFailedPreparationKeepsCurrentAndRequestsRevert() {
        var state = EngineSwitchState(activeVersion: .parakeetV2)
        state.beginPreparing(.parakeetV3)

        let resolution = state.resolvePreparation(
            for: .parakeetV3,
            outcome: .failed
        )

        XCTAssertEqual(
            resolution,
            .reverted(
                to: .parakeetV2,
                message:
                    "couldn't switch — still on parakeet v2"
            )
        )
        XCTAssertEqual(state.activeVersion, .parakeetV2)
        XCTAssertNil(state.targetVersion)
        XCTAssertEqual(
            state.failureMessage,
            "couldn't switch — still on parakeet v2"
        )
    }

    func testStalePreparationOutcomeCannotReplaceNewerTarget() {
        var state = EngineSwitchState(activeVersion: .parakeetV2)
        state.beginPreparing(.parakeetV3)
        state.beginPreparing(.parakeetV2)

        XCTAssertEqual(
            state.resolvePreparation(for: .parakeetV3, outcome: .ready),
            .ignored
        )
        XCTAssertEqual(state.activeVersion, .parakeetV2)
        XCTAssertNil(state.targetVersion)
    }

    func testSelectingCurrentVersionCancelsPendingSwitch() {
        var state = EngineSwitchState(activeVersion: .parakeetV2)
        state.beginPreparing(.parakeetV3)

        XCTAssertFalse(state.beginPreparing(.parakeetV2))
        XCTAssertEqual(state.activeVersion, .parakeetV2)
        XCTAssertNil(state.targetVersion)
    }
}
