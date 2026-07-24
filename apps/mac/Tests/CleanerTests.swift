import XCTest

final class CleanerTests: XCTestCase {
    func testDictionarySubstitutionUsesExactReplacementCasing() {
        let cleaner = DeterministicCleaner(
            entries: [
                DictionaryEntry(wrong: "gpt", right: "GPT"),
                DictionaryEntry(wrong: "iphone", right: "iPhone"),
            ]
        )

        XCTAssertEqual(
            cleaner.clean("use gPt with an IPHONE"),
            "Use GPT with an iPhone."
        )
    }

    func testWordBoundariesProtectPartialMatches() {
        let cleaner = DeterministicCleaner(
            entries: [DictionaryEntry(wrong: "gpt", right: "GPT")]
        )

        XCTAssertEqual(cleaner.clean("umbrella gptx"), "Umbrella gptx.")
    }

    func testFillersAndFollowingCommasAreRemoved() {
        let cleaner = DeterministicCleaner()

        XCTAssertEqual(
            cleaner.clean("um, I uh think erm, this uhm works"),
            "I think this works."
        )
    }

    func testConservativeFillerListKeepsLikeAndYouKnow() {
        let cleaner = DeterministicCleaner()

        XCTAssertEqual(
            cleaner.clean("like, you know, this works"),
            "Like, you know, this works."
        )
    }

    func testWhitespaceIsCollapsedAndRemovedBeforePunctuation() {
        let cleaner = DeterministicCleaner()

        XCTAssertEqual(
            cleaner.clean("  hello   ,   world  !  "),
            "Hello, world!"
        )
    }

    func testSentenceStartsAreCapitalizedAndFinishWithAPeriod() {
        let cleaner = DeterministicCleaner()

        // ADR 0019 adds sentence-aware capitalization and punctuation
        // finishing, so the old lowercase second sentence is intentionally
        // upgraded here.
        XCTAssertEqual(
            cleaner.clean("hello. second sentence"),
            "Hello. Second sentence."
        )
    }

    func testEmptyStringRemainsEmpty() {
        XCTAssertEqual(DeterministicCleaner().clean(""), "")
    }

    func testDictionaryOnlyPassPreservesRawCommandText() {
        let substituter = DictionarySubstituter(
            entries: [DictionaryEntry(wrong: "gpt", right: "GPT")]
        )

        XCTAssertEqual(
            substituter.apply(to: "  type um, gPt   EXACTLY  "),
            "  type um, GPT   EXACTLY  "
        )
    }

    func testUnicodeWhitespaceNormalizerTable() {
        assertTransform(
            UnicodeWhitespaceNormalizer(),
            cases: [
                ("", ""),
                ("  hello  ", "hello"),
                ("hello\t\tworld", "hello world"),
                ("hello\nworld", "hello world"),
                ("hello\r\nworld", "hello world"),
                ("hello\u{00A0}world", "hello world"),
                ("hello\u{2003}world", "hello world"),
                ("cafe\u{301}", "café"),
                ("zero\u{200B}width", "zerowidth"),
            ]
        )
    }

    func testSpokenPunctuationCoreTable() {
        assertTransform(
            SpokenPunctuation(),
            cases: [
                ("hello comma how", "hello, how"),
                ("done period", "done."),
                ("done full stop", "done."),
                ("really question mark", "really?"),
                ("great exclamation mark", "great!"),
                ("great exclamation point", "great!"),
                ("one colon two", "one: two"),
                ("one semicolon two", "one; two"),
                ("first new line second", "first\nsecond"),
                (
                    "first new paragraph second",
                    "first\n\nsecond"
                ),
                (
                    "open quote hello close quote",
                    "\"hello\""
                ),
                (
                    "say open quote hello close quote now",
                    "say \"hello\" now"
                ),
            ]
        )
    }

    func testSpokenPunctuationConservativeBoundariesTable() {
        assertTransform(
            SpokenPunctuation(),
            cases: [
                ("comma support", "comma support"),
                ("period drama", "period drama"),
                ("question mark syntax", "question mark syntax"),
                ("new line handling", "new line handling"),
                ("open quote", "open quote"),
                ("close quote", "close quote"),
                ("commander", "commander"),
                ("periodic work", "periodic work"),
                // Accepted v1 limitation: semantic disambiguation of this
                // phrase is not attempted.
                ("the word comma", "the word,"),
            ]
        )
    }

