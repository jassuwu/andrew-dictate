import XCTest

/// The stretch transcriber, driven the way a meeting drives it: through the
/// coordinator, with a fake tap and a fake engine, and judged by what a
/// person or an agent would read — the transcript file and the live lines.
///
/// Speech is a tone and silence is zeros. Every phrase is played at its own
/// loudness and the fake engine knows a phrase by how loud the stretch it was
/// handed is, so a stretch cut in the wrong place comes back as the wrong
/// words, or none.
///
/// The numbers in here follow from three settings: chunks of 100 ms, a
/// loudness detector with a 0.5 s hangover, and the cutter's 0.3 s of
/// pre-roll. A phrase said from 1.3 s is stamped 1.0 s.
///
/// A tone that never changes has no pattern to follow, so where one side has
/// to be told from a copy of the other, speech is a tone in bursts — a few
/// hundred milliseconds of syllable, a breath, the next, each at its own
/// loudness — and each voice has bursts of its own.
@MainActor
final class MeetingStretchTests: XCTestCase {
    private var dir: URL!
    private var source: FakeSource!
    private var engine: PhraseEngine!
    private var diarizer: RecordingDiarizer!
    private var events: [MeetingEvent] = []

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-stretches-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        source = FakeSource()
        engine = PhraseEngine()
        diarizer = RecordingDiarizer()
        events = []
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - who said it, and when

    func testWhatYouSayIsYoursAndStampedWhereYouBeganToSayIt() async throws {
        let c = coordinator(stretches())
        c.start()
        await source.awaitStart()

        await play([you("the deploy is blocked", from: 1.3, to: 2.5)], through: 3.5, on: c)
        await waitFor { c.liveLines.count == 1 }

        XCTAssertEqual(live(c), ["you 1.0 the deploy is blocked"])
        c.stop()
        let lines = try await savedLines()
        XCTAssertEqual(lines, ["[00:00:01] you: the deploy is blocked"])
    }

    /// The speaker is the side it came from — nothing is guessed from who
    /// was louder.
    func testTheFarSideIsThemAndTheTurnsComeInTheOrderTheyWereSaid() async throws {
        let c = coordinator(stretches())
        c.start()
        await source.awaitStart()

        await play([
            them("are we all here", from: 1.3, to: 2.0),
            you("the deploy is blocked", from: 2.8, to: 4.0),
            them("since when", from: 5.3, to: 6.0),
        ], through: 7.0, on: c)
        await waitFor { c.liveLines.count == 3 }

        XCTAssertEqual(live(c), [
            "them 1.0 are we all here",
            "you 2.5 the deploy is blocked",
            "them 5.0 since when",
        ])
        c.stop()
        let lines = try await savedLines()
        XCTAssertEqual(lines, [
            "[00:00:01] them: are we all here",
            "[00:00:02] you: the deploy is blocked",
            "[00:00:05] them: since when",
        ])
    }

    /// A two-word turn at the start, and unrelated speech 15 s on. The first
    /// ended at 1.9 s and the second began at 16.0, so they are two
    /// paragraphs with a time each, not one stamped 1.0 with 14 s of silence
    /// in the middle of it.
    func testSpeechThatPicksUpAfterALongSilenceIsAParagraphOfItsOwn() async throws {
        let c = coordinator(stretches())
        c.start()
        await source.awaitStart()

        await play([
            them("okay so", from: 1.3, to: 1.9),
            them("now about the budget", from: 16.3, to: 17.5),
        ], through: 19.0, on: c)
        await waitFor { c.liveLines.count == 2 }

        XCTAssertEqual(live(c), ["them 1.0 okay so", "them 16.0 now about the budget"])
        c.stop()
        let lines = try await savedLines()
        XCTAssertEqual(lines, [
            "[00:00:01] them: okay so",
            "[00:00:16] them: now about the budget",
        ])
    }

    /// Talking over each other is two people saying two things. Neither is
    /// folded into the other or lost under it.
    func testBothSidesAtOnceIsATurnEach() async throws {
        let c = coordinator(stretches())
        c.start()
        await source.awaitStart()

        await play([
            you("i think we should ship it", from: 1.3, to: 4.0),
            them("no wait", from: 2.3, to: 3.0),
        ], through: 5.0, on: c)
        await waitFor { c.liveLines.count == 2 }

        // the panel shows each as it is decoded, and theirs ended first.
        XCTAssertEqual(live(c), [
            "them 2.0 no wait",
            "you 1.0 i think we should ship it",
        ])
        c.stop()
        let lines = try await savedLines()
        XCTAssertEqual(lines, [
            "[00:00:01] you: i think we should ship it",
            "[00:00:02] them: no wait",
        ])
    }

    /// Every stretch is handed to the engine once, and no sample is in two
    /// of them. With a hangover shorter than the pre-roll, "two" begins
    /// 0.2 s after "one" ended: its pre-roll would reach back into "one",
    /// and stops where "one" did instead.
    func testEachStretchReachesTheEngineOnceAndNoAudioTwice() async throws {
        let c = coordinator(stretches(hangover: .milliseconds(200)))
        c.start()
        await source.awaitStart()

        await play([
            you("one", from: 1.3, to: 2.0),
            you("two", from: 2.2, to: 3.0),
            them("three", from: 3.3, to: 4.5),
        ], through: 5.5, on: c)
        await waitFor { c.liveLines.count == 3 }

        XCTAssertEqual(handed(), ["one 16000", "two 16000", "three 24000"])
        XCTAssertEqual(live(c), ["you 1.0 one", "you 2.0 two", "them 3.0 three"])
        c.stop()
        let lines = try await savedLines()
        // one speaker carrying on is one paragraph in the file; the live
        // lines above are where the two stretches show apart.
        XCTAssertEqual(lines, [
            "[00:00:01] you: one two",
            "[00:00:03] them: three",
        ])
        XCTAssertEqual(handed().count, 3, "stopping decodes nothing again")
    }

    /// Talk past the ceiling is cut at it, and the next stretch starts on
    /// the very next sample: 1.0 to 3.0, 3.0 to 5.0, 5.0 to 6.4 — 5.4 s
    /// handed over for 5.4 s said, pre-roll included.
    func testSpeechLongerThanTheCeilingIsCutIntoStretchesWithNothingLostBetween() async throws {
        let c = coordinator(stretches(ceiling: .seconds(2)))
        c.start()
        await source.awaitStart()

        await play([you("and another thing", from: 1.3, to: 6.4)], through: 7.5, on: c)
        await waitFor { c.liveLines.count == 3 }

        XCTAssertEqual(handed(), [
            "and another thing 32000",
            "and another thing 32000",
            "and another thing 22400",
        ])
        XCTAssertEqual(live(c), [
            "you 1.0 and another thing",
            "you 3.0 and another thing",
            "you 5.0 and another thing",
        ])
        c.stop()
        let lines = try await savedLines()
        XCTAssertEqual(lines, [
            "[00:00:01] you: and another thing and another thing and another thing",
        ])
    }

