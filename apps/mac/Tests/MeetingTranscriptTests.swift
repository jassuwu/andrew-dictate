import XCTest

final class MeetingTranscriptTests: XCTestCase {
    private var parent: URL!
    private let tz = TimeZone(identifier: "Asia/Kolkata")!

    override func setUpWithError() throws {
        parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-transcript-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: parent)
    }

    // MARK: - naming

    func testSlugKeepsLettersAndDigitsOnly() {
        XCTAssertEqual(MeetingTranscriptFile.slug("zoom.us"), "zoom-us")
        XCTAssertEqual(MeetingTranscriptFile.slug("Google Chrome"), "google-chrome")
        XCTAssertEqual(MeetingTranscriptFile.slug("  --Teams 2--  "), "teams-2")
        XCTAssertEqual(MeetingTranscriptFile.slug("!!!"), "meeting")
    }

    func testFileURLHasNoSpacesAndAMonthFolder() {
        let url = MeetingTranscriptFile.fileURL(
            in: parent, started: started(), app: "zoom", timeZone: tz)
        XCTAssertEqual(
            url.path,
            parent.appendingPathComponent("meetings/2026-08/2026-08-29-1402-zoom.md").path
        )
        XCTAssertFalse(url.path.contains(" "))
    }

    func testFileURLStepsAsideWhenTheNameIsTaken() throws {
        let first = MeetingTranscriptFile.fileURL(
            in: parent, started: started(), app: "zoom", timeZone: tz)
        try FileManager.default.createDirectory(
            at: first.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "x".write(to: first, atomically: true, encoding: .utf8)
        let second = MeetingTranscriptFile.fileURL(
            in: parent, started: started(), app: "zoom", timeZone: tz)
        XCTAssertEqual(second.lastPathComponent, "2026-08-29-1402-zoom-2.md")
    }

    // MARK: - markdown

    func testACompleteTranscriptRendersFrontMatterAndTurns() {
        let transcript = MeetingTranscript(
            app: "zoom",
            started: started(),
            duration: .seconds(6120),
            engine: "whisper-large-v3-turbo",
            gaps: [],
            recovered: false,
            turns: [
                .init(speaker: .you, at: .seconds(4), text: "hi, can you hear me?"),
                .init(speaker: .them(1), at: .seconds(9), text: "yes. the deploy is blocked."),
                .init(speaker: .them(nil), at: .seconds(724), text: "let's move on."),
            ]
        )
        let expected = """
        ---
        app: zoom
        started: 2026-08-29T14:02:11+05:30
        ended: 2026-08-29T15:44:11+05:30
        duration_s: 6120
        engine: whisper-large-v3-turbo
        speakers: [you, them 1, them]
        words: 13
        complete: true
        gaps: []
        recovered: false
        ---

        [00:00:04] you: hi, can you hear me?

        [00:00:09] them 1: yes. the deploy is blocked.

        [00:12:04] them: let's move on.

        """
        XCTAssertEqual(MeetingTranscriptFile.markdown(transcript, timeZone: tz), expected)
    }

    func testAnIncompleteTranscriptSaysWhereTheHolesAre() {
        let transcript = MeetingTranscript(
            app: "chrome",
            started: started(),
            duration: .seconds(100),
            engine: "whisper-large-v3-turbo",
            gaps: [.init(began: .seconds(41.25), ended: .seconds(63))],
            recovered: true,
            turns: [.init(speaker: .you, at: .zero, text: "hello")]
        )
        let expected = """
        ---
        app: chrome
        started: 2026-08-29T14:02:11+05:30
        ended: 2026-08-29T14:03:51+05:30
        duration_s: 100
        engine: whisper-large-v3-turbo
        speakers: [you]
        words: 1
        complete: false
        reason: audio was lost in 1 gap
        gaps:
        - [41.2, 63.0]
        recovered: true
        ---

        > 1 gap — audio was lost between 00:00:41 and 00:01:03

        [00:00:00] you: hello

        """
        XCTAssertEqual(MeetingTranscriptFile.markdown(transcript, timeZone: tz), expected)
    }

    // MARK: - turns

    func testConsecutiveLinesBySameSpeakerAreOneParagraph() throws {
        let url = try MeetingTranscriptFile.write(
            meeting(turns: [
                .init(speaker: .you, at: .seconds(4), text: "so the thing is"),
                .init(speaker: .you, at: .seconds(9), text: "we shipped it on friday."),
                .init(speaker: .them(nil), at: .seconds(15), text: "right."),
                .init(speaker: .you, at: .seconds(20), text: "and nobody noticed."),
            ]),
            in: parent, timeZone: tz)

        XCTAssertEqual(
            try body(of: url),
            """
            [00:00:04] you: so the thing is we shipped it on friday.

            [00:00:15] them: right.

            [00:00:20] you: and nobody noticed.
            """)
    }

    /// A monologue stays findable: a minute after a paragraph began, the same
    /// speaker's next line opens a new one.
    func testALongMonologueStartsANewParagraphEveryMinute() throws {
        let url = try MeetingTranscriptFile.write(
            meeting(turns: [
                .init(speaker: .you, at: .seconds(5), text: "one"),
                .init(speaker: .you, at: .seconds(30), text: "two"),
                .init(speaker: .you, at: .seconds(55), text: "three"),
                .init(speaker: .you, at: .seconds(64), text: "four"),
                .init(speaker: .you, at: .seconds(70), text: "five"),
                .init(speaker: .you, at: .seconds(130), text: "six"),
            ]),
            in: parent, timeZone: tz)

        XCTAssertEqual(
            try body(of: url),
            """
            [00:00:05] you: one two three four

            [00:01:10] you: five

            [00:02:10] you: six
            """)
    }

    /// Talk that carries on is one paragraph; talk that picks up again after
    /// a silence is a new one, with its own time.
    func testAPauseStartsANewParagraph() throws {
        let url = try MeetingTranscriptFile.write(
            meeting(turns: [
                .init(speaker: .you, at: .seconds(5), text: "can you hear me"),
                .init(speaker: .you, at: .seconds(50), text: "you dropped off."),
            ]),
            in: parent, timeZone: tz)

        XCTAssertEqual(
            try body(of: url),
            """
            [00:00:05] you: can you hear me

            [00:00:50] you: you dropped off.
            """)
    }

    /// A turn that says where it ended is judged by the quiet after it, not
    /// by where the next began: this one ran 4 s, and talk that begins 5 s
    /// after that is a new paragraph, though it began only 9 s after the
    /// first did.
    func testTalkThatBeginsFiveSecondsAfterTheLastTurnEndedIsANewParagraph() throws {
        let url = try MeetingTranscriptFile.write(
            meeting(turns: [
                .init(speaker: .them(nil), at: .seconds(10), text: "hello", end: .seconds(14)),
                .init(speaker: .them(nil), at: .seconds(19), text: "can we start", end: .seconds(22)),
            ]),
            in: parent, timeZone: tz)

        XCTAssertEqual(
            try body(of: url),
            """
            [00:00:10] them: hello

            [00:00:19] them: can we start
            """)
    }

    func testTalkThatBeginsTwoSecondsAfterTheLastTurnEndedIsTheSameParagraph() throws {
        let url = try MeetingTranscriptFile.write(
            meeting(turns: [
                .init(speaker: .them(nil), at: .seconds(10), text: "hello", end: .seconds(14)),
                .init(speaker: .them(nil), at: .seconds(16), text: "can we start", end: .seconds(19)),
            ]),
            in: parent, timeZone: tz)

        XCTAssertEqual(try body(of: url), "[00:00:10] them: hello can we start")
    }

    /// The pause is measured from the end of the turn just before, and only
    /// when that one says where it ended. One that does not is held to the 30 s
    /// between beginnings, however the turns around it end.
    func testATurnWithNoEndIsJudgedByWhereItBeganAndTheNextByWhereItEnded() throws {
        let url = try MeetingTranscriptFile.write(
            meeting(turns: [
                .init(speaker: .you, at: .seconds(5), text: "one"),
                .init(speaker: .you, at: .seconds(34), text: "two", end: .seconds(36)),
                .init(speaker: .you, at: .seconds(38), text: "three", end: .seconds(39)),
                .init(speaker: .you, at: .seconds(45), text: "four"),
                .init(speaker: .you, at: .seconds(70), text: "five"),
                .init(speaker: .you, at: .seconds(101), text: "six"),
            ]),
            in: parent, timeZone: tz)

        XCTAssertEqual(
            try body(of: url),
            """
            [00:00:05] you: one two three

            [00:00:45] you: four five

            [00:01:41] you: six
            """)
    }

    /// Talk with no pause in it is still cut every minute, so a long
    /// monologue stays findable: each turn here begins a second after the one
    /// before ended.
    func testAMonologueWithNoPauseInItStillStartsANewParagraphEveryMinute() throws {
        let url = try MeetingTranscriptFile.write(
            meeting(turns: [
                .init(speaker: .you, at: .seconds(0), text: "a", end: .seconds(24)),
                .init(speaker: .you, at: .seconds(25), text: "b", end: .seconds(49)),
                .init(speaker: .you, at: .seconds(50), text: "c", end: .seconds(74)),
                .init(speaker: .you, at: .seconds(75), text: "d", end: .seconds(99)),
                .init(speaker: .you, at: .seconds(100), text: "e", end: .seconds(124)),
                .init(speaker: .you, at: .seconds(125), text: "f", end: .seconds(149)),
                .init(speaker: .you, at: .seconds(150), text: "g", end: .seconds(174)),
            ]),
            in: parent, timeZone: tz)

        XCTAssertEqual(
            try body(of: url),
            """
            [00:00:00] you: a b c

            [00:01:15] you: d e f

            [00:02:30] you: g
            """)
    }

    func testTwoFarSideVoicesAreNotMergedIntoOne() throws {
        let url = try MeetingTranscriptFile.write(
            meeting(turns: [
                .init(speaker: .them(1), at: .seconds(3), text: "can you hear me"),
                .init(speaker: .them(1), at: .seconds(6), text: "okay good."),
                .init(speaker: .them(2), at: .seconds(8), text: "i can."),
                .init(speaker: .them(2), at: .seconds(11), text: "go ahead."),
                .init(speaker: .them(nil), at: .seconds(14), text: "thanks."),
            ]),
            in: parent, timeZone: tz)

        XCTAssertEqual(
            try body(of: url),
            """
            [00:00:03] them 1: can you hear me okay good.

            [00:00:08] them 2: i can. go ahead.

            [00:00:14] them: thanks.
            """)
    }

    // MARK: - front matter

    func testTheFrontMatterSaysWhenTheMeetingEnded() throws {
        let url = try MeetingTranscriptFile.write(
            meeting(duration: .seconds(6120), turns: []), in: parent, timeZone: tz)

        let front = try frontMatter(of: url)
        XCTAssertEqual(front["started"], "2026-08-29T14:02:11+05:30")
        XCTAssertEqual(front["ended"], "2026-08-29T15:44:11+05:30")
    }

    /// The clocks are real and the file shows whole seconds: `ended` must sit
    /// exactly `duration_s` after `started` as written, not a second off
    /// because of the fractions that were rounded away.
    func testEndedIsExactlyTheDurationAfterTheStartAsWritten() throws {
        let url = try MeetingTranscriptFile.write(
            MeetingTranscript(
                app: "zoom", started: started().addingTimeInterval(0.7),
                duration: .seconds(100.9), engine: "e", gaps: [],
                recovered: false, turns: []),
            in: parent, timeZone: tz)

        let front = try frontMatter(of: url)
        XCTAssertEqual(front["started"], "2026-08-29T14:02:11+05:30")
        XCTAssertEqual(front["duration_s"], "100")
        XCTAssertEqual(front["ended"], "2026-08-29T14:03:51+05:30")
    }

    func testTheFrontMatterListsTheSpeakersInOrderOfFirstAppearance() throws {
        let url = try MeetingTranscriptFile.write(
            meeting(turns: [
                .init(speaker: .them(1), at: .seconds(2), text: "morning."),
                .init(speaker: .you, at: .seconds(5), text: "hi."),
                .init(speaker: .them(2), at: .seconds(8), text: "hello."),
                .init(speaker: .them(1), at: .seconds(12), text: "shall we?"),
                .init(speaker: .you, at: .seconds(15), text: "yes."),
            ]),
            in: parent, timeZone: tz)

        XCTAssertEqual(try frontMatter(of: url)["speakers"], "[them 1, you, them 2]")
    }

    func testAMeetingNobodySpokeInHasNoSpeakers() throws {
        let url = try MeetingTranscriptFile.write(
            meeting(turns: []), in: parent, timeZone: tz)

        XCTAssertEqual(try frontMatter(of: url)["speakers"], "[]")
    }

    func testTheFrontMatterCountsTheWordsOfEveryTurn() throws {
        let url = try MeetingTranscriptFile.write(
            meeting(turns: [
                .init(speaker: .you, at: .seconds(4), text: "hi,  can you\thear me?"),
                .init(speaker: .you, at: .seconds(9), text: ""),
                .init(speaker: .them(1), at: .seconds(12), text: "yes. the deploy is blocked."),
                .init(speaker: .them(1), at: .seconds(20), text: "let's move on."),
            ]),
            in: parent, timeZone: tz)

        XCTAssertEqual(try frontMatter(of: url)["words"], "13")
    }

    func testAMeetingNobodySpokeInHasNoWords() throws {
        let url = try MeetingTranscriptFile.write(
            meeting(turns: []), in: parent, timeZone: tz)

        XCTAssertEqual(try frontMatter(of: url)["words"], "0")
    }

    func testAnIncompleteTranscriptSaysWhyWithOneGap() throws {
        let url = try MeetingTranscriptFile.write(
            meeting(
                gaps: [.init(began: .seconds(41), ended: .seconds(63))],
                turns: []),
            in: parent, timeZone: tz)

        let front = try frontMatter(of: url)
        XCTAssertEqual(front["complete"], "false")
        XCTAssertEqual(front["reason"], "audio was lost in 1 gap")
    }

    func testTheDefaultReasonCountsTheGaps() throws {
        let url = try MeetingTranscriptFile.write(
            meeting(
                gaps: [
                    .init(began: .seconds(41), ended: .seconds(63)),
                    .init(began: .seconds(200), ended: .seconds(215)),
                ],
                turns: []),
            in: parent, timeZone: tz)

        XCTAssertEqual(try frontMatter(of: url)["reason"], "audio was lost in 2 gaps")
    }

    func testAReasonGivenByTheCallerReplacesTheDefault() throws {
        let url = try MeetingTranscriptFile.write(
            MeetingTranscript(
                app: "zoom", started: started(), duration: .seconds(600),
                engine: "e", gaps: [.init(began: .seconds(41), ended: .seconds(63))],
                recovered: false, reason: "the meeting model changed halfway",
                turns: []),
            in: parent, timeZone: tz)

        XCTAssertEqual(
            try frontMatter(of: url)["reason"], "the meeting model changed halfway")
    }

    func testACompleteTranscriptHasNoReason() throws {
        let url = try MeetingTranscriptFile.write(
            meeting(turns: [.init(speaker: .you, at: .seconds(1), text: "hi")]),
            in: parent, timeZone: tz)

        let front = try frontMatter(of: url)
        XCTAssertEqual(front["complete"], "true")
        XCTAssertNil(front["reason"])
    }

    // MARK: - round trip

    func testWriteThenSummaryReadsTheFrontMatterBack() throws {
        let transcript = MeetingTranscript(
            app: "teams",
            started: started(),
            duration: .seconds(3601),
            engine: "whisper-large-v3-turbo",
            gaps: [
                .init(began: .seconds(1), ended: .seconds(2)),
                .init(began: .seconds(5), ended: .seconds(9)),
            ],
            recovered: false,
            turns: []
        )
        let url = try MeetingTranscriptFile.write(transcript, in: parent, timeZone: tz)
        let summary = try MeetingTranscriptFile.summary(of: url)
        XCTAssertEqual(summary.fileURL, url)
        XCTAssertEqual(summary.app, "teams")
        XCTAssertEqual(summary.started.timeIntervalSince1970,
                       started().timeIntervalSince1970, accuracy: 0.5)
        XCTAssertEqual(summary.duration, .seconds(3601))
        XCTAssertFalse(summary.complete)
        XCTAssertEqual(summary.gapCount, 2)
        XCTAssertFalse(summary.recovered)
    }

    /// Meetings recorded before the layout changed are still in people's
    /// folders: no `ended`, `speakers` or `words`, a line per fragment.
    func testATranscriptWrittenBeforeTheNewLayoutIsStillRead() throws {
        let month = parent.appendingPathComponent("meetings/2026-07", isDirectory: true)
        try FileManager.default.createDirectory(
            at: month, withIntermediateDirectories: true)
        let old = month.appendingPathComponent("2026-07-02-0900-teams.md")
        try """
        ---
        app: teams
        started: 2026-07-02T09:00:05+05:30
        duration_s: 1800
        engine: whisper-large-v3
        complete: false
        gaps:
        - [41.2, 63.0]
        - [100.0, 104.5]
        recovered: true
        ---

        > 2 gaps — audio was lost between 00:00:41 and 00:01:03, and between 00:01:40 and 00:01:44

        [00:00:04] you: hi, can you

        [00:00:06] you: hear me?

        [00:00:09] them: yes.

        """.write(to: old, atomically: true, encoding: .utf8)
        let newer = try MeetingTranscriptFile.write(
            meeting(turns: [.init(speaker: .you, at: .seconds(1), text: "hi")]),
            in: parent, timeZone: tz)

        let summary = try MeetingTranscriptFile.summary(of: old)
        XCTAssertEqual(summary.app, "teams")
        XCTAssertEqual(summary.started.timeIntervalSince1970, 1_782_963_005, accuracy: 0.5)
        XCTAssertEqual(summary.duration, .seconds(1800))
        XCTAssertFalse(summary.complete)
        XCTAssertEqual(summary.gapCount, 2)
        XCTAssertTrue(summary.recovered)

        XCTAssertEqual(
            MeetingTranscriptFile.listAll(in: parent).map(\.fileURL), [newer, old])
    }

    func testSummaryOfAFileWithoutFrontMatterThrows() throws {
        let url = parent.appendingPathComponent("notes.md")
        try "just some notes".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try MeetingTranscriptFile.summary(of: url))
    }

    func testListAllIsNewestFirstAndSkipsJunk() throws {
        let older = MeetingTranscript(
            app: "zoom", started: started(), duration: .seconds(1),
            engine: "e", gaps: [], recovered: false, turns: [])
        let newer = MeetingTranscript(
            app: "slack", started: started().addingTimeInterval(86_400 * 40),
            duration: .seconds(1), engine: "e", gaps: [], recovered: false, turns: [])
        _ = try MeetingTranscriptFile.write(older, in: parent, timeZone: tz)
        _ = try MeetingTranscriptFile.write(newer, in: parent, timeZone: tz)
        let junk = parent.appendingPathComponent("meetings/2026-08/todo.md")
        try "- [ ] nothing".write(to: junk, atomically: true, encoding: .utf8)

        let all = MeetingTranscriptFile.listAll(in: parent)
        XCTAssertEqual(all.map(\.app), ["slack", "zoom"])
    }

    func testListAllOfAMissingFolderIsEmpty() {
        XCTAssertEqual(
            MeetingTranscriptFile.listAll(
                in: parent.appendingPathComponent("nope")).count, 0)
    }

    // MARK: - the note for agents

    /// An agent told "a meeting happened" opens the folder cold. The note is
    /// the one file in it that says what the rest are.
    func testWritingATranscriptLeavesANoteBesideTheMonths() throws {
        try MeetingTranscriptFile.write(
            meeting(turns: []), in: parent, timeZone: tz)

        let note = parent.appendingPathComponent("meetings/README.md")
        let text = try String(contentsOf: note, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "\n").first, "# meeting transcripts")
        XCTAssertTrue(text.contains("meetings/YYYY-MM/YYYY-MM-DD-HHmm-app.md"))
        XCTAssertEqual(permissions(of: note), 0o600)
    }

    func testANoteSomeoneElseWroteIsLeftAlone() throws {
        let folder = parent.appendingPathComponent("meetings", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true)
        let note = folder.appendingPathComponent("README.md")
        try "my own notes about these".write(to: note, atomically: true, encoding: .utf8)

        try MeetingTranscriptFile.write(meeting(turns: []), in: parent, timeZone: tz)
        try MeetingTranscriptFile.write(meeting(turns: []), in: parent, timeZone: tz)

        XCTAssertEqual(
            try String(contentsOf: note, encoding: .utf8), "my own notes about these")
    }

    func testTheNoteIsNeverListedAsAMeeting() throws {
        let url = try MeetingTranscriptFile.write(
            meeting(turns: []), in: parent, timeZone: tz)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: parent.appendingPathComponent("meetings/README.md").path))

        XCTAssertEqual(MeetingTranscriptFile.listAll(in: parent).map(\.fileURL), [url])
    }

    /// The note is only worth having if it is the whole story: every key the
    /// writer puts at the top of a file is explained in it.
    func testTheNoteExplainsEveryKeyAFileCarries() throws {
        let url = try MeetingTranscriptFile.write(
            meeting(
                gaps: [.init(began: .seconds(41), ended: .seconds(63))],
                turns: [.init(speaker: .you, at: .seconds(1), text: "hi")]),
            in: parent, timeZone: tz)
        let note = try String(
            contentsOf: parent.appendingPathComponent("meetings/README.md"),
            encoding: .utf8)

        let keys = try frontMatter(of: url).keys
        XCTAssertEqual(
            Set(keys),
            ["app", "started", "ended", "duration_s", "engine", "speakers",
             "words", "complete", "reason", "gaps", "recovered"])
        for key in keys {
            XCTAssertTrue(note.contains("`\(key)`"), "\(key) is not in the note")
        }
    }

    // MARK: - who can read it

    /// The one file that holds other people's words was the one file left at
    /// the OS default. Both nouns agree now.
    func testTheTranscriptIsNotReadableByOtherUsers() throws {
        let url = try MeetingTranscriptFile.write(
            MeetingTranscript(
                app: "zoom", started: started(), duration: .seconds(61),
                engine: "e", gaps: [], recovered: false, turns: []),
            in: parent, timeZone: tz)

        XCTAssertEqual(permissions(of: url), 0o600)
        XCTAssertEqual(permissions(of: url.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(
            permissions(of: parent.appendingPathComponent("meetings", isDirectory: true)),
            0o700)
    }

    func testLockDownRepairsTranscriptsAlreadyOnDisk() throws {
        let month = parent.appendingPathComponent("meetings/2026-08", isDirectory: true)
        try FileManager.default.createDirectory(
            at: month, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])
        let old = month.appendingPathComponent("2026-08-29-1717-arc.md")
        try "---\napp: arc\n---\n".write(to: old, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: old.path)

        MeetingTranscriptFile.lockDown(in: parent)

        XCTAssertEqual(permissions(of: old), 0o600)
        XCTAssertEqual(permissions(of: month), 0o700)
        XCTAssertEqual(
            permissions(of: parent.appendingPathComponent("meetings", isDirectory: true)),
            0o700)
    }

    // MARK: -

    private func meeting(
        duration: Duration = .seconds(600),
        gaps: [MeetingSession.Gap] = [],
        turns: [MeetingTurn]
    ) -> MeetingTranscript {
        MeetingTranscript(
            app: "zoom", started: started(), duration: duration,
            engine: "whisper-large-v3-turbo", gaps: gaps, recovered: false,
            turns: turns)
    }

    /// Everything the file says after its front matter, without the blank
    /// lines that frame it.
    private func body(of url: URL) throws -> String {
        let text = try String(contentsOf: url, encoding: .utf8)
        let close = try XCTUnwrap(text.range(of: "\n---\n"))
        return text[close.upperBound...].trimmingCharacters(in: .newlines)
    }

    /// The `key: value` lines between the two `---`, by key. List items such
    /// as the gaps have no key and are left out.
    private func frontMatter(of url: URL) throws -> [String: String] {
        let lines = try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: "\n")
        let close = try XCTUnwrap(lines.dropFirst().firstIndex(of: "---"))
        var fields: [String: String] = [:]
        for line in lines[1..<close] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields[String(line[..<colon])] = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
        }
        return fields
    }

    private func permissions(of url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
    }

    private func started() -> Date {
        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 29
        components.hour = 14; components.minute = 2; components.second = 11
        components.timeZone = tz
        return Calendar(identifier: .gregorian).date(from: components)!
    }
}