    func testEmailParserTable() {
        assertTransform(
            EmailParser(),
            cases: [
                (
                    "john at cypher dot io",
                    "john@cypher.io"
                ),
                (
                    "john dot smith at cypher dot io",
                    "john.smith@cypher.io"
                ),
                (
                    "jane underscore doe at example dot com",
                    "jane_doe@example.com"
                ),
                (
                    "build dash bot at example dot dev",
                    "build-bot@example.dev"
                ),
                (
                    "user at mail dot cypher dot co dot uk",
                    "user@mail.cypher.co.uk"
                ),
                (
                    "email JOHN at Example dot COM now",
                    "email JOHN@Example.COM now"
                ),
                ("john at localhost", "john at localhost"),
                ("meet john at five", "meet john at five"),
                (
                    "john at server dot 3",
                    "john at server dot 3"
                ),
                (
                    "john@example.com",
                    "john@example.com"
                ),
            ]
        )
    }

    func testURLParserTable() {
        assertTransform(
            URLParser(),
            cases: [
                ("example dot com", "example.com"),
                (
                    "www dot example dot com",
                    "www.example.com"
                ),
                (
                    "example dot com slash docs",
                    "example.com/docs"
                ),
                (
                    "example dot com slash docs slash api",
                    "example.com/docs/api"
                ),
                (
                    "example dot com slash getting dash started",
                    "example.com/getting-started"
                ),
                (
                    "example dot com slash account underscore settings",
                    "example.com/account_settings"
                ),
                (
                    "go to sub dot example dot io now",
                    "go to sub.example.io now"
                ),
                (
                    "example dot com slash",
                    "example.com/"
                ),
                ("turn dot knob", "turn dot knob"),
                ("version one dot two", "version one dot two"),
                (
                    "https://example.com/docs",
                    "https://example.com/docs"
                ),
            ]
        )
    }

    func testNumberParserCardinalTable() {
        assertTransform(
            NumberParser(),
            cases: [
                ("zero", "0"),
                ("five", "5"),
                ("nineteen", "19"),
                ("twenty", "20"),
                ("twenty five", "25"),
                ("twenty-five", "25"),
                ("one hundred", "100"),
                ("one hundred and five", "105"),
                ("nine hundred ninety nine", "999"),
                ("one thousand", "1000"),
                ("twelve thousand three hundred", "12300"),
                ("one million", "1000000"),
                (
                    "two million three hundred thousand five",
                    "2300005"
                ),
                (
                    "nine hundred ninety nine million nine hundred ninety nine thousand nine hundred ninety nine",
                    "999999999"
                ),
            ]
        )
    }

    func testNumberParserCurrencyAndPercentageTable() {
        assertTransform(
            NumberParser(),
            cases: [
                ("five hundred dollars", "$500"),
                ("one dollar", "$1"),
                ("zero dollars", "$0"),
                (
                    "two million dollars",
                    "$2000000"
                ),
                ("five hundred rupees", "₹500"),
                ("one rupee", "₹1"),
                ("twenty five percent", "25%"),
                ("one hundred percentage", "100%"),
                (
                    "budget five hundred dollars today",
                    "budget $500 today"
                ),
            ]
        )
    }

    func testNumberParserAmbiguityGuardsTable() {
        assertTransform(
            NumberParser(),
            cases: [
                ("one and two", "one and two"),
                ("twenty thirteen", "twenty thirteen"),
                ("five six", "five six"),
                ("hundred", "hundred"),
                ("one thousand million", "one thousand million"),
                ("one million two million", "one million two million"),
                ("zero five", "zero five"),
                ("version 2", "version 2"),
            ]
        )
    }