    /// Talk past the ceiling with a breath in it a second before: the cut
    /// is made in the breath, not at the ceiling in the middle of a word.
    /// Said from 1.3 s with 0.1 s of quiet at 10.0, it is cut 1.0 to 10.075
    /// — the middle of the later 50 ms of the quiet, the one nearer the
    /// ceiling — and goes on from the very next sample to 14.0: 13 s handed
    /// over for 13 s said. Cut at the ceiling, at 11.0, the first stretch
    /// would hold both phrases and be heard as the louder one.
    func testTalkPastTheCeilingIsCutInAQuietMomentBeforeIt() async throws {
        let c = coordinator(stretches(ceiling: .seconds(10)))
        c.start()
        await source.awaitStart()

        await play([
            you("i think the deploy", from: 1.3, to: 10.0),
            you("is blocked", from: 10.1, to: 14.0),
        ], through: 15.0, on: c)
        await waitFor { c.liveLines.count == 2 }

        XCTAssertEqual(handed(), ["i think the deploy 145200", "is blocked 62800"])
        XCTAssertEqual(live(c), ["you 1.0 i think the deploy", "you 10.1 is blocked"])
        c.stop()
        let lines = try await savedLines()
        XCTAssertEqual(lines, ["[00:00:01] you: i think the deploy is blocked"])
    }

    /// No moment in the four seconds before the ceiling is quieter than the
    /// ceiling itself, so that is where it is cut: 1.0 to 11.0, then on from
    /// the next sample to 14.0. A tone is never exactly as loud from one
    /// 50 ms to the next; being a little quieter is not a breath.
    func testTalkWithNoQuietMomentBeforeTheCeilingIsCutAtIt() async throws {
        let c = coordinator(stretches(ceiling: .seconds(10)))
        c.start()
        await source.awaitStart()

        await play([you("and another thing", from: 1.3, to: 14.0)], through: 15.0, on: c)
        await waitFor { c.liveLines.count == 2 }

        XCTAssertEqual(handed(), ["and another thing 160000", "and another thing 48000"])
        XCTAssertEqual(live(c), ["you 1.0 and another thing", "you 11.0 and another thing"])
        c.stop()
        let lines = try await savedLines()
        XCTAssertEqual(lines, ["[00:00:01] you: and another thing and another thing"])
    }

    /// Whisper names a stretch with no words in it rather than leaving it
    /// blank. A name is not a turn: the file and the panel only get words,
    /// and a marker in front of words is taken off them.
    func testMarkersForNoSpeechAndEmptyTextAreNotTurns() async throws {
        let c = coordinator(stretches())
        c.start()
        await source.awaitStart()

        await play([
            you("[BLANK_AUDIO]", from: 1.3, to: 1.8),
            you("(silence)", from: 2.8, to: 3.3),
            you("[ Silence ]", from: 4.3, to: 4.8),
            you("[MUSIC]", from: 5.8, to: 6.3),
            you("", from: 7.3, to: 7.8),
            you("  ", from: 8.8, to: 9.3),
            you("right", from: 10.3, to: 10.8),
            you("[MUSIC] so anyway", from: 11.8, to: 12.3),
        ], through: 13.5, on: c)
        await waitFor { c.liveLines.count == 2 }

        XCTAssertEqual(handed().count, 8, "every stretch was decoded: \(handed())")
        XCTAssertEqual(live(c), ["you 10.0 right", "you 11.5 so anyway"])
        c.stop()
        let lines = try await savedLines()
        XCTAssertEqual(lines, ["[00:00:10] you: right so anyway"])
    }

    // MARK: - a gap

    /// The lid closes at 3.0 s while they are mid-sentence, and the mac
    /// wakes a minute in; the tap comes back stamped 60.0 s and they are
    /// talking again. What was being said is closed at the gap, and what
    /// comes after is stamped on the meeting's clock — 57 s of audio never
    /// reached the spool, so by a count of samples it would read 3.0.
    ///
    /// The diarizer hears the spool, so it is asked about spool time: the
    /// coordinator takes the lost 57 s back off a turn stamped on the
    /// meeting's clock, and lands on 3.0 — where that audio really is.
    func testAfterAGapTheTurnsAreOnTheMeetingsClockAndTheSplitHearsTheSpool() async throws {
        let clock = FakeClock()
        let c = coordinator(stretches(), clock: clock)
        c.start()
        await source.awaitStart()

        await play([them("can you hear me", from: 1.3, to: 3.0)], through: 3.0, on: c)
        clock.advance(by: .seconds(60))
        c.probeTapIsAlive()
        await waitFor { c.state == .rebuilding }
        XCTAssertEqual(c.state, .rebuilding)

        await play([them("you dropped off", from: 60.0, to: 61.0)], from: 60.0, through: 63.0, on: c)
        await waitFor { c.liveLines.count == 2 }

        XCTAssertEqual(live(c), ["them 1.0 can you hear me", "them 60.0 you dropped off"])
        c.stop()
        let lines = try await savedLines()
        XCTAssertEqual(lines, [
            "[00:00:01] them: can you hear me",
            "[00:01:00] them: you dropped off",
        ])
        XCTAssertEqual(diarizer.askedAbout.map(seconds), ["1.0", "3.0"])
    }

    // MARK: - a model that takes its time

    /// Whisper takes ten-odd seconds to load and the tap opens at once.
    /// What is said in those seconds waits for it, rather than being lost.
    func testWhatIsSaidWhileTheModelLoadsIsTranscribedOnceItHas() async throws {
        engine.holdLoading()
        let c = coordinator(stretches())
        c.start()
        await source.awaitStart()

        await play([
            you("can everyone see my screen", from: 1.3, to: 2.5),
            them("yes", from: 3.3, to: 3.8),
        ], through: 5.0, on: c)
        XCTAssertEqual(handed(), [], "nothing reaches a model that has not loaded")
        XCTAssertEqual(live(c), [])

        engine.letLoad()
        await waitFor { c.liveLines.count == 2 }

        XCTAssertEqual(live(c), ["you 1.0 can everyone see my screen", "them 3.0 yes"])
        c.stop()
        let lines = try await savedLines()
        XCTAssertEqual(lines, [
            "[00:00:01] you: can everyone see my screen",
            "[00:00:03] them: yes",
        ])
    }

    /// A one-line call, stopped before the model was ready and while the
    /// line was still being said: stopping waits for the model, and the
    /// words are in the file.
    func testStoppingBeforeTheModelHasLoadedStillSavesTheWords() async throws {
        engine.holdLoading()
        let c = coordinator(stretches())
        c.start()
        await source.awaitStart()

        await play([you("hello", from: 0.3, to: 1.0)], through: 1.0, on: c)
        c.stop()
        try await Task.sleep(for: .milliseconds(300))
        engine.letLoad()

        let lines = try await savedLines()
        XCTAssertEqual(lines, ["[00:00:00] you: hello"])
    }

