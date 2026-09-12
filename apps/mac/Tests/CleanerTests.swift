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

    /// the user-visible half of ADR 0038: you taught it `iPhone` for exactly
    /// one reason, and position zero is where the old pipeline overruled you.
    func testATaughtWordKeepsItsSpellingAtTheStartOfALine() {
        let cleaner = DeterministicCleaner(
            entries: [DictionaryEntry(wrong: "iphone", right: "iPhone")]
        )

        XCTAssertEqual(
            cleaner.clean("iphone battery is fine"),
            "iPhone battery is fine."
        )
    }

    func testWordBoundariesProtectPartialMatches() {
        let cleaner = DeterministicCleaner(
            entries: [DictionaryEntry(wrong: "gpt", right: "GPT")]
        )

        XCTAssertEqual(cleaner.clean("umbrella gptx"), "Umbrella gptx.")
    }

    /// ADR 0020: "um" is a word you said. The cleaner renders speech as
    /// writing; it does not edit you.
    func testFillersAreLeftWhereYouSaidThem() {
        let cleaner = DeterministicCleaner()

        XCTAssertEqual(
            cleaner.clean("um, I uh think erm, this uhm works"),
            "Um, I uh think erm, this uhm works."
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

    func testDictionaryOnlyPassPreservesSurroundingText() {
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
                // "at" is how everyone names a website out loud, so an
                // ordinary word on the left of it is a preposition, not a
                // mailbox.
                (
                    "look at github dot com",
                    "look at github dot com"
                ),
                (
                    "the docs are at example dot com",
                    "the docs are at example dot com"
                ),
                (
                    "you can find it at cypher dot io",
                    "you can find it at cypher dot io"
                ),
                (
                    "he works at meta dot com now",
                    "he works at meta dot com now"
                ),
                (
                    "we host it at fly dot io",
                    "we host it at fly dot io"
                ),
                (
                    "sign up at notion dot so",
                    "sign up at notion dot so"
                ),
                (
                    "read more at anthropic dot com slash news",
                    "read more at anthropic dot com slash news"
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
                // a bare count is a word — nobody types "1 of the".
                ("zero", "zero"),
                ("five", "five"),
                ("one of my keyboards", "one of my keyboards"),
                ("no one knows", "no one knows"),
                ("one on one meeting", "one on one meeting"),
                ("two-ish years", "two-ish years"),
                ("a year or two", "a year or two"),
                ("one-way", "one-way"),
                ("nineteen", "19"),
                ("twenty", "20"),
                ("twenty five", "25"),
                ("twenty-five", "25"),
                ("one hundred", "100"),
                ("one hundred and five", "105"),
                ("nine hundred ninety nine", "999"),
                ("one thousand", "1000"),
                ("ten thousand", "10,000"),
                ("twelve thousand three hundred", "12,300"),
                ("one million", "1,000,000"),
                // a year is not a quantity — the grouping floor leaves it be
                ("two thousand twenty six", "2026"),
                (
                    "two million three hundred thousand five",
                    "2,300,005"
                ),
                (
                    "nine hundred ninety nine million nine hundred ninety nine thousand nine hundred ninety nine",
                    "999,999,999"
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
                    "$2,000,000"
                ),
                ("fifty thousand rupees", "₹50,000"),
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

    /// These were the transform's showcase cases until ticket 004. Each is a
    /// genuine spoken correction, and none of them is rewritten any more —
    /// because the same pattern that catches them also fires on ordinary
    /// speech, silently. They are flagged for the model instead; see
    /// `testMarkersStillFlagTheTranscriptForTheModel`.
    /// ADR 0020, the whole of it in one table. Each of these was rewritten by
    /// a stage that no longer exists, and each rewrite was indistinguishable
    /// from a clean success — which is what made them worse than the stumble
    /// they were removing.
    func testTheCleanerNeverRewritesTheWordsYouSaid() {
        let cleaner = DeterministicCleaner()
        let cases = [
            // self-corrections: ordinary english that lost its subject
            (
                "I actually finished the report last night",
                "I actually finished the report last night."
            ),
            (
                "we should actually ship this today",
                "we should actually ship this today."
            ),
            (
                "there is no wait time on the free tier",
                "there is no wait time on the free tier."
            ),
            ("do not scratch that surface", "do not scratch that surface."),
            // self-corrections: genuine corrections, now left for the model
            ("call john i mean jane", "call john i mean jane."),
            ("scratch that", "scratch that."),
            // repetition: intended repetition that was collapsed
            (
                "I had had enough of the flakiness",
                "I had had enough of the flakiness."
            ),
            ("that that guy said was wrong", "that that guy said was wrong."),
            ("it is very very slow right now", "it is very very slow right now."),
            // repetition: a genuine stumble, now left for the model
            (
                "we should we should ship tomorrow",
                "we should we should ship tomorrow."
            ),
            // fillers
            ("the um value should be higher", "the um value should be higher."),
        ]

        for (input, expected) in cases {
            XCTAssertEqual(
                cleaner.clean(input),
                expected.prefix(1).uppercased() + expected.dropFirst(),
                "input: \(input)"
            )
        }
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
                    // an address is not a sentence — capitalising it gives
                    // you John@cypher.io, which is nobody's email.
                    "john@cypher.io",
                    "john@cypher.io"
                ),
                ("123 hello", "123 hello"),
                // a capital past the first character is a spelling somebody
                // chose. without one there is nothing to protect, so the
                // sentence start still wins.
                ("iPhone works", "iPhone works"),
                ("macOS 26 is out", "macOS 26 is out"),
                ("gRPC is fast", "gRPC is fast"),
                ("iphone works", "Iphone works"),
            ]
        )
    }

    /// the caret was sitting after "the build failed because ", so the
    /// utterance is the rest of that sentence — everything inside it still
    /// starts sentences the way it always did.
    func testCapitalizationContinuingASentenceTable() {
        assertTransform(
            Capitalization(continuingASentence: true),
            cases: [
                (
                    "the linker ran out of memory",
                    "the linker ran out of memory"
                ),
                ("hello. second", "hello. Second"),
                ("hello\nsecond", "hello\nSecond"),
                (
                    "john@cypher.io is mine",
                    "john@cypher.io is mine"
                ),
            ]
        )
    }

    /// only the capital is held back: the words still get their full stop.
    func testAContinuationStillGetsItsTerminalPeriod() {
        XCTAssertEqual(
            DeterministicCleaner().clean(
                "the linker ran out of memory",
                continuingASentence: true
            ),
            "the linker ran out of memory."
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
                // an utterance that ends on an address ends there
                ("john@cypher.io", "john@cypher.io"),
                ("visit cypher.io/docs", "visit cypher.io/docs"),
                ("", ""),
            ]
        )
    }

    /// the pipeline proof for the grouping comma: PunctuationFinishing's
    /// after-separator rule wants a letter next, and a digit is not one, so
    /// nothing creeps in between the 50 and the 000.
    func testAGroupedPriceKeepsItsCommaClosed() {
        XCTAssertEqual(
            DeterministicCleaner().clean(
                "fifty thousand rupees is just ten percent"
            ),
            "₹50,000 is just 10%."
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

    /// ADR 0019's original worked example, amended by ticket 004. The
    /// deterministic pass no longer guesses at the correction; it punctuates
    /// and capitalises, and leaves the words the user said.
    /// ADR 0019's worked examples for the two removed stages, kept as
    /// regressions under ADR 0020's rule: the words survive.
    func testADRRemovedStagesLeaveTheirWorkedExamplesAlone() {
        XCTAssertEqual(
            DeterministicCleaner().clean("ship it friday, actually monday"),
            "Ship it friday, actually monday."
        )
        XCTAssertEqual(
            DeterministicCleaner().clean("we should we should ship tomorrow"),
            "We should we should ship tomorrow."
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
                "Ship it friday, actually monday."
            ),
            (
                "we should we should ship tomorrow",
                "We should we should ship tomorrow."
            ),
            (
                "this is very comma very important",
                "This is very, very important."
            ),
            (
                // no full stop: mail refuses a recipient with a dot on the
                // end, and the link 404s with one.
                "um send it to john at cypher dot io",
                "Um send it to john@cypher.io"
            ),
            (
                "visit cypher dot io slash docs",
                "Visit cypher.io/docs"
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
                "Call john sorry jane?"
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

    /// the whole pipeline is the only place this shows: EmailParser has to
    /// hand the sentence on, because only URLParser can turn "slash news"
    /// into a path. swallow the span and the "at" becomes an @.
    func testSayingAWebsiteOutLoudStaysAWebsite() {
        let cleaner = DeterministicCleaner()

        XCTAssertEqual(
            cleaner.clean("read more at anthropic dot com slash news"),
            "Read more at anthropic.com/news"
        )
        XCTAssertEqual(
            cleaner.clean("sign up at notion dot so"),
            "Sign up at notion.so"
        )
        XCTAssertEqual(
            cleaner.clean("her email is sarah at gmail dot com"),
            "Her email is sarah@gmail.com"
        )
    }

    /// an address, a clock time and a thousands separator all carry a dot or
    /// a comma that is not sentence punctuation. four stages used to read
    /// them as one; they now ask AddressToken the same question.
    func testAnAddressATimeAndAPriceArriveIntact() {
        let cleaner = DeterministicCleaner()
        let cases = [
            ("john at cypher dot io", "john@cypher.io"),
            ("cypher dot io slash docs", "cypher.io/docs"),
            ("go to seven dot com", "Go to seven.com"),
            ("go to example.com", "Go to example.com"),
            (
                "send the invoice at five dot com",
                "Send the invoice@five.com"
            ),
            (
                "let's meet at 10:30 tomorrow",
                "Let's meet at 10:30 tomorrow."
            ),
            ("it cost 3,500 dollars", "It cost 3,500 dollars."),
            // and the prose that must not move
            ("hello,world", "Hello, world."),
            ("version 1.2", "Version 1.2."),
            (
                "i met him at home. great to see him",
                "I met him at home. Great to see him."
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

    /// the space between two dictations is added at the cursor, not here:
    /// the cleaner's output is flush at both ends, and that flush string is
    /// what dictations.jsonl keeps.
    func testTheCleanerStillReturnsAFlushString() {
        let cleaned = DeterministicCleaner().clean("second thing")

        XCTAssertEqual(cleaned, "Second thing.")
        XCTAssertEqual(
            cleaned,
            cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// the whole pipeline, not one stage: a time, an amount, a version, a
    /// filename and an address are punctuation parakeet wrote itself, and
    /// the cleaner has no business re-spacing any of it. every one of these
    /// was split and shouted before the spoken-punctuation stage learned to
    /// stand down.
    func testTheModelsOwnPunctuationSurvivesTheWholePipeline() {
        let cleaner = DeterministicCleaner()
        let cases = [
            ("7 p.m. tomorrow", "7 p.m. tomorrow."),
            ("9 a.m. then", "9 a.m. then."),
            ("1.5 GB", "1.5 GB."),
            ("10:30", "10:30."),
            ("meet at 8:30", "Meet at 8:30."),
            ("20,000", "20,000."),
            ("the file is main.swift", "The file is main.swift."),
            (
                "Check https://example.com/docs",
                "Check https://example.com/docs"
            ),
            (
                "Send it to jass@jass.gg now",
                "Send it to jass@jass.gg now."
            ),
            ("the U.S. team", "The U.S. team."),
        ]

        for (input, expected) in cases {
            XCTAssertEqual(
                cleaner.clean(input),
                expected,
                "input: \(input)"
            )
        }
    }

    /// the other half of the same fix: when a marker *did* fire, the stage
    /// still spaces its own symbols — and still leaves the model's alone.
    func testSpokenMarkersStillPunctuateAndStillSpareTheDigits() {
        let cleaner = DeterministicCleaner()
        let cases = [
            ("ship it comma then tell me", "Ship it, then tell me."),
            ("hello comma world question mark", "Hello, world?"),
            (
                "he said open quote hello close quote to me",
                "He said \"hello\" to me."
            ),
            (
                "para one new paragraph para two",
                "Para one\n\nPara two."
            ),
            (
                "the price comma 20,000 rupees",
                "The price, 20,000 rupees."
            ),
            (
                "meet at 8:30 comma bring the 1.5 GB drive",
                "Meet at 8:30, bring the 1.5 GB drive."
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

    /// ADR 0019's order contract still bites, on a narrower case than it used
    /// to. `SelfCorrections` now only recognises a whole utterance that is
    /// exactly "scratch that" — so whether the trailing spoken "period" has
    /// already become a full stop decides whether the utterance is discarded.
    /// ADR 0019's "pipeline order is law" still binds. The correction stage
    /// it originally protected is gone (ADR 0020), but capitalization still
    /// depends on sentence boundaries that only spoken punctuation can
    /// create, so the two cannot be reordered.
    func testPipelineOrderPunctuationMustRunBeforeCapitalization() {
        let input = "hello period how are you"
        let punctuationFirst = Capitalization().apply(
            SpokenPunctuation().apply(input)
        )
        let capitalizationFirst = SpokenPunctuation().apply(
            Capitalization().apply(input)
        )

        XCTAssertEqual(punctuationFirst, "Hello. How are you")
        XCTAssertNotEqual(capitalizationFirst, punctuationFirst)
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
