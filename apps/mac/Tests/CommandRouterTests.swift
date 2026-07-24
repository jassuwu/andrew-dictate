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
            .ask(prompt: "opening Arc")
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
            .ask(prompt: "google")
        )
        XCTAssertEqual(
            router.route("google search"),
            .ask(prompt: "google search")
        )
    }

    func testTemplateRequiresTheKnownSiteAsTheExactFirstWord() {
        XCTAssertEqual(
            router.route("googley swift actors"),
            .ask(prompt: "googley swift actors")
        )
        XCTAssertEqual(
            router.route("please google swift actors"),
            .ask(prompt: "please google swift actors")
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

    func testImperativeInputDelegatesUnchanged() {
        XCTAssertEqual(
            router.route("brew install arc"),
            .delegate(prompt: "brew install arc")
        )
    }

    func testEmptyWhitespaceAndGarbageInputsAskUnchanged() {
        XCTAssertEqual(router.route(""), .ask(prompt: ""))
        XCTAssertEqual(router.route("   \n"), .ask(prompt: "   \n"))
        XCTAssertEqual(
            router.route("?! 123"),
            .ask(prompt: "?! 123")
        )
    }

    func testAskActJudgmentTable() {
        let cases: [(String, RoutedCommand)] = [
            ("what is actor isolation", .ask(prompt: "what is actor isolation")),
            ("why did the build fail", .ask(prompt: "why did the build fail")),
            (
                "how do I undo this",
                .screenAsk(
                    prompt: "how do I undo this",
                    scope: .frontWindow
                )
            ),
            ("is docker running", .ask(prompt: "is docker running")),
            ("can you run the tests", .ask(prompt: "can you run the tests")),
            ("explain git rebase", .ask(prompt: "explain git rebase")),
            (
                "summarize this project",
                .screenAsk(
                    prompt: "summarize this project",
                    scope: .frontWindow
                )
            ),
            ("tell me whether to deploy", .ask(prompt: "tell me whether to deploy")),
            ("status of the build", .ask(prompt: "status of the build")),
            ("please deploy the app", .ask(prompt: "please deploy the app")),
            ("run the tests", .delegate(prompt: "run the tests")),
            ("build status", .delegate(prompt: "build status")),
            ("restart?", .delegate(prompt: "restart?")),
            ("fix what is broken", .delegate(prompt: "fix what is broken")),
            ("git status", .delegate(prompt: "git status")),
            ("docker compose up", .delegate(prompt: "docker compose up")),
            ("npm install", .delegate(prompt: "npm install")),
            ("delete the cache", .delegate(prompt: "delete the cache")),
            ("write a release note", .delegate(prompt: "write a release note")),
            ("maybe the cache is stale", .ask(prompt: "maybe the cache is stale")),
        ]

        for (phrase, expected) in cases {
            XCTAssertEqual(
                router.route(phrase),
                expected,
                "unexpected route for '\(phrase)'"
            )
        }
    }

    func testScreenAskCueRoutingTable() {
        let cases: [
            (phrase: String, expected: RoutedCommand)
        ] = [
            (
                "what is this",
                .screenAsk(
                    prompt: "what is this",
                    scope: .frontWindow
                )
            ),
            (
                "explain this error",
                .screenAsk(
                    prompt: "explain this error",
                    scope: .frontWindow
                )
            ),
            (
                "what changed on this page?",
                .screenAsk(
                    prompt: "what changed on this page?",
                    scope: .frontWindow
                )
            ),
            (
                "summarize this window",
                .screenAsk(
                    prompt: "summarize this window",
                    scope: .frontWindow
                )
            ),
            (
                "what happened here",
                .screenAsk(
                    prompt: "what happened here",
                    scope: .frontWindow
                )
            ),
            (
                "THIS looks wrong",
                .screenAsk(
                    prompt: "THIS looks wrong",
                    scope: .frontWindow
                )
            ),
            (
                "what is on my screen",
                .screenAsk(
                    prompt: "what is on my screen",
                    scope: .activeDisplay
                )
            ),
            (
                "summarize the screen",
                .screenAsk(
                    prompt: "summarize the screen",
                    scope: .activeDisplay
                )
            ),
            (
                "explain everything",
                .screenAsk(
                    prompt: "explain everything",
                    scope: .activeDisplay
                )
            ),
            (
                "what is on this display",
                .screenAsk(
                    prompt: "what is on this display",
                    scope: .activeDisplay
                )
            ),
            (
                "what is this on my screen",
                .screenAsk(
                    prompt: "what is this on my screen",
                    scope: .activeDisplay
                )
            ),
            (
                "compare here with the screen",
                .screenAsk(
                    prompt: "compare here with the screen",
                    scope: .activeDisplay
                )
            ),
            (
                "what is actor isolation",
                .ask(prompt: "what is actor isolation")
            ),
            (
                "why did that page fail",
                .ask(prompt: "why did that page fail")
            ),
            (
                "what is on that screen",
                .ask(prompt: "what is on that screen")
            ),
        ]

        for testCase in cases {
            XCTAssertEqual(
                router.route(testCase.phrase),
                testCase.expected,
                "unexpected route for '\(testCase.phrase)'"
            )
        }
    }

    func testDisplayCuesWinScopeConflicts() {
        XCTAssertEqual(
            CommandRouter.screenAskScope(
                in: "this error is also on my screen"
            ),
            .activeDisplay
        )
        XCTAssertEqual(
            CommandRouter.screenAskScope(
                in: "look here on this display"
            ),
            .activeDisplay
        )
        XCTAssertEqual(
            CommandRouter.screenAskScope(
                in: "compare this window with the screen"
            ),
            .activeDisplay
        )
        XCTAssertEqual(
            CommandRouter.screenAskScope(in: "this error here"),
            .frontWindow
        )
        XCTAssertNil(
            CommandRouter.screenAskScope(
                in: "what is on that monitor"
            )
        )
    }

    func testTierOneLiteralTypingStillWinsBeforeScreenAsk() {
        XCTAssertEqual(
            router.route("type this exactly"),
            .typeLiteral(text: "this exactly")
        )
    }

    func testImperativeDetectorUsesOnlyTheNormalizedLeadingToken() {
        XCTAssertTrue(CommandRouter.isImperativeShape("  RUN tests"))
        XCTAssertTrue(CommandRouter.isImperativeShape("“docker” ps"))
        XCTAssertTrue(CommandRouter.isImperativeShape("delete?"))
        XCTAssertFalse(CommandRouter.isImperativeShape("running tests"))
        XCTAssertFalse(CommandRouter.isImperativeShape("please run tests"))
        XCTAssertFalse(CommandRouter.isImperativeShape(""))
    }

    func testQuestionDetectorUsesWholeLeadingTokens() {
        XCTAssertTrue(CommandRouter.isQuestionShape("  WHAT now"))
        XCTAssertTrue(CommandRouter.isQuestionShape("“explain:” actors"))
        XCTAssertTrue(CommandRouter.isQuestionShape("can build finish"))
        XCTAssertFalse(CommandRouter.isQuestionShape("whatever works"))
        XCTAssertFalse(CommandRouter.isQuestionShape("please explain actors"))
        XCTAssertFalse(CommandRouter.isQuestionShape("?!"))
    }

    func testCustomActionWinsBeforeBuiltInVerb() {
        let action = CustomAction(
            trigger: "open arc",
            type: .ask,
            payload: "why arc?"
        )
        XCTAssertEqual(
            router.route(
                "OPEN, ARC!",
                customActions: [action]
            ),
            .custom(action: action, capturedArgument: nil)
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