    /// Out of the coordinator's reach — it always asks the model to load,
    /// and walks away from a meeting whose model would not — so asked of the
    /// transcriber directly: with no model coming, finishing does not wait
    /// for one.
    func testAModelThatNeverLoadedDoesNotHoldUpTheFinish() async throws {
        let neverAsked = stretches()
        await neverAsked.feed(chunk(0, [you("hello", from: 0.0, to: 0.1)]))
        let unasked = await finishInTime(neverAsked)
        XCTAssertEqual(unasked?.isEmpty, true, "finished: \(String(describing: unasked))")

        engine.refuseToLoad()
        let refused = stretches()
        do {
            try await refused.begin()
            XCTFail("the model was meant to refuse")
        } catch {}
        await refused.feed(chunk(0, [you("hello", from: 0.0, to: 0.1)]))
        let failed = await finishInTime(refused)
        XCTAssertEqual(failed?.isEmpty, true, "finished: \(String(describing: failed))")
        XCTAssertEqual(handed(), [])
    }

    // MARK: - an engine that fails

    func testAStretchTheEngineFailsOnOnceIsTriedAgain() async throws {
        engine.failing("the deploy is blocked", times: 1)
        let c = coordinator(stretches())
        c.start()
        await source.awaitStart()

        await play([
            you("the deploy is blocked", from: 1.3, to: 2.5),
            them("since when", from: 3.3, to: 4.0),
        ], through: 5.0, on: c)
        await waitFor { c.liveLines.count == 2 }

        XCTAssertEqual(handed(), [
            "the deploy is blocked 24000",
            "the deploy is blocked 24000",
            "since when 16000",
        ])
        XCTAssertEqual(live(c), ["you 1.0 the deploy is blocked", "them 3.0 since when"])
        c.stop()
        let lines = try await savedLines()
        XCTAssertEqual(lines, [
            "[00:00:01] you: the deploy is blocked",
            "[00:00:03] them: since when",
        ])
    }

    /// Twice is not a hiccup. That stretch is let go, and the queue behind
    /// it carries on to the end of the meeting.
    func testAStretchTheEngineFailsOnTwiceIsSkippedAndTheRestIsSaved() async throws {
        engine.failing("the deploy is blocked", times: 2)
        let c = coordinator(stretches())
        c.start()
        await source.awaitStart()

        await play([
            you("the deploy is blocked", from: 1.3, to: 2.5),
            them("since when", from: 3.3, to: 4.0),
            you("since this morning", from: 5.3, to: 6.0),
        ], through: 7.0, on: c)
        await waitFor { c.liveLines.count == 2 }

        XCTAssertEqual(handed(), [
            "the deploy is blocked 24000",
            "the deploy is blocked 24000",
            "since when 16000",
            "since this morning 16000",
        ])
        XCTAssertEqual(live(c), ["them 3.0 since when", "you 5.0 since this morning"])
        c.stop()
        let lines = try await savedLines()
        XCTAssertEqual(lines, [
            "[00:00:03] them: since when",
            "[00:00:05] you: since this morning",
        ])
    }

    // MARK: - words made up for the quiet

    /// On a mic with nothing on it whisper writes "Thank you." over the room.
    /// Two seconds of that is not a turn, and not a line in the panel. It was
    /// still read, so the coverage check is not told it was left unread; it
    /// is counted as let go.
    func testAQuietStretchReadAsThankYouIsNotATurn() async throws {
        engine.inventsWords(forRoomNoise: ["Thank you."])
        let transcriber = stretches(threshold: Self.faint)
        let c = coordinator(transcriber)
        c.start()
        await source.awaitStart()

        await play([roomNoise(from: 1.3, to: 3.3)], through: 5.0, on: c)
        await waitForStretches(transcriber, 2)

        XCTAssertEqual(live(c), [])
        let tally = await transcriber.tally
        // the other stretch is the hum on the first chunk, 0.1 s of it.
        XCTAssertEqual(tally, StretchTally(
            decodedYou: 1, decodedThem: 1, quietDropped: 1,
            speechYou: .milliseconds(2_300), speechThem: .milliseconds(100),
            readYou: .milliseconds(2_300), readThem: .milliseconds(100)))
        c.stop()
        let lines = try await savedLines()
        XCTAssertEqual(lines, [])
    }

    /// Quiet is not enough: a quiet stretch that comes back as anything but
    /// one of those phrases is words someone said softly.
    func testAQuietStretchReadAsAnythingElseIsKept() async throws {
        engine.inventsWords(forRoomNoise: ["see you tomorrow"])
        let transcriber = stretches(threshold: Self.faint)
        let c = coordinator(transcriber)
        c.start()
        await source.awaitStart()

        await play([roomNoise(from: 1.3, to: 3.3)], through: 5.0, on: c)
        await waitFor { c.liveLines.count == 1 }

        XCTAssertEqual(live(c), ["you 1.0 see you tomorrow"])
        let tally = await transcriber.tally
        XCTAssertEqual(tally.quietDropped, 0)
        c.stop()
        let lines = try await savedLines()
        XCTAssertEqual(lines, ["[00:00:01] you: see you tomorrow"])
    }

    /// And loud is not enough either way: someone who says "thank you" at the
    /// end of a call said it.
    func testALoudStretchThatSaysThankYouIsKept() async throws {
        let transcriber = stretches()
        let c = coordinator(transcriber)
        c.start()
        await source.awaitStart()

        await play([you("Thank you.", from: 1.3, to: 2.3)], through: 4.0, on: c)
        await waitFor { c.liveLines.count == 1 }

        XCTAssertEqual(live(c), ["you 1.0 Thank you."])
        let tally = await transcriber.tally
        XCTAssertEqual(tally.quietDropped, 0)
        c.stop()
        let lines = try await savedLines()
        XCTAssertEqual(lines, ["[00:00:01] you: Thank you."])
    }

    /// The phrases are matched however whisper cases and punctuates them:
    /// each of these, over room noise, is let go.
    func testEveryPhraseWhisperMakesUpOverRoomNoiseIsLetGoHoweverItIsWritten() async throws {
        let written = [
            "Thank you.", "THANK YOU VERY MUCH!", "Thanks for watching!", "Thank you for watching.",
            "Thanks.", "Bye.", "Bye-bye!", "You", "Please subscribe.",
            "Subtitles by the Amara.org community",
        ]
        engine.inventsWords(forRoomNoise: written)
        let transcriber = stretches(threshold: Self.faint)
        let c = coordinator(transcriber)
        c.start()
        await source.awaitStart()

        // 1.2 s of noise, then 1 s of quiet, ten times.
        await play(
            (0..<written.count).map { roomNoise(from: 1.3 + 2.2 * Double($0), to: 2.5 + 2.2 * Double($0)) },
            through: 25.0, on: c)
        await waitForStretches(transcriber, 11)

        XCTAssertEqual(live(c), [])
        let tally = await transcriber.tally
        XCTAssertEqual(tally.quietDropped, 10)
        c.stop()
        let lines = try await savedLines()
        XCTAssertEqual(lines, [])
    }

