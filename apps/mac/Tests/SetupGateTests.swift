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
    /// the badge and the "finish setup" row answer to this, and settings
    /// already calls a failed download a setup issue — so the menu must too.
    func testAFailedSpeechModelNeedsAttentionEvenWithEveryGrant() {
        XCTAssertTrue(
            SetupGate.needsAttention(
                onboardingDismissed: true,
                dictationWanted: true,
                permissions: ready,
                speechModelFailed: true
            )
        )
    }

    /// keying the dot on "not ready" would blink it through every legitimate
    /// first download, which is most of a new user's first minutes.
    func testADownloadInProgressIsNotAProblem() {
        XCTAssertFalse(
            SetupGate.needsAttention(
                onboardingDismissed: true,
                dictationWanted: true,
                permissions: ready,
                speechModelFailed: false
            )
        )
    }

    func testAMeetingsOnlySetupIsNeverBadgedForTheSpeechModel() {
        XCTAssertFalse(
            SetupGate.needsAttention(
                onboardingDismissed: true,
                dictationWanted: false,
                permissions: noAccessibility,
                speechModelFailed: true
            )
        )
    }

    /// before setup has been dismissed, onboarding is the surface that says
    /// this — the badge would be repeating it behind an open window.
    func testSetupNotYetDismissedIsNeverBadged() {
        XCTAssertFalse(
            SetupGate.needsAttention(
                onboardingDismissed: false,
                dictationWanted: true,
                permissions: noMicrophone,
                speechModelFailed: true
            )
        )
    }

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

extension SetupGateTests {
    /// the global key monitors are built at launch, which on a first run is
    /// before anyone has granted anything — only the moment trust arrives
    /// is worth rebuilding them.
    func testOnlyANewGrantRebuildsTheHotkeyMonitors() {
        XCTAssertTrue(
            SetupGate.shouldReinstallHotkey(was: false, now: true)
        )
        XCTAssertFalse(
            SetupGate.shouldReinstallHotkey(was: true, now: true)
        )
        XCTAssertFalse(
            SetupGate.shouldReinstallHotkey(was: true, now: false)
        )
        XCTAssertFalse(
            SetupGate.shouldReinstallHotkey(was: false, now: false)
        )
    }
}
