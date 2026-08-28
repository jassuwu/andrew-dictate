import XCTest

final class AppIdentityTests: XCTestCase {
    func testTheReleaseBuildKeepsTheFolderItHasAlwaysHad() {
        XCTAssertEqual(
            AppIdentity.supportDirectoryName(for: "gg.jass.dictate"),
            "Andrew Dictate",
            "renaming this orphans every existing dictionary and archive"
        )
    }

    func testADevelopmentBuildGetsItsOwnFolder() {
        XCTAssertEqual(
            AppIdentity.supportDirectoryName(for: "gg.jass.dictate.dev"),
            "Andrew Dictate Dev"
        )
    }

    /// The check is equality with the release identifier, not a `.dev` suffix.
    /// Anything unrecognised must land in development storage — a typo should
    /// cost you a fresh empty folder, never the archive you actually use.
    func testAnythingUnrecognisedIsTreatedAsDevelopment() {
        for bundleID in [
            "gg.jass.dictate.local",
            "gg.jass.dictate2",
            "com.example.whatever",
            "",
        ] {
            XCTAssertEqual(
                AppIdentity.supportDirectoryName(for: bundleID),
                "Andrew Dictate Dev",
                bundleID
            )
        }
    }
}
