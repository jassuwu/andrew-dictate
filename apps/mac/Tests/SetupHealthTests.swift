import XCTest

final class SetupHealthTests: XCTestCase {
    private let ready = PermissionSnapshot(
        microphoneGranted: true,
        accessibilityGranted: true
    )

    func testAWorkingSetupHasNothingToSay() {
        XCTAssertTrue(
            SetupHealth.issues(
                permissions: ready,
                speechModelFailed: false
            ).isEmpty
        )
    }

    func testEachMissingPieceIsNamedOnce() {
        let issues = SetupHealth.issues(
            permissions: PermissionSnapshot(
                microphoneGranted: false,
                accessibilityGranted: false
            ),
            speechModelFailed: true
        )

        XCTAssertEqual(
            issues.map(\.id),
            ["microphone", "accessibility", "speech-model"]
        )
    }

    func testAFailedModelIsAnIssueEvenWhenPermissionsAreFine() {
        XCTAssertEqual(
            SetupHealth.issues(
                permissions: ready,
                speechModelFailed: true
            ).map(\.id),
            ["speech-model"]
        )
    }
}
