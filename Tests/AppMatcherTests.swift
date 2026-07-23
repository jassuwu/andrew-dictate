import Foundation
import XCTest

final class AppMatcherTests: XCTestCase {
    func testExactCaseInsensitiveMatchWinsOverPrefix() {
        let exact = app("Arc", path: "/Applications/Arc.app")
        let prefix = app(
            "Arc Browser",
            path: "/Applications/Arc Browser.app"
        )
        let matcher = AppMatcher(applications: [prefix, exact])

        XCTAssertEqual(matcher.match("aRc"), exact)
    }

    func testPrefixMatchWinsBeforeTokenAndDistanceMatching() {
        let prefix = app(
            "Visual Studio Code",
            path: "/Applications/Visual Studio Code.app"
        )
        let token = app(
            "Code Visualizer",
            path: "/Applications/Code Visualizer.app"
        )
        let matcher = AppMatcher(applications: [token, prefix])

        XCTAssertEqual(matcher.match("Visual Studio"), prefix)
    }

    func testTokenSubsetMatchesWordsInAnyOrder() {
        let expected = app(
            "Visual Studio Code",
            path: "/Applications/Visual Studio Code.app"
        )
        let matcher = AppMatcher(
            applications: [
                app("CodeEdit", path: "/Applications/CodeEdit.app"),
                expected,
            ]
        )

        XCTAssertEqual(matcher.match("code visual"), expected)
    }

    func testTokenMatchingUsesWholeTokens() {
        let matcher = AppMatcher(
            applications: [
                app("Superhuman", path: "/Applications/Superhuman.app"),
            ]
        )

        XCTAssertNil(matcher.match("human"))
    }

    func testSmallLevenshteinTypoMatches() {
        let expected = app("Slack", path: "/Applications/Slack.app")
        let matcher = AppMatcher(
            applications: [
                app("Music", path: "/System/Applications/Music.app"),
                expected,
            ]
        )

        XCTAssertEqual(matcher.match("slak"), expected)
    }

    func testClosestLevenshteinCandidateWins() {
        let safari = app(
            "Safari",
            path: "/System/Applications/Safari.app"
        )
        let matcher = AppMatcher(
            applications: [
                app("Saffron", path: "/Applications/Saffron.app"),
                safari,
            ]
        )

        XCTAssertEqual(matcher.match("safri"), safari)
    }

    func testDistanceThresholdRejectsUnrelatedGarbage() {
        let matcher = AppMatcher(
            applications: [
                app("Safari", path: "/System/Applications/Safari.app"),
                app("Slack", path: "/Applications/Slack.app"),
            ]
        )

        XCTAssertNil(matcher.match("totally unrelated"))
    }

    func testEmptyAndWhitespaceQueriesDoNotMatch() {
        let matcher = AppMatcher(
            applications: [
                app("Safari", path: "/System/Applications/Safari.app"),
            ]
        )

        XCTAssertNil(matcher.match(""))
        XCTAssertNil(matcher.match("   \n"))
    }

    func testExactMatchingIgnoresDiacritics() {
        let expected = app(
            "Résumé",
            path: "/Applications/Resume.app"
        )
        let matcher = AppMatcher(applications: [expected])

        XCTAssertEqual(matcher.match("resume"), expected)
    }

    func testAmbiguousMatchesPreferTheShorterDisplayName() {
        let shorter = app("Termius", path: "/Applications/Termius.app")
        let matcher = AppMatcher(
            applications: [
                app("Terminal", path: "/System/Applications/Terminal.app"),
                shorter,
            ]
        )

        XCTAssertEqual(matcher.match("term"), shorter)
    }

    func testStableTieBreakUsesNameThenPath() {
        let alpha = app("Alpha Tool", path: "/Applications/Alpha Tool.app")
        let matcher = AppMatcher(
            applications: [
                app("Alpine App", path: "/Applications/Alpine App.app"),
                alpha,
            ]
        )

        XCTAssertEqual(matcher.match("al"), alpha)
    }

    private func app(_ name: String, path: String) -> InstalledApp {
        InstalledApp(
            displayName: name,
            url: URL(fileURLWithPath: path),
            bundleIdentifier: "test.\(name)"
        )
    }
}
