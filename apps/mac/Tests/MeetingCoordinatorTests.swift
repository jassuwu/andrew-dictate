import XCTest

@MainActor
final class MeetingCoordinatorTests: XCTestCase {
    private var dir: URL!
    private var source: FakeSource!
    private var transcriber: FakeTranscriber!
    private var transcribers: FakeTranscribers!
    private var events: [MeetingEvent] = []
    private var hookRuns: [HookRun] = []
    /// What settings say right now, read whenever the coordinator asks.
    private var meetingsFolder: URL!
    private var meetingModel: MeetingModel = .whisperLargeV3Turbo
    private var hook: URL?

    private let zoom = RunningApp(name: "zoom.us", bundleID: "us.zoom.xos", pid: 42)

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-coordinator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        source = FakeSource()
        transcriber = FakeTranscriber()
        transcribers = FakeTranscribers(otherwise: transcriber)
        events = []
        hookRuns = []
        meetingsFolder = dir.appendingPathComponent("docs")
        meetingModel = .whisperLargeV3Turbo
        hook = nil
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    /// `starting` is the date each meeting starts on, in order; a meeting
    /// past the end of it starts now.
    private func coordinator(
        thresholds: MeetingThresholds = .init(
            probeTimeout: .seconds(1), silenceTimeout: .seconds(5),
            silenceFloor: 0.001, quietNudgeAfter: .seconds(30)),
        clock: FakeClock = FakeClock(),
        starting dates: [Date] = []
    ) -> MeetingCoordinator {
        let dates = StartDates(dates)
        let c = MeetingCoordinator(
            source: source,
            makeTranscriber: { [transcribers] _ in transcribers!.next() },
            diarizer: FakeDiarizer(),
            spool: MeetingSpool(root: dir.appendingPathComponent("spool")),
            hookRunner: HookRunner(logURL: dir.appendingPathComponent("hooks.log")),
            thresholds: thresholds,
            now: { clock.now },
            date: { dates.next() },
            preferences: { [unowned self] in
                MeetingPreferences(folder: meetingsFolder, hook: hook, model: meetingModel)
            }
        )
        c.onEvent = { [weak self] in self?.events.append($0) }
        c.recordHookRun = { [weak self] in self?.hookRuns.append($0) }
        return c
    }

    // MARK: -

    func testHearingTheProbeStartsTheRecording() async throws {
        let c = coordinator()
        c.start(tapping: zoom)
        await source.awaitStart()
        XCTAssertEqual(c.state, .provingItCanHear)

        source.send(loud(at: .zero))
        await settle()

        XCTAssertEqual(c.state, .recording)
        XCTAssertEqual(events, [.started(app: "zoom")])
        XCTAssertEqual(c.dictationResponse, .refuseAndSayWhy)
    }

    func testSilenceThroughTheProbeMeansItCannotHear() async throws {
        let c = coordinator()
        c.start(tapping: zoom)
        await source.awaitStart()

        source.send(quiet(at: .zero))
        source.send(quiet(at: .seconds(2)))
        await settle()

        // "can't hear" is said once and the session ends — the menu must
        // never read "recording" over a tap that delivered nothing.
        XCTAssertEqual(c.state, .idle)
        XCTAssertEqual(events, [.cannotHear(app: "zoom")])
        // the pill ignores the mouse, so it points at setup rather than at a
        // switch the user would then have to go and find.
        XCTAssertEqual(events.first?.hudText, "can't hear zoom — opening setup")
        XCTAssertEqual(c.dictationResponse, .allow)
        XCTAssertEqual(MeetingSpool(root: dir.appendingPathComponent("spool")).orphans().count, 0)
    }