    // MARK: - a spool found at launch

    /// The app died mid-meeting. At the next launch the spool is read back
    /// whole and goes through the same detector and engine: the same
    /// stretches, stamped from the start of the spool, each decoded once.
    func testASpoolFoundAtLaunchIsCutAndDecodedTheSameWay() async throws {
        let spool = MeetingSpool(root: dir.appendingPathComponent("spool"))
        let handle = try spool.begin(.init(
            app: "teams", started: Date(timeIntervalSince1970: 1_787_000_000),
            engine: "whisper-large-v3-turbo", model: .whisperLargeV3Turbo))
        let file = try SpoolAudioFile(url: handle.audioURL)
        let said = [
            you("are you recording this", from: 1.3, to: 2.5),
            them("i am now", from: 2.3, to: 3.0),
            you("good", from: 4.3, to: 4.8),
        ]
        for k in 0..<60 {
            try await file.append(chunk(k, said))
        }

        let c = coordinator(stretches())
        c.recoverOrphans()

        let lines = try await savedLines()
        XCTAssertEqual(lines, [
            "[00:00:01] you: are you recording this",
            "[00:00:02] them: i am now",
            "[00:00:04] you: good",
        ])
        XCTAssertEqual(handed().count, 3)
    }

    /// The spool is cut the same way, so its turns know where they ended too:
    /// "okay so" ends at 0.5 s and "and the budget" begins at 4.0, a pause of
    /// 3.5 s, though they begin only 4.0 s apart.
    func testASpoolsSpeechAfterALongSilenceIsAParagraphOfItsOwn() async throws {
        _ = try await spoolLeftBehind([
            them("okay so", from: 0.3, to: 0.5),
            them("and the budget", from: 4.3, to: 5.0),
        ])

        let c = coordinator(stretches())
        c.recoverOrphans()

        let lines = try await savedLines()
        XCTAssertEqual(lines, [
            "[00:00:00] them: okay so",
            "[00:00:04] them: and the budget",
        ])
    }

    /// A spool found at launch is read the same way, and the room noise in it
    /// is let go the same way.
    func testASpoolsRoomNoiseReadAsThankYouIsNotATurn() async throws {
        _ = try await spoolLeftBehind([
            roomNoise(from: 1.3, to: 3.3),
            you("are you recording this", from: 4.3, to: 5.3),
        ])
        engine.inventsWords(forRoomNoise: ["Thank you."])

        let transcriber = stretches(threshold: Self.faint)
        let c = coordinator(transcriber)
        c.recoverOrphans()

        let lines = try await savedLines()
        XCTAssertEqual(lines, ["[00:00:04] you: are you recording this"])
        let tally = await transcriber.tally
        XCTAssertEqual(tally.quietDropped, 1)
    }

    /// Every stretch of the spool failed to decode, twice. Writing that out
    /// would save a meeting where nobody spoke and delete the only copy of
    /// what they did say: the spool stays for the next launch instead, with
    /// the try counted against it.
    func testASpoolWhoseEveryStretchFailsIsKeptForTheNextLaunch() async throws {
        let spool = try await spoolLeftBehind([
            you("are you recording this", from: 1.3, to: 2.5),
            them("i am now", from: 2.3, to: 3.0),
        ])
        engine.failing("are you recording this", times: 2)
        engine.failing("i am now", times: 2)

        let c = coordinator(stretches())
        c.recoverOrphans()
        await waitFor { spool.orphans().first?.manifest.attempts == 1 }

        XCTAssertEqual(spool.orphans().map(\.manifest.attempts), [1])
        XCTAssertEqual(handed(), [
            "are you recording this 24000",
            "are you recording this 24000",
            "i am now 16000",
            "i am now 16000",
        ])
        XCTAssertEqual(
            MeetingTranscriptFile.listAll(in: dir.appendingPathComponent("docs")).count, 0)
    }

    /// Nobody spoke: nothing was cut, so nothing failed. That is a meeting
    /// with no turns in it, written out like any other, not a spool kept
    /// back to be tried again at every launch.
    func testASpoolNobodySpokeInIsWrittenOutWithNoTurns() async throws {
        let spool = try await spoolLeftBehind([])

        let c = coordinator(stretches())
        c.recoverOrphans()

        let lines = try await savedLines()
        XCTAssertEqual(lines, [])
        XCTAssertEqual(handed(), [])
        XCTAssertEqual(spool.orphans().count, 0)
    }

    /// A spool is heard the way the meeting was, and the mic's copy of the
    /// far side is let go in it too: the file has them once, and no you.
    func testASpoolWithTheFarSideOnTheMicHasNoYouTurnForIt() async throws {
        let theirs = them("are we all here", from: 1.3, to: 4.3, voice: .theirs)
        _ = try await spoolLeftBehind([theirs, theirs.asBleed()])

        let transcriber = stretches(threshold: Self.keen)
        let c = coordinator(transcriber)
        c.recoverOrphans()

        let lines = try await savedLines()
        XCTAssertEqual(lines, ["[00:00:01] them: are we all here"])
        XCTAssertEqual(handed(), ["are we all here 52800"])
        let tally = await transcriber.tally
        XCTAssertEqual(tally, StretchTally(
            decodedThem: 1, bleed: 1, speechThem: .milliseconds(3_300), readThem: .milliseconds(3_300)))
    }

    // MARK: - the numbers

    /// What the meeting's record will be told: stretches decoded per side,
    /// stretches let go, and how far behind the meeting the decoding ran —
    /// from a stretch joining the queue to its decode finishing.
    ///
    /// Both of the first two join the queue at 0 s and wait out a ten-second
    /// load. The first is done at 11 s; the second fails at 12 and again at
    /// 13. The third joins at 13 and is done at 14.
    func testTheNumbersCountEachSideWhatFailedAndHowFarBehindTheDecodingRan() async throws {
        let wall = FakeClock()
        engine.holdLoading()
        engine.eachDecodeTakes(.seconds(1), on: wall)
        engine.failing("since when", times: 2)
        let transcriber = stretches(clock: wall)
        let c = coordinator(transcriber)
        c.start()
        await source.awaitStart()

        await play([
            you("the deploy is blocked", from: 1.3, to: 2.5),
            them("since when", from: 3.3, to: 4.0),
        ], through: 5.0, on: c)
        wall.advance(by: .seconds(10))
        engine.letLoad()
        await waitFor { handed().count == 3 }

        await play([you("since this morning", from: 5.3, to: 6.0)], from: 5.0, through: 7.0, on: c)
        await waitFor { c.liveLines.count == 2 }

        let tally = await transcriber.tally
        // the far side's second, cut and never read, is speech the file
        // does not have.
        XCTAssertEqual(tally, StretchTally(
            decodedYou: 2, decodedThem: 0, failed: 1,
            mostBehind: .seconds(13), lastBehind: .seconds(1),
            speechYou: .seconds(2.5), speechThem: .seconds(1),
            readYou: .seconds(2.5), readThem: .zero))
    }

