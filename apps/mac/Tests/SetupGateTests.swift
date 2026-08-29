import XCTest

final class SetupGateTests: XCTestCase {
    private let ready = PermissionSnapshot(
        microphoneGranted: true,
        accessibilityGranted: true
    )
    private let noAccessibility = PermissionSnapshot(
        microphoneGranted: true,
        accessibilityGranted: false
    )
    private let noMicrophone = PermissionSnapshot(
        microphoneGranted: false,
        accessibilityGranted: true
    )

    func testDictationNeedsBothGrants() {
        XCTAssertTrue(ready.isDictationReady)
        XCTAssertFalse(noAccessibility.isDictationReady)
        XCTAssertFalse(noMicrophone.isDictationReady)
    }

    func testFirstRunAlwaysPresents() {
        for moment in [
            SetupCheckMoment.launchOrReopen,
            .midSession
        ] {
            XCTAssertEqual(
                SetupGate.presentation(
                    onboardingDismissed: false,
                    permissions: ready,
                    moment: moment
                ),
                .present
            )
        }
    }

    func testSkippingWithEveryGrantIsNeverNaggedAgain() {
        XCTAssertEqual(
            SetupGate.presentation(
                onboardingDismissed: true,
                permissions: ready,
                moment: .launchOrReopen
            ),
            .none
        )
    }

    func testUnusableSetupPresentsOnLaunchOrReopen() {
        for permissions in [noAccessibility, noMicrophone] {
            XCTAssertEqual(
                SetupGate.presentation(
                    onboardingDismissed: true,
                    permissions: permissions,
                    moment: .launchOrReopen
                ),
                .present
            )
        }
    }

    func testRevocationMidSessionNeverStealsFocus() {
        XCTAssertEqual(
            SetupGate.presentation(
                onboardingDismissed: true,
                permissions: noAccessibility,
                moment: .midSession
            ),
            .badgeOnly
        )
    }
}

extension SetupGateTests {
    /// someone who set up meetings only has no hotkey to be dead, so a
    /// missing accessibility grant is not a reason to bring setup back.
    func testAMeetingsOnlySetupIsNeverNaggedForAccessibility() {
        for moment in [SetupCheckMoment.launchOrReopen, .midSession] {
            XCTAssertEqual(
                SetupGate.presentation(
                    onboardingDismissed: true,
                    permissions: noAccessibility,
                    moment: moment,
                    dictationWanted: false
                ),
                .none
            )
        }
        XCTAssertEqual(
            SetupGate.presentation(
                onboardingDismissed: false,
                permissions: noAccessibility,
                moment: .launchOrReopen,
                dictationWanted: false
            ),
            .present
        )
    }
}