    func testStoppingWritesTheFileDeletesTheSpoolAndRunsTheHook() async throws {
        hook = try script("#!/bin/sh\ncat > \"$ANDREW_FOLDER/seen.json\"\nexit 0\n")
        transcriber.finalTurns = [
            .init(speaker: .you, at: .seconds(1), text: "hello"),
            .init(speaker: .them(nil), at: .seconds(2), text: "hi"),
        ]
        let c = coordinator()
        c.start(tapping: zoom)
        await source.awaitStart()
        source.send(loud(at: .zero))
        source.send(loud(at: .seconds(1)))
        await settle()

        c.stop()
        await settle(for: 1.5)

        XCTAssertEqual(c.state, .idle)
        let all = MeetingTranscriptFile.listAll(in: dir.appendingPathComponent("docs"))
        XCTAssertEqual(all.count, 1)
        let saved = try XCTUnwrap(all.first)
        XCTAssertEqual(saved.app, "zoom")
        XCTAssertTrue(saved.complete)
        let body = try String(contentsOf: saved.fileURL, encoding: .utf8)
        XCTAssertTrue(body.contains("[00:00:02] them 1: hi"), body)

        XCTAssertTrue(events.contains(.writingItOut))
        XCTAssertTrue(events.contains(.saved(saved)))
        XCTAssertEqual(hookRuns.map(\.outcome), [.succeeded])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: saved.fileURL.deletingLastPathComponent().appendingPathComponent("seen.json").path))
        XCTAssertEqual(MeetingSpool(root: dir.appendingPathComponent("spool")).orphans().count, 0)
    }

    func testAFailingHookIsAnnounced() async throws {
        hook = try script("#!/bin/sh\nexit 7\n")
        let c = coordinator()
        c.start(tapping: zoom)
        await source.awaitStart()
        source.send(loud(at: .zero))
        await settle()
        c.stop()
        await settle(for: 1.5)

        XCTAssertEqual(events.last, .hookFailed("exit 7"))
        XCTAssertEqual(hookRuns.map(\.outcome), [.failed(exitCode: 7)])
    }

    func testStoppingBeforeAnythingWasHeardKeepsNothing() async throws {
        let c = coordinator()
        c.start(tapping: zoom)
        await source.awaitStart()
        source.send(quiet(at: .zero))
        await settle()
        c.stop()
        await settle()

        XCTAssertEqual(events, [.nothingToKeep])
        XCTAssertEqual(MeetingTranscriptFile.listAll(in: dir.appendingPathComponent("docs")).count, 0)
        XCTAssertEqual(MeetingSpool(root: dir.appendingPathComponent("spool")).orphans().count, 0)
    }

    func testFaintAudioCountsAsActivity() async throws {
        let c = coordinator()
        c.start(tapping: zoom)
        await source.awaitStart()
        source.send(loud(at: .zero))
        // Quiet, but not long enough to be a dead tap: each chunk is a second
        // of near-silence within the 5 s silence timeout of nothing... so
        // keep the tap "alive" with a faint signal above the floor.
        for s in stride(from: 1, through: 40, by: 1) {
            source.send(faint(at: .seconds(s)))
        }
        await settle()

        XCTAssertEqual(events.filter { $0 == .nudge }.count, 0, "faint audio counts as activity")
        XCTAssertEqual(c.state, .recording)
    }

    /// SPEC §11's hour of silence. It could never arrive: every rebuild
    /// replays the start sound into our own tap, and every silent chunk in
    /// between read as activity, so the quiet clock was reset every two
    /// minutes for as long as the quiet lasted.
    func testASilentHourAsksOnce() async throws {
        let c = coordinator()
        // the real source chirps on every rebuild and the tap hears this
        // app: a fake that stays mute cannot see the bug.
        source.toneOnRebuild = loud(at: .zero)
        c.start(tapping: zoom)
        await source.awaitStart()
        source.send(loud(at: .zero))
        await settle()

        // nobody says another word. the tap goes silent, rebuilds, hears its
        // own tone, and goes silent again — over and over.
        await beQuiet(from: 5, through: 60)

        XCTAssertEqual(events.filter { $0 == .nudge }.count, 1, "\(events)")
        XCTAssertTrue(events.contains(.gapBegan))
        XCTAssertGreaterThan(source.rebuilds, 1, "the tone really was replayed")
    }

    /// ADR 0023: it asks, it never acts — and an answered nudge does not come
    /// straight back.
    func testAnsweringTheNudgeBuysAnotherQuietSpan() async throws {
        let c = coordinator()
        source.toneOnRebuild = loud(at: .zero)
        c.start(tapping: zoom)
        await source.awaitStart()
        source.send(loud(at: .zero))
        await settle()

        await beQuiet(from: 5, through: 40)
        XCTAssertEqual(events.filter { $0 == .nudge }.count, 1, "\(events)")

        c.keepGoing()
        await beQuiet(from: 45, through: 65)
        XCTAssertEqual(events.filter { $0 == .nudge }.count, 1, "answered, so it waits")

        await beQuiet(from: 70, through: 100)
        XCTAssertEqual(events.filter { $0 == .nudge }.count, 2, "\(events)")
    }

    /// SPEC §11: a tap that stops calling back — a sleep, a locked screen, a
    /// driver that died — is a gap like any other. No chunk ever arrives to
    /// report it, so nothing inside `ingest` can: only the wall clock knows,
    /// and a file that says `complete: true` over forty minutes it never
    /// heard is the one failure that looks exactly like a success.
    func testAMacThatSleptThroughAMeetingSaysSoInTheFile() async throws {
        let clock = FakeClock()
        let c = coordinator(clock: clock)
        c.start(tapping: zoom)
        await source.awaitStart()
        source.send(loud(at: .zero))
        source.send(loud(at: .seconds(1_082)))
        await settle()
        XCTAssertEqual(c.state, .recording)
        XCTAssertEqual(c.elapsed, .seconds(1_083))

        // the lid closes at 00:18:03; forty minutes later the mac wakes at
        // 00:58:18 by the wall and asks the tap whether it is still there.
        clock.advance(by: .seconds(3_498))
        c.probeTapIsAlive()
        await settle()

        XCTAssertEqual(c.state, .rebuilding)
        XCTAssertTrue(events.contains(.gapBegan), "\(events)")
        XCTAssertEqual(c.elapsed, .seconds(3_498), "the menu stops counting frozen frames")

        // the rebuilt tap hears the room again, wall-aligned.
        source.send(loud(at: .seconds(3_498)))
        await settle()
        XCTAssertTrue(events.contains(.gapEnded), "\(events)")

        clock.advance(by: .seconds(230))
        c.stop()
        await settle(for: 1.0)

        let saved = try XCTUnwrap(
            MeetingTranscriptFile.listAll(in: dir.appendingPathComponent("docs")).first)
        XCTAssertFalse(saved.complete)
        XCTAssertEqual(saved.gapCount, 1)
        XCTAssertEqual(saved.duration, .seconds(3_728))
        let body = try String(contentsOf: saved.fileURL, encoding: .utf8)
        XCTAssertTrue(body.contains("- [1083.0, 3499.0]"), body)
        XCTAssertTrue(body.contains("complete: false"), body)
    }

    /// The other half of the same rule: a wall clock that has moved is not
    /// on its own a reason to declare a gap.
    func testATapStillCallingBackIsNotDeclaredDead() async throws {
        let clock = FakeClock()
        let c = coordinator(clock: clock)
        c.start(tapping: zoom)
        await source.awaitStart()
        source.send(loud(at: .zero))
        await settle()

        clock.advance(by: .seconds(2))
        c.probeTapIsAlive()
        await settle()

        XCTAssertEqual(c.state, .recording)
        XCTAssertFalse(events.contains(.gapBegan), "\(events)")
        XCTAssertEqual(source.rebuilds, 0)
    }

    func testLiveLinesAreUpsertedById() async throws {
        let c = coordinator()
        c.start(tapping: zoom)
        await source.awaitStart()
        source.send(loud(at: .zero))
        let id = UUID()
        transcriber.emit(.init(id: id, speaker: .them, at: .zero, text: "the dep", isConfirmed: false))
        transcriber.emit(.init(id: id, speaker: .them, at: .zero, text: "the deploy is blocked", isConfirmed: true))
        await settle()

        XCTAssertEqual(c.liveLines.map(\.text), ["the deploy is blocked"])
        XCTAssertEqual(c.liveLines.first?.isConfirmed, true)
    }

    func testAnOrphanedSpoolBecomesARecoveredTranscript() async throws {
        let spool = MeetingSpool(root: dir.appendingPathComponent("spool"))
        let handle = try spool.begin(.init(
            app: "teams", started: Date(timeIntervalSince1970: 1_787_000_000),
            engine: "whisper-large-v3-turbo", model: .whisperLargeV3Turbo))
        let file = try SpoolAudioFile(url: handle.audioURL)
        try await file.append(loud(at: .zero))
        transcriber.batchTurns = [.init(speaker: .them(nil), at: .zero, text: "recovered words")]

        let c = coordinator()
        c.recoverOrphans()
        await settle(for: 1.0)

        let all = MeetingTranscriptFile.listAll(in: dir.appendingPathComponent("docs"))
        XCTAssertEqual(all.map(\.app), ["teams"])
        XCTAssertEqual(all.first?.recovered, true)
        XCTAssertEqual(spool.orphans().count, 0)

        // it says so first, and the word it lands on is the one the history
        // row already uses — not the one a live stop shows.
        XCTAssertEqual(events.first, .recovering(app: "teams"))
        XCTAssertEqual(
            events.first?.hudText,
            "found an unsaved teams recording — writing it out…")
        XCTAssertEqual(events.last?.hudText, "recovered teams — saved · <1m")
        XCTAssertNil(c.recovering)
    }

    /// Fifteen minutes of the neural engine for the same failure at every
    /// launch, forever. Two tries, then it is kept out of the way.
    func testASpoolThatCannotBeTranscribedIsSetAsideAfterTwoTries() async throws {
        let spool = MeetingSpool(root: dir.appendingPathComponent("spool"))
        let handle = try spool.begin(.init(
            app: "teams", started: Date(timeIntervalSince1970: 1_787_000_000),
            engine: "whisper-large-v3-turbo", model: .whisperLargeV3Turbo))
        let file = try SpoolAudioFile(url: handle.audioURL)
        try await file.append(loud(at: .zero))
        transcriber.batchFailure = Unreadable()

        let c = coordinator()
        c.recoverOrphans()
        await settle(for: 0.6)
        XCTAssertEqual(spool.orphans().count, 1, "one failure is not two")
        XCTAssertEqual(spool.unreadableCount(), 0)

        c.recoverOrphans()
        await settle(for: 0.6)

        XCTAssertEqual(spool.orphans().count, 0)
        XCTAssertEqual(spool.unreadableCount(), 1, "kept, never retried")
        XCTAssertEqual(
            MeetingTranscriptFile.listAll(in: dir.appendingPathComponent("docs")).count, 0)
    }

    /// The call ended, the tab stopped playing, nobody said anything for
    /// minutes: the file must come back whole. A gap means audio was lost,
    /// and once it means "it was quiet" it means nothing at all.
    func testAQuietRoomIsNotRecordedAsDamage() async throws {
        let c = coordinator()
        source.playing = false
        c.start(tapping: zoom)
        await source.awaitStart()
        source.send(loud(at: .zero))
        await settle()

        await beQuiet(from: 5, through: 40)

        XCTAssertFalse(events.contains(.gapBegan), "\(events)")
        XCTAssertEqual(source.rebuilds, 0)
        XCTAssertEqual(c.state, .recording)

        c.stop()
        await settle(for: 1.0)

        let saved = try XCTUnwrap(
            MeetingTranscriptFile.listAll(in: dir.appendingPathComponent("docs")).first)
        XCTAssertTrue(saved.complete)
        XCTAssertEqual(saved.gapCount, 0)
    }

    /// The banner is the only surface that waits until you are back at the
    /// mac, so it names the file rather than congratulating itself.
    func testTheSavedBannerNamesTheFile() {
        let url = URL(
            fileURLWithPath: "/tmp/meetings/2026-09/2026-09-05-1402-zoom.md")
        let whole = MeetingSummary(
            fileURL: url, app: "zoom",
            started: Date(timeIntervalSince1970: 1_787_000_000),
            duration: .seconds(6_120), complete: true, gapCount: 0,
            recovered: false)

        XCTAssertEqual(
            MeetingNudgeNotifier.savedBody(whole),
            "zoom · 1h 42m · 2026-09-05-1402-zoom.md")

        let holed = MeetingSummary(
            fileURL: url, app: "zoom", started: whole.started,
            duration: .seconds(6_120), complete: false, gapCount: 2,
            recovered: false)

        XCTAssertEqual(
            MeetingNudgeNotifier.savedBody(holed),
            "zoom · 1h 42m · 2 gaps · 2026-09-05-1402-zoom.md")

        let rescued = MeetingSummary(
            fileURL: url, app: "zoom", started: whole.started,
            duration: .seconds(6_120), complete: true, gapCount: 0,
            recovered: true)

        XCTAssertEqual(
            MeetingNudgeNotifier.savedBody(rescued),
            "zoom · 1h 42m · recovered · 2026-09-05-1402-zoom.md")
    }

    // MARK: - one meeting, one file

    /// Stop, then start again while the first is still being written out:
    /// back to back, the way a calendar runs. Each gets its own file, its
    /// own start and its own words — the second used to be lost, and the
    /// first stamped with the second's start.
    func testAMeetingStartedWhileTheLastIsWritingOutGetsItsOwnFile() async throws {
        let first = FakeTranscriber(finalTurns: [
            .init(speaker: .you, at: .seconds(1), text: "the first meeting")])
        let second = FakeTranscriber(finalTurns: [
            .init(speaker: .you, at: .seconds(1), text: "the second meeting")])
        first.holds = true
        transcribers.lineUp(first, second)
        let c = coordinator(starting: [
            Date(timeIntervalSince1970: 1_787_000_000),
            Date(timeIntervalSince1970: 1_787_003_600),
        ])

        c.start(tapping: zoom)
        await source.awaitStart()
        source.send(loud(at: .zero))
        source.send(loud(at: .seconds(1)))
        await settle()
        c.stop()
        await held(first)

        c.start(tapping: zoom)
        await source.awaitStart()
        source.send(loud(at: .zero))
        source.send(loud(at: .seconds(1)))
        await settle()
        first.release()
        await settle()
        c.stop()
        await settle(for: 1.0)

        let all = MeetingTranscriptFile.listAll(in: dir.appendingPathComponent("docs"))
        XCTAssertEqual(all.map(\.started), [
            Date(timeIntervalSince1970: 1_787_003_600),
            Date(timeIntervalSince1970: 1_787_000_000),
        ])
        let bodies = try all.map { try String(contentsOf: $0.fileURL, encoding: .utf8) }
        XCTAssertEqual(bodies.map { $0.contains("[00:00:01] you: the second meeting") }, [true, false])
        XCTAssertEqual(bodies.map { $0.contains("[00:00:01] you: the first meeting") }, [false, true])
        XCTAssertFalse(events.contains(.nothingToKeep), "\(events)")
    }

    /// The same, with the first one's last decode still running while the
    /// second is under way: the second's own engine hears it and its own
    /// spool keeps it.
    func testASecondMeetingIsHeardAndSpooledWhileTheFirstStillDecodes() async throws {
        let first = FakeTranscriber(finalTurns: [
            .init(speaker: .you, at: .seconds(1), text: "the first meeting")])
        let second = FakeTranscriber(finalTurns: [
            .init(speaker: .them(nil), at: .seconds(1), text: "the second meeting")])
        first.holds = true
        transcribers.lineUp(first, second)
        let c = coordinator(starting: [
            Date(timeIntervalSince1970: 1_787_000_000),
            Date(timeIntervalSince1970: 1_787_003_600),
        ])

        c.start(tapping: zoom)
        await source.awaitStart()
        source.send(loud(at: .zero))
        await settle()
        c.stop()
        await held(first)

        c.start(tapping: zoom)
        await source.awaitStart()
        first.release()
        await settle()
        source.send(loud(at: .zero))
        source.send(loud(at: .seconds(1)))
        await settle()
        XCTAssertEqual(second.fed, 2)

        c.stop()
        await settle(for: 1.0)

        let newest = try XCTUnwrap(
            MeetingTranscriptFile.listAll(in: dir.appendingPathComponent("docs")).first)
        XCTAssertEqual(newest.started, Date(timeIntervalSince1970: 1_787_003_600))
        let body = try String(contentsOf: newest.fileURL, encoding: .utf8)
        // `them 1`, not `them`: the diarizer had the second's far side to
        // listen to, so the spool kept it.
        XCTAssertTrue(body.contains("[00:00:01] them 1: the second meeting"), body)
        XCTAssertEqual(MeetingSpool(root: dir.appendingPathComponent("spool")).orphans().count, 0)
    }

    /// The menu's stop and the banner's, or one click landing twice: the
    /// first stop is the one, the menu says so at once, and the second
    /// finds nothing left to stop.
    func testTwoStopsWriteOneFile() async throws {
        let c = coordinator()
        c.start(tapping: zoom)
        await source.awaitStart()
        source.send(loud(at: .zero))
        await settle()

        c.stop()
        XCTAssertEqual(c.state, .idle)
        c.stop()
        await settle(for: 1.0)

        XCTAssertEqual(
            MeetingTranscriptFile.listAll(in: dir.appendingPathComponent("docs")).count, 1)
        XCTAssertEqual(events.filter { $0 == .writingItOut }.count, 1, "\(events)")
    }

    /// One source, one tap: a meeting started while the last one's tap is
    /// still closing opens its own once that is done, not on top of it.
    func testANewMeetingOpensTheTapOnlyOnceTheLastOneHasClosed() async throws {
        let c = coordinator()
        c.start(tapping: zoom)
        await source.awaitStart()
        source.send(loud(at: .zero))
        await settle()

        source.holdsStop = true
        c.stop()
        for _ in 0..<200 where !source.isClosing {
            try await Task.sleep(for: .milliseconds(10))
        }
        c.start(tapping: zoom)
        await settle()
        source.releaseStop()
        await source.awaitStart()
        source.send(loud(at: .zero))
        await settle()

        XCTAssertFalse(source.openedWhileClosing)
        XCTAssertEqual(c.state, .recording)
    }

    /// Settings changed mid-meeting are for the next one: this meeting's
    /// file goes where it started out going, names the model that heard
    /// it, and tells the hook it started with.
    func testSettingsChangedMidMeetingAreForTheNextOne() async throws {
        let c = coordinator()
        c.start(tapping: zoom)
        await source.awaitStart()
        source.send(loud(at: .zero))
        await settle()

        meetingsFolder = dir.appendingPathComponent("elsewhere")
        meetingModel = .whisperLargeV3
        hook = try script("#!/bin/sh\nexit 0\n")
        c.stop()
        await settle(for: 1.0)

        XCTAssertEqual(
            MeetingTranscriptFile.listAll(in: dir.appendingPathComponent("elsewhere")).count, 0)
        let saved = try XCTUnwrap(
            MeetingTranscriptFile.listAll(in: dir.appendingPathComponent("docs")).first)
        let body = try String(contentsOf: saved.fileURL, encoding: .utf8)
        XCTAssertTrue(body.contains("engine: whisperLargeV3Turbo\n"), body)
        XCTAssertEqual(hookRuns.count, 0)
    }

    // MARK: - recovery beside a live meeting

    /// Launch recovery can run for a quarter of an hour, and a meeting can
    /// start in the middle of it. What recovery finishes is the spool it
    /// found; the meeting goes on and is saved like any other.
    func testARecoveryThatEndsMidMeetingLeavesTheMeetingAlone() async throws {
        try await orphan("teams", started: Date(timeIntervalSince1970: 1_787_000_000))
        let recovery = FakeTranscriber(batchTurns: [
            .init(speaker: .them(nil), at: .zero, text: "recovered words")])
        let live = FakeTranscriber(finalTurns: [
            .init(speaker: .you, at: .seconds(1), text: "live words")])
        recovery.holds = true
        transcribers.lineUp(recovery, live)
        let c = coordinator(starting: [Date(timeIntervalSince1970: 1_787_090_000)])

        c.recoverOrphans()
        await held(recovery)
        c.start(tapping: zoom)
        await source.awaitStart()
        source.send(loud(at: .zero))
        await settle()
        recovery.release()
        await settle()
        source.send(loud(at: .seconds(1)))
        await settle()
        c.stop()
        await settle(for: 1.0)

        let all = MeetingTranscriptFile.listAll(in: dir.appendingPathComponent("docs"))
        XCTAssertEqual(all.map(\.app), ["zoom", "teams"])
        XCTAssertEqual(all.map(\.recovered), [false, true])
        let bodies = try all.map { try String(contentsOf: $0.fileURL, encoding: .utf8) }
        XCTAssertEqual(bodies.map { $0.contains("[00:00:01] you: live words") }, [true, false])
        XCTAssertEqual(MeetingSpool(root: dir.appendingPathComponent("spool")).orphans().count, 0)
    }

    /// One meeting model at a time: the next spool waits for the meeting
    /// being recorded to stop, and the menu does not claim a recovery that
    /// is only waiting its turn.
    func testRecoveryWaitsForTheMeetingBeingRecordedBeforeTheNextSpool() async throws {
        try await orphan("teams", started: Date(timeIntervalSince1970: 1_787_000_000))
        try await orphan("meet", started: Date(timeIntervalSince1970: 1_787_001_000))
        let teams = FakeTranscriber(batchTurns: [
            .init(speaker: .them(nil), at: .zero, text: "from teams")])
        let live = FakeTranscriber(finalTurns: [
            .init(speaker: .you, at: .seconds(1), text: "live words")])
        let meet = FakeTranscriber(batchTurns: [
            .init(speaker: .them(nil), at: .zero, text: "from meet")])
        teams.holds = true
        transcribers.lineUp(teams, live, meet)
        let c = coordinator(starting: [Date(timeIntervalSince1970: 1_787_090_000)])
        let recoveries = { [unowned self] in
            events.filter { if case .recovering = $0 { true } else { false } }
        }

        c.recoverOrphans()
        await held(teams)
        c.start(tapping: zoom)
        await source.awaitStart()
        source.send(loud(at: .zero))
        await settle()
        teams.release()
        await settle()

        XCTAssertEqual(recoveries(), [.recovering(app: "teams")])
        XCTAssertNil(c.recovering)
        XCTAssertEqual(
            MeetingTranscriptFile.listAll(in: dir.appendingPathComponent("docs")).map(\.app),
            ["teams"])

        c.stop()
        await settle(for: 1.0)

        XCTAssertEqual(recoveries(), [.recovering(app: "teams"), .recovering(app: "meet")])
        XCTAssertEqual(
            MeetingTranscriptFile.listAll(in: dir.appendingPathComponent("docs")).map(\.app),
            ["zoom", "meet", "teams"])
    }

    /// Recovery runs a few seconds after launch, and a meeting started in
    /// those seconds has a spool on disk that looks just like one a crash
    /// left. It is not one: it stays where it is, and the meeting is saved
    /// as itself.
    func testAMeetingStartedJustBeforeRecoveryIsNotAnOrphan() async throws {
        let live = FakeTranscriber(finalTurns: [
            .init(speaker: .you, at: .seconds(1), text: "live words")])
        transcribers.lineUp(live)
        let c = coordinator()
        c.start(tapping: zoom)
        await source.awaitStart()
        source.send(loud(at: .zero))
        await settle()

        c.recoverOrphans()
        await settle()
        XCTAssertFalse(events.contains(.recovering(app: "zoom")), "\(events)")
        XCTAssertEqual(try spoolFolders(), 1)

        source.send(loud(at: .seconds(1)))
        await settle()
        c.stop()
        await settle(for: 1.0)

        let all = MeetingTranscriptFile.listAll(in: dir.appendingPathComponent("docs"))
        XCTAssertEqual(all.map(\.recovered), [false])
        let body = try String(contentsOf: try XCTUnwrap(all.first).fileURL, encoding: .utf8)
        XCTAssertTrue(body.contains("[00:00:01] you: live words"), body)
    }

    /// The same for a meeting that has stopped and is still being written
    /// out: its spool is about to become its file, not a recovery.
    func testAMeetingStillWritingOutIsNotAnOrphan() async throws {
        let live = FakeTranscriber(finalTurns: [
            .init(speaker: .you, at: .seconds(1), text: "live words")])
        live.holds = true
        transcribers.lineUp(live)
        let c = coordinator()
        c.start(tapping: zoom)
        await source.awaitStart()
        source.send(loud(at: .zero))
        await settle()
        c.stop()
        await held(live)

        c.recoverOrphans()
        await settle()
        XCTAssertFalse(events.contains(.recovering(app: "zoom")), "\(events)")

        live.release()
        await settle(for: 1.0)
        let all = MeetingTranscriptFile.listAll(in: dir.appendingPathComponent("docs"))
        XCTAssertEqual(all.map(\.recovered), [false])
    }

    // MARK: - a quit that waits for the file

    /// A quit right after stop must not take the file down with it: a
    /// stopped meeting is still being written out until its file is there,
    /// and whoever waits on that is let go only then.
    func testAStoppedMeetingIsWritingOutUntilItsFileIsThere() async throws {
        let live = FakeTranscriber(finalTurns: [
            .init(speaker: .you, at: .seconds(1), text: "live words")])
        live.holds = true
        transcribers.lineUp(live)
        let c = coordinator()
        c.start(tapping: zoom)
        await source.awaitStart()
        source.send(loud(at: .zero))
        await settle()
        XCTAssertFalse(c.isWritingOut)

        c.stop()
        XCTAssertTrue(c.isWritingOut)
        await held(live)
        XCTAssertTrue(c.isWritingOut)

        let docs = dir.appendingPathComponent("docs")
        let waited = Task {
            await c.untilWrittenOut()
            return MeetingTranscriptFile.listAll(in: docs).count
        }
        await settle()
        live.release()

        let filesWhenTheWaitEnded = await waited.value
        XCTAssertEqual(filesWhenTheWaitEnded, 1)
        XCTAssertFalse(c.isWritingOut)
    }

    // MARK: - helpers

    private func spoolFolders() throws -> Int {
        try FileManager.default.contentsOfDirectory(
            atPath: dir.appendingPathComponent("spool").path
        ).filter { !$0.hasPrefix(".") }.count
    }

    /// A spool a crash left behind, with a second of audio on it.
    private func orphan(_ app: String, started: Date) async throws {
        let spool = MeetingSpool(root: dir.appendingPathComponent("spool"))
        let handle = try spool.begin(.init(
            app: app, started: started,
            engine: "whisper-large-v3-turbo", model: .whisperLargeV3Turbo))
        let file = try SpoolAudioFile(url: handle.audioURL)
        try await file.append(loud(at: .zero))
    }

    private func loud(at: Duration) -> MeetingAudioChunk {
        let n = 16_000
        return .init(you: Array(repeating: 0.05, count: n),
                     them: (0..<n).map { sin(Float($0) * 0.05) * 0.3 }, at: at)
    }

    private func faint(at: Duration) -> MeetingAudioChunk {
        .init(you: Array(repeating: 0, count: 16_000),
              them: Array(repeating: 0.01, count: 16_000), at: at)
    }

    private func quiet(at: Duration) -> MeetingAudioChunk {
        .init(you: Array(repeating: 0, count: 16_000),
              them: Array(repeating: 0, count: 16_000), at: at)
    }

    private func settle(for seconds: Double = 0.3) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// Until the transcriber is parked in its hold, or two seconds, so a
    /// test against code that never gets there fails instead of hanging.
    private func held(_ transcriber: FakeTranscriber) async {
        for _ in 0..<200 where !transcriber.isWaiting {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Silence, delivered the way a live tap delivers it: one chunk at a
    /// time, with room for a rebuild and its tone to land in between.
    private func beQuiet(from first: Int, through last: Int) async {
        for s in stride(from: first, through: last, by: 5) {
            source.send(quiet(at: .seconds(s)))
            await settle(for: 0.12)
        }
    }

    private func script(_ text: String) throws -> URL {
        let url = dir.appendingPathComponent("hook.sh")
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}

// MARK: - fakes

/// A wall the test moves by hand — the coordinator only ever reads it.
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

/// The dates meetings start on, one each, in order.
private final class StartDates: @unchecked Sendable {
    private let lock = NSLock()
    private var dates: [Date]

    init(_ dates: [Date]) {
        self.dates = dates
    }

    func next() -> Date {
        lock.withLock { dates.isEmpty ? Date() : dates.removeFirst() }
    }
}

/// The tap. Opened again after a stop, it starts a new stream, the way the
/// real one does for the next meeting. While `holdsStop` is set, a stop
/// waits for `releaseStop()` — a tap slow to close.
private final class FakeSource: MeetingAudioSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _continuation: AsyncStream<MeetingAudioChunk>.Continuation?
    private var starts = 0
    private var startsSeen = 0
    private var stopsInFlight = 0
    private var _holdsStop = false
    private var _openedWhileClosing = false
    private var waitingToStop: [CheckedContinuation<Void, Never>] = []
    private var nextAt: Duration = .zero
    var rebuilds = 0
    /// The real source plays the start sound again on every rebuild, and the
    /// tap is scoped to this app as well — so the tone comes back as far-side
    /// audio a moment later. A fake that stays mute cannot see what that
    /// does to the quiet clock.
    var toneOnRebuild: MeetingAudioChunk?

    private var continuation: AsyncStream<MeetingAudioChunk>.Continuation? {
        lock.withLock { _continuation }
    }

    var holdsStop: Bool {
        get { lock.withLock { _holdsStop } }
        set { lock.withLock { _holdsStop = newValue } }
    }

    /// A stop is parked in its hold.
    var isClosing: Bool {
        lock.withLock { !waitingToStop.isEmpty }
    }

    /// The tap was opened while a stop of it was still in flight.
    var openedWhileClosing: Bool {
        lock.withLock { _openedWhileClosing }
    }

    func start(tapping app: RunningApp) async throws -> AsyncStream<MeetingAudioChunk> {
        let (stream, continuation) = AsyncStream<MeetingAudioChunk>.makeStream()
        lock.withLock {
            if stopsInFlight > 0 { _openedWhileClosing = true }
            _continuation = continuation
            starts += 1
        }
        return stream
    }

    func rebuild() async throws {
        rebuilds += 1
        guard let tone = toneOnRebuild else { return }
        send(MeetingAudioChunk(you: tone.you, them: tone.them, at: nextAt))
    }

    /// What the tapped app says about its own output. `nil` is "cannot
    /// tell", which is what the real source returns for a helper process.
    var playing: Bool?

    func tappedAppIsPlaying() -> Bool? { playing }

    func stop() async {
        let holds = lock.withLock {
            stopsInFlight += 1
            return _holdsStop
        }
        if holds {
            // checked again in the lock that registers the wait, so a
            // release landing between the two cannot be missed.
            await withCheckedContinuation { continuation in
                let goNow = lock.withLock {
                    guard _holdsStop else {
                        return true
                    }
                    waitingToStop.append(continuation)
                    return false
                }
                if goNow {
                    continuation.resume()
                }
            }
        }
        let continuation = lock.withLock { () -> AsyncStream<MeetingAudioChunk>.Continuation? in
            defer {
                _continuation = nil
                stopsInFlight -= 1
            }
            return _continuation
        }
        continuation?.finish()
    }

    func releaseStop() {
        let released = lock.withLock {
            _holdsStop = false
            let released = waitingToStop
            waitingToStop = []
            return released
        }
        for continuation in released {
            continuation.resume()
        }
    }

    func send(_ chunk: MeetingAudioChunk) {
        nextAt = chunk.at + chunk.duration
        continuation?.yield(chunk)
    }

    /// Until the tap has been opened once more than the last call saw, or
    /// two seconds — a meeting that never opens it fails the test instead
    /// of hanging it.
    func awaitStart() async {
        for _ in 0..<200 {
            let opened = lock.withLock {
                guard starts > startsSeen else { return false }
                startsSeen += 1
                return true
            }
            if opened { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private struct Unreadable: Error {}

/// One per meeting, the way the app builds them. The test lines up the ones
/// it wants to hold or read; a meeting past those gets the shared one.
private final class FakeTranscribers: @unchecked Sendable {
    private let lock = NSLock()
    private var lined: [FakeTranscriber] = []
    private let otherwise: FakeTranscriber

    init(otherwise: FakeTranscriber) {
        self.otherwise = otherwise
    }

    func lineUp(_ transcribers: FakeTranscriber...) {
        lock.withLock { lined.append(contentsOf: transcribers) }
    }

    func next() -> FakeTranscriber {
        lock.withLock { lined.isEmpty ? otherwise : lined.removeFirst() }
    }
}

/// While `holds` is set, `finish` and `transcribe` wait for the test to
/// `release()` them — the last decode of a meeting, or the whole of a
/// recovery's, still running.
private final class FakeTranscriber: MeetingTranscriber, @unchecked Sendable {
    var finalTurns: [MeetingTurn] = []
    var batchTurns: [MeetingTurn] = []
    /// what a spool the engine cannot read does at every launch.
    var batchFailure: (any Error)?
    let lines: AsyncStream<LiveLine>
    private let emitter: AsyncStream<LiveLine>.Continuation
    private let lock = NSLock()
    private var _fed = 0
    private var _holds = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(finalTurns: [MeetingTurn] = [], batchTurns: [MeetingTurn] = []) {
        self.finalTurns = finalTurns
        self.batchTurns = batchTurns
        (lines, emitter) = AsyncStream<LiveLine>.makeStream()
    }

    var fed: Int {
        lock.withLock { _fed }
    }

    var holds: Bool {
        get { lock.withLock { _holds } }
        set { lock.withLock { _holds = newValue } }
    }

    var isWaiting: Bool {
        lock.withLock { !waiting.isEmpty }
    }

    func begin() async throws {}
    func feed(_ chunk: MeetingAudioChunk) async {
        lock.withLock { _fed += 1 }
    }
    func finish() async -> [MeetingTurn] {
        await heldUntilReleased()
        return finalTurns
    }
    func transcribe(you: [Float], them: [Float]) async throws -> [MeetingTurn] {
        await heldUntilReleased()
        if let batchFailure { throw batchFailure }
        return batchTurns
    }
    func emit(_ line: LiveLine) { emitter.yield(line) }

    func release() {
        let released = lock.withLock {
            _holds = false
            let released = waiting
            waiting = []
            return released
        }
        for continuation in released {
            continuation.resume()
        }
    }

    private func heldUntilReleased() async {
        guard holds else { return }
        // the hold is checked again in the same lock that registers the
        // wait: a release landing between the two would otherwise leave
        // this waiting on a release that already happened.
        await withCheckedContinuation { continuation in
            let goNow = lock.withLock {
                guard _holds else {
                    return true
                }
                waiting.append(continuation)
                return false
            }
            if goNow {
                continuation.resume()
            }
        }
    }
}

private struct FakeDiarizer: MeetingDiarizer {
    func split(them: [Float], turns: [MeetingTurn]) async -> [MeetingTurn] {
        turns.map { turn in
            if case .them = turn.speaker {
                return .init(speaker: .them(1), at: turn.at, text: turn.text)
            }
            return turn
        }
    }
}

extension MeetingCoordinatorTests {
    /// The engine failing is the app's fault, not the permission's: it must
    /// not read as "can't hear", must not write an empty transcript, and
    /// must leave the spool for the next launch to recover.
    func testAModelThatWillNotLoadAbandonsTheMeetingButKeepsTheSpool() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-coordinator-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let spool = MeetingSpool(root: dir.appendingPathComponent("spool"))
        let source = FakeSource()
        var events: [MeetingEvent] = []

        struct WillNotLoad: Error {}
        let c = MeetingCoordinator(
            source: source,
            makeTranscriber: { _ in throw WillNotLoad() },
            diarizer: FakeDiarizer(),
            spool: spool,
            hookRunner: HookRunner(logURL: dir.appendingPathComponent("hooks.log")),
            preferences: {
                MeetingPreferences(folder: dir.appendingPathComponent("docs"), hook: nil, model: .whisperLargeV3)
            }
        )
        c.onEvent = { events.append($0) }
        c.start(tapping: RunningApp(name: "zoom.us", bundleID: "us.zoom.xos", pid: 1))
        try? await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(c.state, .idle)
        XCTAssertEqual(events.count, 1)
        guard case .engineFailed = events.first else {
            return XCTFail("expected engineFailed, got \(events)")
        }
        XCTAssertEqual(MeetingTranscriptFile.listAll(in: dir.appendingPathComponent("docs")).count, 0)
        // The spool folder survives, with its manifest, for recovery.
        let folders = try FileManager.default.contentsOfDirectory(atPath: spool.root.path)
        XCTAssertEqual(folders.count, 1)
    }
}