    // MARK: - the far side coming back through the mic

    /// On the mac's own speakers the far side leaves them and comes back in
    /// through the mic, a little late and a fifth as loud. Heard apart, that
    /// is a second speaker saying everything they said, and it is you. The
    /// copy is let go before it is decoded; they keep their one line.
    ///
    /// The far side says it from 1.3 to 4.3 s, the mic has it from 1.38 to
    /// 4.38: a stretch 1.08 to 4.38 that is only theirs.
    func testTheFarSideComingBackThroughTheMicIsNotYou() async throws {
        let transcriber = stretches(threshold: Self.keen)
        let c = coordinator(transcriber)
        c.start()
        await source.awaitStart()

        let theirs = them("are we all here", from: 1.3, to: 4.3, voice: .theirs)
        await play([theirs, theirs.asBleed()], through: 6.0, on: c)
        await waitForStretches(transcriber, 2)
        await waitFor { c.liveLines.count == 1 }

        XCTAssertEqual(live(c), ["them 1.0 are we all here"])
        XCTAssertEqual(handed(), ["are we all here 52800"])
        let tally = await transcriber.tally
        // the copy let go is not speech of yours.
        XCTAssertEqual(tally, StretchTally(
            decodedThem: 1, bleed: 1, speechThem: .milliseconds(3_300), readThem: .milliseconds(3_300)))
        c.stop()
        let lines = try await savedLines()
        XCTAssertEqual(lines, ["[00:00:01] them: are we all here"])
    }

    /// Talking over them is not their voice coming back: yours is louder at
    /// the mic than their copy, and rises and falls in its own time, with
    /// theirs a fifth as loud underneath it. The mic has theirs from 1.38 s
    /// and yours from 2.3, one stretch from 1.08 s.
    func testYouTalkingOverTheFarSideAreKept() async throws {
        let transcriber = stretches(threshold: Self.keen)
        let c = coordinator(transcriber)
        c.start()
        await source.awaitStart()

        let theirs = them("are we all here", from: 1.3, to: 4.3, voice: .theirs)
        await play([
            theirs, theirs.asBleed(),
            you("no wait that is wrong", from: 2.3, to: 4.3, voice: .yours),
        ], through: 6.0, on: c)
        await waitForStretches(transcriber, 2)
        await waitFor { c.liveLines.count == 2 }

        XCTAssertEqual(live(c), [
            "them 1.0 are we all here",
            "you 1.1 no wait that is wrong",
        ])
        XCTAssertEqual(handed(), ["are we all here 52800", "no wait that is wrong 52800"])
        let tally = await transcriber.tally
        XCTAssertEqual(tally, StretchTally(
            decodedYou: 1, decodedThem: 1,
            speechYou: .milliseconds(3_300), speechThem: .milliseconds(3_300),
            readYou: .milliseconds(3_300), readThem: .milliseconds(3_300)))
        c.stop()
        let lines = try await savedLines()
        XCTAssertEqual(lines, [
            "[00:00:01] them: are we all here",
            "[00:00:01] you: no wait that is wrong",
        ])
    }

    /// They talk, and you say something else in a pause of theirs. The
    /// copy of what they said is let go; what you said is not, because the
    /// far side was quiet while you said it.
    func testWhatYouSayInAPauseOfTheirsIsKept() async throws {
        let transcriber = stretches(threshold: Self.keen)
        let c = coordinator(transcriber)
        c.start()
        await source.awaitStart()

        let theirs = them("are we all here", from: 1.3, to: 2.5, voice: .theirs)
        await play([
            theirs, theirs.asBleed(),
            you("wait one second", from: 3.3, to: 4.3, voice: .yours),
        ], through: 6.0, on: c)
        await waitForStretches(transcriber, 3)
        await waitFor { c.liveLines.count == 2 }

        XCTAssertEqual(live(c), ["them 1.0 are we all here", "you 3.0 wait one second"])
        XCTAssertEqual(handed(), ["are we all here 24000", "wait one second 20800"])
        let tally = await transcriber.tally
        XCTAssertEqual(tally, StretchTally(
            decodedYou: 1, decodedThem: 1, bleed: 1,
            speechYou: .milliseconds(1_300), speechThem: .seconds(1.5),
            readYou: .milliseconds(1_300), readThem: .seconds(1.5)))
        c.stop()
        let lines = try await savedLines()
        XCTAssertEqual(lines, [
            "[00:00:01] them: are we all here",
            "[00:00:03] you: wait one second",
        ])
    }

    /// "Yes", said over the far side: 0.16 s of tone and 0.3 s of pre-roll,
    /// 0.46 s in all, nine frames to compare. Nine frames of loudness agree
    /// by chance as easily as by being a copy — this one agrees at 0.84 with
    /// what they were saying — so a stretch this short is kept, whatever the
    /// comparison says.
    func testAMicStretchTooShortToJudgeIsKept() async throws {
        let transcriber = stretches()
        let c = coordinator(transcriber)
        c.start()
        await source.awaitStart()

        let theirs = them("are we all here", from: 1.3, to: 5.3, voice: .theirs)
        await play([theirs, theirs.asBleed(), you("yes", from: 2.2, to: 2.36)], through: 7.0, on: c)
        await waitForStretches(transcriber, 2)
        await waitFor { c.liveLines.count == 2 }

        XCTAssertEqual(live(c), ["you 1.9 yes", "them 1.0 are we all here"])
        XCTAssertEqual(handed(), ["yes 7360", "are we all here 68800"])
        let tally = await transcriber.tally
        XCTAssertEqual(tally, StretchTally(
            decodedYou: 1, decodedThem: 1,
            speechYou: .milliseconds(460), speechThem: .milliseconds(4_300),
            readYou: .milliseconds(460), readThem: .milliseconds(4_300)))
        c.stop()
        let lines = try await savedLines()
        XCTAssertEqual(lines, ["[00:00:01] them: are we all here", "[00:00:01] you: yes"])
    }

    // MARK: - the decision alone

    /// Loudness for 40 frames of 50 ms — two seconds — none of them quiet. The
    /// far side's, and an unrelated one for the mic.
    private static let theirFrames: [Float] = [
        0.04, 0.03, 0.06, 0.03, 0.09, 0.09, 0.09, 0.08, 0.05, 0.03, 0.09, 0.02, 0.08, 0.08,
        0.02, 0.09, 0.06, 0.05, 0.03, 0.07, 0.02, 0.02, 0.02, 0.10, 0.02, 0.08, 0.05, 0.08,
        0.02, 0.10, 0.05, 0.09, 0.09, 0.10, 0.05, 0.07, 0.05, 0.05, 0.09, 0.06,
    ]
    private static let otherFrames: [Float] = [
        0.06, 0.04, 0.10, 0.10, 0.08, 0.03, 0.03, 0.08, 0.05, 0.04, 0.06, 0.06, 0.05, 0.09,
        0.02, 0.08, 0.06, 0.08, 0.02, 0.07, 0.05, 0.04, 0.09, 0.02, 0.10, 0.10, 0.09, 0.08,
        0.03, 0.02, 0.05, 0.05, 0.09, 0.08, 0.09, 0.10, 0.10, 0.04, 0.03, 0.02,
    ]