    func testSelfCorrectionsTable() {
        assertTransform(
            SelfCorrections(),
            cases: [
                (
                    "ship it friday, actually monday",
                    "ship it monday"
                ),
                ("send red sorry blue", "send blue"),
                ("call john i mean jane", "call jane"),
                (
                    "meet friday no wait monday",
                    "meet monday"
                ),
                ("paint red rather blue", "paint blue"),
                (
                    "version one make that two",
                    "version two"
                ),
                ("scratch that", ""),
                ("scratch that.", ""),
                (
                    "meet on friday actually next monday",
                    "meet next monday"
                ),
                (
                    "send the red file actually blue file",
                    "send the blue file"
                ),
            ]
        )
    }

    func testSelfCorrectionsLeaveAmbiguityUntouchedTable() {
        assertTransform(
            SelfCorrections(),
            cases: [
                ("actually ship it", "actually ship it"),
                ("sorry about that", "sorry about that"),
                (
                    "tea rather than coffee",
                    "tea rather than coffee"
                ),
                (
                    "red actually blue sorry green",
                    "red actually blue sorry green"
                ),
                (
                    "keep this scratch that",
                    "keep this scratch that"
                ),
                (
                    "one actually a b c d e f g",
                    "one actually a b c d e f g"
                ),
                ("no markers here", "no markers here"),
                ("rather than", "rather than"),
            ]
        )
    }

    func testRepetitionCollapseTable() {
        assertTransform(
            RepetitionCollapse(),
            cases: [
                (
                    "we should we should ship tomorrow",
                    "we should ship tomorrow"
                ),
                (
                    "please send please send the report",
                    "please send the report"
                ),
                ("go go go", "go"),
                ("the the answer", "the answer"),
                (
                    "that is that is correct",
                    "that is correct"
                ),
                (
                    "Ship now ship now please",
                    "Ship now please"
                ),
                ("one one two", "one two"),
                (
                    "we can do it we can do it",
                    "we can do it"
                ),
            ]
        )
    }

    func testRepetitionCollapsePreservesEmphasisTable() {
        assertTransform(
            RepetitionCollapse(),
            cases: [
                (
                    "this is very, very important",
                    "this is very, very important"
                ),
                ("no, no, no", "no, no, no"),
                ("far far-away", "far far-away"),
                ("go—go", "go—go"),
                ("word. word", "word. word"),
                ("yes! yes", "yes! yes"),
                ("had, had", "had, had"),
                (
                    "we should, we should",
                    "we should, we should"
                ),
            ]
        )
    }

    func testFillerRemovalTable() {
        assertTransform(
            FillerRemoval(),
            cases: [
                ("um hello", "hello"),
                ("um, hello", "hello"),
                ("hello uh world", "hello world"),
                ("erm, yes", "yes"),
                ("uhm this works", "this works"),
                ("umbrella", "umbrella"),
                ("like this", "like this"),
                ("you know this", "you know this"),
                ("hello, um, world", "hello, world"),
            ]
        )
    }

    func testDictionarySubstitutionsStageTable() {
        let transform = DictionarySubstitutions(
            entries: [
                DictionaryEntry(wrong: "gpt", right: "GPT"),
                DictionaryEntry(wrong: "iphone", right: "iPhone"),
                DictionaryEntry(wrong: "c plus plus", right: "C++"),
            ]
        )
        assertTransform(
            transform,
            cases: [
                ("gpt", "GPT"),
                ("Gpt", "GPT"),
                ("IPHONE", "iPhone"),
                ("use c plus plus", "use C++"),
                ("gptx", "gptx"),
                ("ungpt", "ungpt"),
                ("gpt iphone", "GPT iPhone"),
                ("  gpt  ", "  GPT  "),
            ]
        )
    }

    func testCapitalizationTable() {
        assertTransform(
            Capitalization(),
            cases: [
                ("hello", "Hello"),
                ("hello. second", "Hello. Second"),
                ("hello? yes", "Hello? Yes"),
                ("hello! yes", "Hello! Yes"),
                ("hello\nsecond", "Hello\nSecond"),
                ("\"hello\"", "\"Hello\""),
                (
                    "visit example.com. next",
                    "Visit example.com. Next"
                ),
                (
                    "john@cypher.io",
                    "John@cypher.io"
                ),
                ("123 hello", "123 hello"),
                ("iPhone works", "IPhone works"),
            ]
        )
    }

