import XCTest

final class CapabilitiesTests: XCTestCase {
    /// Uninstall is not a development convenience. "Nothing you say leaves the
    /// machine" is only half a promise if leaving is hard.
    func testBothBuildsCanUninstall() {
        XCTAssertTrue(Capabilities.release.canUninstall)
        XCTAssertTrue(Capabilities.development.canUninstall)
    }

    /// The distinction the whole type exists for: a shortcut that skips
    /// confirmation is fine against a throwaway folder and unacceptable
    /// against someone's real archive.
    func testOnlyDevelopmentCanWipeWithoutAsking() {
        XCTAssertFalse(Capabilities.release.canResetInPlace)
        XCTAssertTrue(Capabilities.development.canResetInPlace)
    }

    func testTimingsShipInBothBecauseTheClaimIsCheckable() {
        XCTAssertTrue(Capabilities.release.canCopyTimings)
        XCTAssertTrue(Capabilities.development.canCopyTimings)
    }

    func testOnlyDevelopmentTalksAboutItself() {
        XCTAssertFalse(Capabilities.release.announcesItself)
        XCTAssertTrue(Capabilities.development.announcesItself)
    }

    func testTheReleaseBuildNeverGetsDevelopmentCapabilities() {
        // Belt and braces: if `current` ever resolved the wrong way, the
        // release app would ship a one-click wipe of a stranger's archive.
        XCTAssertEqual(
            Capabilities.release,
            Capabilities(
                canUninstall: true,
                canResetInPlace: false,
                canCopyTimings: true,
                announcesItself: false
            )
        )
    }
}