    /// A side's loudness, a value to each 50 ms from the start of the meeting:
    /// every frame a square wave at exactly that loudness.
    private func trail(_ frames: [Float]) -> LoudnessTrail {
        var trail = LoudnessTrail()
        trail.hear(frames.flatMap { rms in (0..<800).map { $0.isMultiple(of: 2) ? rms : -rms } }, at: .zero)
        return trail
    }

    /// What the mic makes of a far side: a fifth as loud, `delay` frames late.
    private func copy(of frames: [Float], late delay: Int = 0) -> [Float] {
        [Float](repeating: 0, count: delay) + frames.dropLast(delay).map { $0 * 0.2 }
    }

    /// The far side with nothing said in its first `frames`.
    private func theirsAfter(_ quiet: Int) -> [Float] {
        [Float](repeating: 0, count: quiet) + Self.theirFrames.dropFirst(quiet)
    }

    /// The decision for a stretch of the mic, by default from 0.5 s to 1.5 s:
    /// frames 10 up to 30, with the 6 before for the delay.
    private func verdict(
        mic: [Float], far: [Float],
        from: Duration = .milliseconds(500), to: Duration = .milliseconds(1500)
    ) -> BleedJudge.Verdict {
        BleedJudge.verdict(mic: trail(mic), far: trail(far), from: from, to: to)
    }

    /// The mic is theirs when it rises and falls as they did, whatever its
    /// loudness, and however long ago they did it — as long as that is no
    /// more than 300 ms, which is six frames.
    func testAMicThatFollowsTheFarSideAtAnyDelayUpToThreeHundredMillisecondsIsBleed() {
        let theirs = Self.theirFrames
        XCTAssertEqual(verdict(mic: theirs, far: theirs), .drop, "as loud, and no later")
        for frames in 0...6 {
            XCTAssertEqual(
                verdict(mic: copy(of: theirs, late: frames), far: theirs), .drop,
                "\(frames * 50) ms late")
        }
        for frames in 7...8 {
            XCTAssertEqual(
                verdict(mic: copy(of: theirs, late: frames), far: theirs), .keep,
                "\(frames * 50) ms late is past what the room can do")
        }
    }

    /// Two people say two things: what the mic does has nothing to do with
    /// what the far side did.
    func testAMicThatRisesAndFallsInItsOwnTimeIsKept() {
        XCTAssertEqual(verdict(mic: Self.otherFrames, far: Self.theirFrames), .keep)
    }

    /// Nobody was talking at the far end, so there was nothing to hear again.
    func testAMicWithAFarSideThatSaidNothingIsKept() {
        XCTAssertEqual(
            verdict(mic: Self.otherFrames, far: [Float](repeating: 0, count: 40)), .keep)
        XCTAssertEqual(
            verdict(mic: copy(of: Self.theirFrames), far: [Float](repeating: 0, count: 40)), .keep)
    }

    /// A second is the least that is judged: 1 s is twenty frames, and
    /// 0.95 s is nineteen. Shorter than that, a "yes" said over the far side
    /// agrees with it by chance too often to risk.
    func testASecondIsTheLeastThatIsJudged() {
        let theirs = Self.theirFrames
        XCTAssertEqual(
            verdict(mic: copy(of: theirs), far: theirs, from: .milliseconds(500), to: .milliseconds(1500)),
            .drop)
        XCTAssertEqual(
            verdict(mic: copy(of: theirs), far: theirs, from: .milliseconds(500), to: .milliseconds(1450)),
            .keep)
    }

    /// Their loudness is the evidence, and only where they were talking. A mic
    /// that follows a far side exactly is still not hearing it if the far
    /// side was quiet for most of the stretch — the quiet is what is shared.
    func testAFarSideQuietForMoreThanThreeTenthsOfTheStretchIsNotWhatTheMicHeard() {
        // quiet for 8 frames of the 20, then talking: copied to the letter.
        XCTAssertEqual(
            verdict(mic: copy(of: theirsAfter(18)), far: theirsAfter(18)), .keep)
        // quiet for 4 of the 20: talking through most of it.
        XCTAssertEqual(
            verdict(mic: copy(of: theirsAfter(14)), far: theirsAfter(14)), .drop)
    }

    /// Too quiet to be heard at all, as loud as the room it is in: nothing
    /// came out of the speakers to come back.
    func testAFarSideBelowTheFloorIsNotWhatTheMicHeard() {
        let faint = Self.theirFrames.map { $0 * 0.08 }
        XCTAssertEqual(verdict(mic: copy(of: faint), far: faint), .keep)
    }

    /// A tone that holds its loudness has no pattern to follow. Its frames
    /// still differ a hair — by where in a cycle each began — and two such
    /// tones differ in the same hairs, so they would agree perfectly. That
    /// is two people with steady voices, not an echo.
    func testALoudnessThatHardlyMovesIsNotAPatternToFollow() {
        let steady: [Float] = (0..<40).map { 0.05 + 0.0005 * Float($0 % 3) }
        XCTAssertEqual(verdict(mic: copy(of: steady), far: steady), .keep)
    }

    /// A stretch is judged on what the trails hold. A minute of it is held
    /// and no more, so a stretch from further back than that, one that runs
    /// past what has been heard, and one so near the start of the meeting
    /// that the delay has nothing to look at, are all kept.
    func testAStretchTheTrailsDoNotHoldInFullIsKept() {
        // 70 s of the same bursts over and over, the mic a copy of them.
        let theirs = (0..<1_400).map { Self.theirFrames[$0 % 40] }
        let mic = trail(copy(of: theirs, late: 2))
        let far = trail(theirs)
        func judged(_ from: Duration, _ to: Duration) -> BleedJudge.Verdict {
            BleedJudge.verdict(mic: mic, far: far, from: from, to: to)
        }

        XCTAssertEqual(judged(.seconds(60), .seconds(61)), .drop, "the same stretch, still held")
        XCTAssertEqual(judged(.seconds(5), .seconds(6)), .keep, "more than a minute ago")
        XCTAssertEqual(judged(.milliseconds(69_500), .milliseconds(70_500)), .keep, "not heard yet")
        XCTAssertEqual(
            judged(.milliseconds(100), .milliseconds(1_100)), .keep, "no room before it for the delay")
    }

    // MARK: - building a meeting