    func testPunctuationFinishingTable() {
        assertTransform(
            PunctuationFinishing(),
            cases: [
                ("hello", "hello."),
                ("hello.", "hello."),
                ("hello ?", "hello?"),
                ("hello , world", "hello, world."),
                ("hello;world", "hello; world."),
                ("note:detail", "note: detail."),
                ("first\n second", "first\nsecond."),
                ("\"hello\"", "\"hello.\""),
                ("10:30", "10:30."),
                ("version 1.2", "version 1.2."),
                ("50 %", "50%."),
                ("", ""),
            ]
        )
    }

    func testADRExampleFiveHundredDollars() {
        XCTAssertEqual(NumberParser().apply("five hundred dollars"), "$500")
    }

    func testADRExampleSpokenEmail() {
        XCTAssertEqual(
            EmailParser().apply("john at cypher dot io"),
            "john@cypher.io"
        )
    }

    func testADRExampleSpokenPunctuationPipeline() {
        XCTAssertEqual(
            DeterministicCleaner().clean(
                "hello comma how are you question mark"
            ),
            "Hello, how are you?"
        )
    }

    func testADRExampleSelfCorrectionPipeline() {
        XCTAssertEqual(
            DeterministicCleaner().clean(
                "ship it friday, actually monday"
            ),
            "Ship it monday."
        )
    }

    func testADRExampleImmediateRepetitionPipeline() {
        XCTAssertEqual(
            DeterministicCleaner().clean(
                "we should we should ship tomorrow"
            ),
            "We should ship tomorrow."
        )
    }

    func testADRExampleCommaSeparatedEmphasisIsPreserved() {
        XCTAssertEqual(
            DeterministicCleaner().clean(
                "this is very, very important"
            ),
            "This is very, very important."
        )
    }

    func testFullPipelineRealisticDictationTable() {
        let cleaner = DeterministicCleaner(
            entries: [
                DictionaryEntry(wrong: "gpt", right: "GPT"),
                DictionaryEntry(wrong: "swift ui", right: "SwiftUI"),
            ]
        )
        let cases = [
            (
                "hello comma how are you question mark",
                "Hello, how are you?"
            ),
            (
                "ship it friday comma actually monday",
                "Ship it monday."
            ),
            (
                "we should we should ship tomorrow",
                "We should ship tomorrow."
            ),
            (
                "this is very comma very important",
                "This is very, very important."
            ),
            (
                "um send it to john at cypher dot io",
                "Send it to john@cypher.io."
            ),
            (
                "visit cypher dot io slash docs",
                "Visit cypher.io/docs."
            ),
            (
                "the total is twenty five percent",
                "The total is 25%."
            ),
            (
                "the budget is five hundred dollars",
                "The budget is $500."
            ),
            (
                "first item new line second item",
                "First item\nSecond item."
            ),
            (
                "use gpt semicolon then swift ui",
                "Use GPT; then SwiftUI."
            ),
            (
                "call john sorry jane question mark",
                "Call jane?"
            ),
            (
                "say open quote ship it close quote",
                "Say \"ship it.\""
            ),
        ]

        for (input, expected) in cases {
            XCTAssertEqual(
                cleaner.clean(input),
                expected,
                "input: \(input)"
            )
        }
    }

    func testPipelineOrderPunctuationMustRunBeforeCorrections() {
        let input = "ship it friday comma actually monday"
        let punctuationFirst = SelfCorrections().apply(
            SpokenPunctuation().apply(input)
        )
        let correctionsFirst = SpokenPunctuation().apply(
            SelfCorrections().apply(input)
        )

        XCTAssertEqual(punctuationFirst, "ship it monday")
        XCTAssertNotEqual(correctionsFirst, punctuationFirst)
        XCTAssertEqual(
            DeterministicCleaner().clean(input),
            "Ship it monday."
        )
    }

    private func assertTransform(
        _ transform: any TranscriptTransform,
        cases: [(String, String)],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for (input, expected) in cases {
            XCTAssertEqual(
                transform.apply(input),
                expected,
                "input: \(input)",
                file: file,
                line: line
            )
        }
    }
}
