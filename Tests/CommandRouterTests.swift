import XCTest

final class CommandRouterTests: XCTestCase {
    private let router = CommandRouter()

    func testOpenRoutesToOpenApp() {
        XCTAssertEqual(
            router.route("open Arc"),
            .openApp(query: "Arc")
        )
    }

    func testLaunchIsAnOpenAliasAndVerbsAreCaseInsensitive() {
        XCTAssertEqual(
            router.route("LAUNCH Safari"),
            .openApp(query: "Safari")
        )
    }

    func testSwitchToRoutesToSwitchToApp() {
        XCTAssertEqual(
            router.route("switch to Visual Studio Code"),
            .switchToApp(query: "Visual Studio Code")
        )
    }

    func testQuitRoutesToQuitApp() {
        XCTAssertEqual(
            router.route("quit Music"),
            .quitApp(query: "Music")
        )
    }

    func testGoToDomainAddsHTTPS() {
        XCTAssertEqual(
            router.route("go to news.ycombinator.com"),
            .goTo(urlString: "https://news.ycombinator.com")
        )
    }

    func testGoToPreservesAnExistingScheme() {
        XCTAssertEqual(
            router.route("go to http://example.com/docs"),
            .goTo(urlString: "http://example.com/docs")
        )
    }

    func testGoToNonHTTPSchemeDelegatesForGating() {
        XCTAssertEqual(
            router.route("go to custom:destination"),
            .delegate(prompt: "go to custom:destination")
        )
    }

    func testGoToShortcutsURLDelegatesForGating() {
        let transcript =
            "go to shortcuts://run-shortcut?name=Delete%20Everything"
        XCTAssertEqual(
            router.route(transcript),
            .delegate(prompt: transcript)
        )
    }

    func testGoToNonURLFallsBackToSwitchToApp() {
        XCTAssertEqual(
            router.route("go to System Settings"),
            .switchToApp(query: "System Settings")
        )
    }

    func testGoToAppIsNotASpecialGrammarForm() {
        XCTAssertEqual(
            router.route("go to app Arc"),
            .switchToApp(query: "app Arc")
        )
    }

    func testTypePreservesTheRawTranscriptTail() {
        XCTAssertEqual(
            router.route("type um, Keep THIS   spacing  "),
            .typeLiteral(text: "um, Keep THIS   spacing  ")
        )
    }

    func testLeadingWhitespaceAndFlexibleVerbWhitespaceAreAccepted() {
        XCTAssertEqual(
            router.route(" \n switch \t to   Slack \n"),
            .switchToApp(query: "Slack")
        )
    }

    func testVerbMustBeAWholeLeadingWord() {
        XCTAssertEqual(
            router.route("opening Arc"),
            .delegate(prompt: "opening Arc")
        )
    }

    func testVerbWithoutARemainderDelegates() {
        XCTAssertEqual(router.route("open"), .delegate(prompt: "open"))
        XCTAssertEqual(router.route("switch to"), .delegate(prompt: "switch to"))
        XCTAssertEqual(router.route("type   "), .delegate(prompt: "type   "))
    }

    func testTierOneWinsBeforeATemplate() {
        XCTAssertEqual(
            router.route("open google swift actors"),
            .openApp(query: "google swift actors")
        )
    }

    func testEveryKnownSiteBuildsItsTemplate() throws {
        let cases: [(site: String, expectedURL: String)] = [
            (
                "chatgpt",
                "https://chatgpt.com/?q=swift%20actors"
            ),
            (
                "claude",
                "https://claude.ai/new?q=swift%20actors"
            ),
            (
                "perplexity",
                "https://www.perplexity.ai/search?q=swift%20actors"
            ),
            (
                "google",
                "https://www.google.com/search?q=swift%20actors"
            ),
            (
                "youtube",
                "https://www.youtube.com/results?search_query=swift%20actors"
            ),
        ]

        for testCase in cases {
            let command = try XCTUnwrap(
                templateCommand(
                    from: router.route("\(testCase.site) swift actors")
                )
            )
            XCTAssertEqual(command.url.absoluteString, testCase.expectedURL)
            XCTAssertTrue(command.url.isHTTPOrHTTPS)
            XCTAssertEqual(
                command.label,
                "\(testCase.site): swift actors"
            )
        }
    }

    func testOptionalSearchWordProducesTheSameTemplate() {
        XCTAssertEqual(
            router.route("chatgpt search explain actors"),
            router.route("chatgpt explain actors")
        )
    }

    func testTemplateSiteMatchingIsCaseInsensitive() {
        let expectedURL = URL(
            string: "https://www.google.com/search?q=Swift"
        )!
        XCTAssertEqual(
            router.route("GOOGLE Swift"),
            .template(url: expectedURL, label: "google: Swift")
        )
    }

    func testSearchIsOnlyFillerAsAWholeWord() {
        let expectedURL = URL(
            string: "https://www.google.com/search?q=searchlight"
        )!
        XCTAssertEqual(
            router.route("google searchlight"),
            .template(url: expectedURL, label: "google: searchlight")
        )
    }

    func testTemplateRequiresANonemptyQuery() {
        XCTAssertEqual(
            router.route("google"),
            .delegate(prompt: "google")
        )
        XCTAssertEqual(
            router.route("google search"),
            .delegate(prompt: "google search")
        )
    }

    func testTemplateRequiresTheKnownSiteAsTheExactFirstWord() {
        XCTAssertEqual(
            router.route("googley swift actors"),
            .delegate(prompt: "googley swift actors")
        )
        XCTAssertEqual(
            router.route("please google swift actors"),
            .delegate(prompt: "please google swift actors")
        )
    }

    func testTemplateQueryIsPercentEncoded() throws {
        let command = try XCTUnwrap(
            templateCommand(
                from: router.route("google C++ actors & #macOS café")
            )
        )

        XCTAssertEqual(
            URLComponents(
                url: command.url,
                resolvingAgainstBaseURL: false
            )?.queryItems,
            [
                URLQueryItem(
                    name: "q",
                    value: "C++ actors & #macOS café"
                ),
            ]
        )
        XCTAssertFalse(command.url.absoluteString.contains(" "))
        XCTAssertTrue(command.url.absoluteString.contains("C%2B%2B"))
        XCTAssertTrue(command.url.absoluteString.contains("%26"))
        XCTAssertTrue(command.url.absoluteString.contains("%23"))
    }

    func testUnknownInputDelegatesUnchanged() {
        XCTAssertEqual(
            router.route("brew install arc"),
            .delegate(prompt: "brew install arc")
        )
    }

    func testEmptyWhitespaceAndGarbageInputsDelegateUnchanged() {
        XCTAssertEqual(router.route(""), .delegate(prompt: ""))
        XCTAssertEqual(router.route("   \n"), .delegate(prompt: "   \n"))
        XCTAssertEqual(
            router.route("?! 123"),
            .delegate(prompt: "?! 123")
        )
    }

    private func templateCommand(
        from command: RoutedCommand
    ) -> (url: URL, label: String)? {
        guard case let .template(url, label) = command else {
            return nil
        }
        return (url, label)
    }
}