    private func stretches(
        ceiling: Duration = .seconds(25),
        hangover: Duration = .milliseconds(500),
        threshold: Float = 0.02,
        clock: FakeClock = FakeClock()
    ) -> StretchTranscriber {
        StretchTranscriber(
            engine: engine,
            ceiling: ceiling,
            detector: { LoudnessDetector(threshold: threshold, hangover: hangover) },
            now: { clock.now })
    }

    /// A detector keen enough to hear the far side coming back through the
    /// mic, which is a fifth as loud as it left: the voice model on a real
    /// mac is. Still above the hum on the far side's first chunk.
    private static let keen: Float = 0.006

    /// A detector that hears a mic with nothing on it, which is a tone this
    /// quiet: 0.002 at the loudest. It hears the hum on the first chunk too.
    private static let faint: Float = 0.001

    private func coordinator(
        _ transcriber: StretchTranscriber,
        clock: FakeClock = FakeClock()
    ) -> MeetingCoordinator {
        let folder = dir.appendingPathComponent("docs")
        let c = MeetingCoordinator(
            source: source,
            makeTranscriber: { _ in transcriber },
            diarizer: diarizer,
            spool: MeetingSpool(root: dir.appendingPathComponent("spool")),
            hookRunner: HookRunner(logURL: dir.appendingPathComponent("hooks.log")),
            // nobody here is testing the tap: the far side may be quiet for
            // as long as a test likes without it being called a dead tap.
            thresholds: .init(
                probeTimeout: .seconds(1), silenceTimeout: .seconds(600),
                silenceFloor: 0.001, quietNudgeAfter: .seconds(3_600)),
            now: { clock.now },
            preferences: {
                MeetingPreferences(folder: folder, hook: nil, model: .whisperLargeV3Turbo)
            }
        )
        c.onEvent = { [weak self] in self?.events.append($0) }
        return c
    }

    /// The spool of a meeting the app died in: six seconds of it, in the
    /// chunks the tap would have handed over, waiting in the spool folder
    /// for the next launch.
    private func spoolLeftBehind(_ said: [Said]) async throws -> MeetingSpool {
        let spool = MeetingSpool(root: dir.appendingPathComponent("spool"))
        let handle = try spool.begin(.init(
            app: "teams", started: Date(timeIntervalSince1970: 1_787_000_000),
            engine: "whisper-large-v3-turbo", model: .whisperLargeV3Turbo))
        let file = try SpoolAudioFile(url: handle.audioURL)
        for k in 0..<60 {
            try await file.append(chunk(k, said))
        }
        return spool
    }

    private struct Said {
        let side: Stretch.Side
        let phrase: String
        let from: Double
        let to: Double
        /// How loud it is from one moment to the next. A flat tone when nil.
        var voice: Voice?
        var scale: Float = 1

        /// What the mic makes of this when it is the far side's, played out
        /// of the mac's speakers: a little late and a fifth as loud.
        func asBleed(after delay: Double = 0.08, scale: Float = 0.2) -> Said {
            Said(
                side: .you, phrase: phrase, from: from + delay, to: to + delay,
                voice: voice, scale: scale)
        }
    }

    /// Syllables: each is a tone at its own loudness for `on` seconds and
    /// then quiet for `gap`, and the voice goes round them again from the
    /// first when it runs out. Its loudest syllable is 1, so a phrase is
    /// still as loud as the engine knows it by.
    private struct Voice {
        let syllables: [(on: Double, gap: Double, level: Float)]

        func level(at t: Double) -> Float {
            var left = t.truncatingRemainder(dividingBy: syllables.reduce(0) { $0 + $1.on + $1.gap })
            for syllable in syllables {
                if left < syllable.on { return syllable.level }
                left -= syllable.on
                if left < syllable.gap { return 0 }
                left -= syllable.gap
            }
            return 0
        }

        /// The far side's: 2.14 s to go round.
        static let theirs = Voice(syllables: [
            (0.16, 0.04, 1.0), (0.12, 0.08, 0.6), (0.20, 0.04, 0.8), (0.14, 0.06, 0.4),
            (0.18, 0.10, 0.9), (0.10, 0.04, 0.5), (0.16, 0.06, 0.7), (0.22, 0.04, 1.0),
            (0.12, 0.08, 0.3), (0.14, 0.06, 0.8),
        ])

        /// Yours: its own rhythm, and a length that does not go into theirs.
        static let yours = Voice(syllables: [
            (0.13, 0.05, 0.7), (0.19, 0.07, 1.0), (0.11, 0.09, 0.4), (0.17, 0.05, 0.9),
            (0.15, 0.11, 0.6), (0.21, 0.05, 0.5), (0.12, 0.07, 1.0), (0.18, 0.06, 0.3),
            (0.14, 0.04, 0.8),
        ])
    }

    private func you(_ phrase: String, from: Double, to: Double, voice: Voice? = nil) -> Said {
        Said(side: .you, phrase: phrase, from: from, to: to, voice: voice)
    }

    private func them(_ phrase: String, from: Double, to: Double, voice: Voice? = nil) -> Said {
        Said(side: .them, phrase: phrase, from: from, to: to, voice: voice)
    }

    /// The mic with nothing on it: a tone a thirtieth as loud as the first
    /// phrase played, 0.003 at its loudest and about 0.002 RMS, nowhere near
    /// speech. Play it before any phrase, so it is that first one.
    private func roomNoise(from: Double, to: Double) -> Said {
        Said(side: .you, phrase: "room noise", from: from, to: to, scale: 0.03)
    }

    /// The meeting from `start` to `end` seconds, a 100 ms chunk at a time,
    /// stamped on the meeting's clock. The first chunk of a meeting carries a
    /// hum on the far side, under any detector's threshold, so the probe is
    /// heard and the recording starts.
    ///
    /// It returns once the coordinator has taken the last chunk in. The one
    /// before it is fed by then, so every test ends on a second of silence.
    private func play(
        _ said: [Said], from start: Double = 0, through end: Double,
        on c: MeetingCoordinator
    ) async {
        let first = Int((start * 10).rounded())
        let last = Int((end * 10).rounded())
        for k in first..<last {
            source.send(chunk(k, said))
        }
        await waitFor { c.elapsed >= .milliseconds(100 * last - 1) }
        try? await Task.sleep(for: .milliseconds(100))
    }

    private func chunk(_ k: Int, _ said: [Said]) -> MeetingAudioChunk {
        let n = 1_600
        let first = k * n
        var you = [Float](repeating: 0, count: n)
        var them = [Float](repeating: k == 0 ? 0.005 : 0, count: n)
        for line in said {
            let from = max(first, Int((line.from * 16_000).rounded()))
            let to = min(first + n, Int((line.to * 16_000).rounded()))
            guard from < to else { continue }
            let loudness = engine.loudness(of: line.phrase) * line.scale
            let began = Int((line.from * 16_000).rounded())
            for i in from..<to {
                let level = line.voice?.level(at: Double(i - began) / 16_000) ?? 1
                let sample = sin(Float(i) * 0.05) * loudness * level
                // two lines on one side are heard together.
                switch line.side {
                case .you: you[i - first] += sample
                case .them: them[i - first] += sample
                }
            }
        }
        return MeetingAudioChunk(you: you, them: them, at: .milliseconds(100 * k))
    }

    // MARK: - reading it back

    /// The turn lines of the one transcript the meeting saved, once it is
    /// on disk.
    private func savedLines() async throws -> [String] {
        let folder = dir.appendingPathComponent("docs")
        await waitFor(10) { !MeetingTranscriptFile.listAll(in: folder).isEmpty }
        let saved = try XCTUnwrap(
            MeetingTranscriptFile.listAll(in: folder).first, "nothing saved: \(events)")
        let body = try String(contentsOf: saved.fileURL, encoding: .utf8)
        return body.split(separator: "\n").filter { $0.hasPrefix("[") }.map(String.init)
    }

    private func live(_ c: MeetingCoordinator) -> [String] {
        c.liveLines.map { line in
            let who = line.speaker == .you ? "you" : "them"
            let confirmed = line.isConfirmed ? "" : " (tentative)"
            return "\(who) \(seconds(line.at)) \(line.text)\(confirmed)"
        }
    }

    /// What the engine was handed, in order: the phrase it heard and how
    /// many samples it heard it in.
    private func handed() -> [String] {
        engine.handed.map { "\($0.phrase) \($0.samples)" }
    }

    private func seconds(_ duration: Duration) -> String {
        String(format: "%.1f", duration.totalSeconds)
    }

    /// `finish`, given five seconds. `nil` if it took longer: a finish that
    /// hangs fails the test instead of hanging the suite.
    private func finishInTime(_ transcriber: StretchTranscriber) async -> [MeetingTurn]? {
        let finished = Finished()
        Task { finished.turns = await transcriber.finish() }
        await waitFor { finished.turns != nil }
        return finished.turns
    }

    /// Polls until the transcriber has dealt with `count` stretches, one way
    /// or another: decoded, failed, or let go as bleed.
    private func waitForStretches(_ transcriber: StretchTranscriber, _ count: Int) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            let tally = await transcriber.tally
            if tally.decodedYou + tally.decodedThem + tally.failed + tally.bleed >= count { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Polls until `condition` holds or the time is up; the assertion after
    /// it says what was there instead.
    private func waitFor(_ seconds: Double = 5, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

// MARK: - fakes

/// A wall the test moves by hand.
private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private let origin = ContinuousClock.now
    private var offset: Duration = .zero

    var now: ContinuousClock.Instant {
        lock.withLock { origin + offset }
    }

    func advance(by amount: Duration) {
        lock.withLock { offset += amount }
    }
}

private final class FakeSource: MeetingAudioSource, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<MeetingAudioChunk>.Continuation?

    func start() async throws -> AsyncStream<MeetingAudioChunk> {
        let (stream, continuation) = AsyncStream<MeetingAudioChunk>.makeStream()
        lock.withLock { self.continuation = continuation }
        return stream
    }

    func rebuild() async throws {}

    func stop() async {
        lock.withLock { continuation }?.finish()
    }

    func send(_ chunk: MeetingAudioChunk) {
        _ = lock.withLock { continuation }?.yield(chunk)
    }

    func awaitStart() async {
        while lock.withLock({ continuation == nil }) {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private struct Garbled: Error {}

private final class Finished: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [MeetingTurn]?

    var turns: [MeetingTurn]? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Knows a phrase by its loudness: the test plays phrase n at 0.1 × n, and a
/// stretch is heard as the phrase whose loudness its peak is nearest to.
/// Silence is heard as nothing at all.
///
/// Words are words however quiet: a stretch a fifth as loud as phrase n —
/// the phrase coming back through the mic — is heard as phrase n. Only for
/// the first two phrases: a fifth of any later one is as loud as an earlier
/// phrase, and is heard as that.
private final class PhraseEngine: StretchEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var phrases: [String] = []
    private var decoded: [(phrase: String, samples: Int)] = []
    private var failures: [String: Int] = [:]
    private var isHeld = false
    private var refuses = false
    private var wall: FakeClock?
    private var eachDecode: Duration = .zero
    private var invented: [String] = []

    func loudness(of phrase: String) -> Float {
        lock.withLock {
            if !phrases.contains(phrase) { phrases.append(phrase) }
            return 0.1 * Float(phrases.firstIndex(of: phrase)! + 1)
        }
    }

    /// Every decode, failed or not, moves `wall` on by `duration`.
    func eachDecodeTakes(_ duration: Duration, on wall: FakeClock) {
        lock.withLock {
            self.wall = wall
            eachDecode = duration
        }
    }

    /// What whisper writes over a mic with nothing on it: each stretch of
    /// room noise a second long or more — too quiet to be words — is heard
    /// as the next of `texts`, and as nothing once they run out. A blip
    /// shorter than that, like the hum on the first chunk, is heard as
    /// nothing.
    func inventsWords(forRoomNoise texts: [String]) {
        lock.withLock { invented = texts }
    }

    /// The next `times` stretches heard as `phrase` throw instead.
    func failing(_ phrase: String, times: Int) {
        lock.withLock { failures[phrase] = times }
    }

    /// Every stretch the engine was handed, failed or not, as the phrase it
    /// heard and its length in samples, in the order it was handed them.
    var handed: [(phrase: String, samples: Int)] {
        lock.withLock { decoded }
    }

    /// `load` does not return until `letLoad`.
    func holdLoading() {
        lock.withLock { isHeld = true }
    }

    func letLoad() {
        lock.withLock { isHeld = false }
    }

    func refuseToLoad() {
        lock.withLock { refuses = true }
    }

    func load() async throws {
        while lock.withLock({ isHeld }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        if lock.withLock({ refuses }) { throw Garbled() }
    }

    func text(of samples: [Float]) async throws -> String {
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        return try lock.withLock {
            let index = Int((peak * 10).rounded()) - 1
            let quiet = Int((peak * 50).rounded()) - 1
            var phrase = ""
            if peak >= 0.05 {
                phrase = phrases.indices.contains(index) ? phrases[index] : "?"
            } else if peak >= 0.015 {
                phrase = phrases.indices.contains(quiet) ? phrases[quiet] : ""
            } else if samples.count >= 16_000, !invented.isEmpty {
                phrase = invented.removeFirst()
            }
            decoded.append((phrase, samples.count))
            wall?.advance(by: eachDecode)
            if let left = failures[phrase], left > 0 {
                failures[phrase] = left - 1
                throw Garbled()
            }
            return phrase
        }
    }
}

/// Splits nobody; remembers the times it was asked about.
private final class RecordingDiarizer: MeetingDiarizer, @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [Duration] = []

    var askedAbout: [Duration] {
        lock.withLock { asked }
    }

    func split(them: [Float], turns: [MeetingTurn]) async -> [MeetingTurn] {
        lock.withLock { asked += turns.map(\.at) }
        return turns
    }
}
