import XCTest

/// A meeting's tap, kept honest through the coordinator and its fakes:
/// silence is never damage, a quiet far side is asked about with a quiet
/// tone, a dead tap is rebuilt patiently, and one that cannot be rebuilt is
/// a problem the meeting records through rather than the end of it.
@MainActor
final class MeetingTapHealthTests: XCTestCase {
    private var dir: URL!
    private var source: FakeSource!
    private var transcriber: FakeTranscriber!
    private var events: [MeetingEvent] = []
    private var records: [MeetingRecord] = []
    private var awake: Wakefulness!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-tap-health-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        source = FakeSource()
        transcriber = FakeTranscriber()
        events = []
        records = []
        awake = Wakefulness()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    /// The test's own numbers: a five-second timeout and a two-second
    /// window, in meeting time; waits on the real clock kept short.
    private func coordinator(
        thresholds: MeetingThresholds = .init(
            probeTimeout: .seconds(1), silenceTimeout: .seconds(5),
            silenceFloor: 0.001, quietNudgeAfter: .seconds(3_600),
            quietProbeWindow: .seconds(2),
            settleBeforeRebuild: .milliseconds(50)),
        clock: FakeClock = FakeClock()
    ) -> MeetingCoordinator {
        let docs = dir.appendingPathComponent("docs")
        let awake = awake!
        let c = MeetingCoordinator(
            source: source,
            makeTranscriber: { [transcriber] _ in transcriber! },
            diarizer: FakeDiarizer(),
            spool: MeetingSpool(root: dir.appendingPathComponent("spool")),
            hookRunner: HookRunner(logURL: dir.appendingPathComponent("hooks.log")),
            // kept as the spool wrote it, so a test can read what it kept.
            keptAudio: KeptAudio(
                root: dir.appendingPathComponent("meeting-audio"),
                compress: { _, _ in throw CocoaError(.featureUnsupported) }),
            thresholds: thresholds,
            now: { clock.now },
            keepAwake: .init(
                hold: {
                    awake.held += 1
                    return NSObject()
                },
                release: { _ in awake.released += 1 }),
            preferences: {
                MeetingPreferences(folder: docs, hook: nil, model: .whisperLargeV3Turbo)
            }
        )
        c.onEvent = { [weak self] in self?.events.append($0) }
        c.keepMeetingRecord = { [weak self] in self?.records.append($0) }
        return c
    }

    // MARK: - our own tones are not the call

    /// The start sound comes back through the tap as far-side audio, and a
    /// model given it writes it down as somebody speaking at 00:00. While
    /// the start window is open the far side is handed over silent — the
    /// spool keeps it as it was — and what you say meanwhile is still
    /// heard, and so is the far side once the window has closed.
    func testTheStartSoundIsNotTranscribedAndYourVoiceUnderItIs() async throws {
        transcriber.transcribesWhatItIsFed = true
        let c = coordinator()
        c.start()
        await source.awaitStart()
        // the start window is the first second: the tone, with you talking
        // over it, then a pause, then the far side speaking.
        await play(
            both(at: .zero), both(at: .milliseconds(500)),
            silent(at: .seconds(1)), silent(at: .milliseconds(1_500)),
            them(at: .seconds(2)))

        c.stop()
        await c.untilWrittenOut()
        XCTAssertEqual(try savedLines(), [
            "[00:00:00] you: you said something you said something",
            "[00:00:02] them: they said something",
        ])
        XCTAssertEqual(
            transcriber.fed.map { $0.themRMS > 0.001 }, [false, false, false, false, true])
        let spooled = try XCTUnwrap(spooledThem())
        XCTAssertGreaterThan(rms(spooled.prefix(8_000)), 0.1, "the spool keeps the tone")
    }

    // MARK: - the mac stays awake

    /// A quiet meeting is still a meeting: the mac is kept from idle sleep
    /// from the start, and let go once, at the stop.
    func testTheMacIsKeptAwakeFromTheStartToTheStop() async throws {
        let c = coordinator()
        c.start()
        XCTAssertEqual(awake.held, 1)
        await source.awaitStart()
        await play(loud(at: .zero))
        XCTAssertEqual(awake.released, 0, "recording")

        c.stop()
        XCTAssertEqual(awake.released, 1)
        await c.untilWrittenOut()
        XCTAssertEqual(awake.held, 1)
        XCTAssertEqual(awake.released, 1)
    }

    /// A model that will not load ends the meeting, and lets the mac go.
    func testAModelThatWillNotLoadLetsTheMacSleep() async throws {
        transcriber.willNotLoad = true
        let c = coordinator()
        c.start()
        await until { c.state == .idle }

        XCTAssertEqual(awake.held, 1)
        XCTAssertEqual(awake.released, 1)
    }

    /// The start sound never came back: the meeting ends before it began,
    /// and lets the mac go.
    func testATapThatNeverHeardTheStartSoundLetsTheMacSleep() async throws {
        let c = coordinator()
        c.start()
        await source.awaitStart()
        await play(quiet(at: .zero), quiet(at: .seconds(2)))
        await c.untilWrittenOut()

        XCTAssertEqual(events, [.cannotHear])
        XCTAssertEqual(awake.held, 1)
        XCTAssertEqual(awake.released, 1)
    }

    // MARK: - a tone that cannot be played

    /// The mac has no output to play the start sound on. The tap was given
    /// nothing to hear, so silence through the probe window is not a tap
    /// that cannot hear: the meeting records, no window opens, and the
    /// record says the probe could not be played.
    func testAStartSoundThatCannotPlayIsCouldNotCheckAndTheMeetingRecords() async throws {
        source.startSoundPlays = false
        let c = coordinator()
        c.start()
        await source.awaitStart()
        await play(voice(at: .zero), voice(at: .seconds(1)), voice(at: .seconds(2)))

        XCTAssertEqual(c.state, .recording)
        XCTAssertEqual(events, [.started])
        XCTAssertEqual(transcriber.fed.count, 3)

        c.stop()
        await c.untilWrittenOut()
        XCTAssertTrue(try savedFile().complete)
        XCTAssertEqual(records.first?.outcome, .saved)
        XCTAssertEqual(records.first?.events, [.init(.probeUnplayable, atS: 0)])
    }

    /// Rebuilt, and no output to play the start sound on: the new tap was
    /// asked nothing, so the try neither worked nor failed. No problem is
    /// named for it, the gap stays open until the far side is heard, and
    /// the tap is tried again at the slow pace meanwhile.
    func testARebuiltTapWhoseStartSoundCannotPlayIsNoEvidenceEitherWay() async throws {
        let clock = FakeClock()
        let c = coordinator(thresholds: retrying, clock: clock)
        c.start()
        await source.awaitStart()
        await play(loud(at: .zero), loud(at: .seconds(1)))

        source.startSoundPlays = false
        clock.advance(by: .seconds(60))
        source.skip(to: .seconds(60))
        c.probeTapIsAlive()
        await until { source.rebuilds == 2 }

        XCTAssertEqual(source.rebuilds, 2)
        XCTAssertNil(c.problem)
        XCTAssertEqual(c.state, .rebuilding)
        XCTAssertEqual(events, [.started, .gapBegan])

        await play(loud(at: .seconds(60)))
        XCTAssertEqual(events, [.started, .gapBegan, .gapEnded])

        c.stop()
        await c.untilWrittenOut()
        XCTAssertEqual(records.first?.events, [
            .init(.gapBegan, atS: 2),
            .init(.probeUnplayable, atS: 60),
            .init(.gapEnded, atS: 61),
        ])
    }

    // MARK: - silence is not damage

    /// Presenting to a room that has nothing playing: five minutes of
    /// nothing from the far side is a quiet room. No tone, no gap, no
    /// rebuild, and a file that says it is whole.
    func testFiveMinutesOfSilenceWithNothingPlayingIsLeftAlone() async throws {
        source.anythingIsPlaying = false
        let c = coordinator()
        c.start()
        await source.awaitStart()
        await play(loud(at: .zero))

        for s in stride(from: 10, through: 300, by: 10) {
            source.send(quiet(at: .seconds(s)))
        }
        await until { c.elapsed >= .seconds(300) }

        XCTAssertEqual(source.quietProbes, 0)
        XCTAssertEqual(source.rebuilds, 0)
        XCTAssertEqual(events, [.started])
        XCTAssertEqual(c.state, .recording)

        c.stop()
        await c.untilWrittenOut()
        let saved = try savedFile()
        XCTAssertTrue(saved.complete)
        XCTAssertEqual(saved.gapCount, 0)
        XCTAssertEqual(records.first?.events, [])
    }

    /// The call ended and the recording ran on: an hour with nothing
    /// playing. It used to chirp, rebuild and cut a gap every two minutes;
    /// now it asks nothing at all.
    func testAnHourOfSilenceAfterEverythingStoppedPlayingAsksNothing() async throws {
        source.anythingIsPlaying = true
        let c = coordinator()
        c.start()
        await source.awaitStart()
        await play(loud(at: .zero), loud(at: .seconds(1)))

        source.anythingIsPlaying = false
        for s in stride(from: 10, through: 3_600, by: 10) {
            source.send(quiet(at: .seconds(s)))
        }
        await until { c.elapsed >= .seconds(3_600) }

        XCTAssertEqual(source.quietProbes, 0)
        XCTAssertEqual(source.rebuilds, 0)
        XCTAssertEqual(events, [.started])

        c.stop()
        await c.untilWrittenOut()
        XCTAssertTrue(try savedFile().complete)
        XCTAssertEqual(records.first?.events, [])
    }

    // MARK: - the quiet probe

    /// You present for longer than the timeout while the call app plays
    /// a muted room. The tap is asked once, with the quiet tone, and hears
    /// it: nothing else happens, the lamp says nothing, and the next
    /// question waits a full timeout from the tone.
    func testAQuietProbeTheTapHearsChangesNothingAndTheNextWaitsAFullTimeout() async throws {
        source.anythingIsPlaying = true
        let c = coordinator()
        c.start()
        await source.awaitStart()
        await play(loud(at: .zero))

        for s in 2...5 {
            await play(quiet(at: .seconds(s)))
        }
        XCTAssertEqual(source.quietProbes, 0, "five seconds is not past the timeout")

        await play(quiet(at: .seconds(6)))
        await until { source.quietProbes == 1 }
        XCTAssertEqual(source.quietProbes, 1)

        // the tone comes back through the tap at 7.0–7.3.
        await play(tone(at: .seconds(7)))
        for s in 8...12 {
            await play(quiet(at: .seconds(s)))
        }
        XCTAssertEqual(source.quietProbes, 1, "not sooner than a full timeout after the tone")

        await play(quiet(at: .seconds(13)))
        await until { source.quietProbes == 2 }
        XCTAssertEqual(source.quietProbes, 2)

        XCTAssertEqual(source.rebuilds, 0)
        XCTAssertEqual(events, [.started])
        XCTAssertEqual(c.state, .recording)

        c.stop()
        await c.untilWrittenOut()
        XCTAssertTrue(try savedFile().complete)
        // the second question was still open at the stop.
        XCTAssertEqual(records.first?.events, [.init(.probeHeard, atS: 7.3)])
    }

    /// Asked, and the window passes with nothing: that is a dead tap. The
    /// gap begins where the question went unanswered, the tap is rebuilt,
    /// the rebuilt tap hears its start sound, and the gap ends there.
    func testAQuietProbeTheTapMissesIsAGapARebuildAndARecovery() async throws {
        source.anythingIsPlaying = true
        let c = coordinator()
        c.start()
        await source.awaitStart()
        await play(loud(at: .zero))
        for s in 2...6 {
            await play(quiet(at: .seconds(s)))
        }
        await until { source.quietProbes == 1 }

        await play(quiet(at: .seconds(7)), quiet(at: .seconds(8)))
        XCTAssertEqual(source.rebuilds, 0, "the window is not over")
        await play(quiet(at: .seconds(9)))
        await until { events.contains(.gapEnded) }

        XCTAssertEqual(source.rebuilds, 1)
        XCTAssertEqual(events, [.started, .gapBegan, .gapEnded])
        XCTAssertEqual(c.state, .recording)

        c.stop()
        await c.untilWrittenOut()
        let saved = try savedFile()
        XCTAssertFalse(saved.complete)
        XCTAssertEqual(saved.gapCount, 1)
        XCTAssertEqual(records.first?.events, [
            .init(.probeUnheard, atS: 9.1),
            .init(.gapBegan, atS: 9.1),
            .init(.gapEnded, atS: 9.4),
        ])
    }

    /// No output to play the tone on: the tap was asked nothing, so the
    /// meeting learns nothing — no gap, no rebuild, nothing on the lamp —
    /// and asks again a full timeout later. The record says it could not.
    func testAQuietProbeThatCannotPlayIsNoEvidenceEitherWay() async throws {
        source.anythingIsPlaying = true
        source.quietProbeCannotPlay = true
        let c = coordinator()
        c.start()
        await source.awaitStart()
        await play(loud(at: .zero))
        for s in 2...6 {
            await play(quiet(at: .seconds(s)))
        }
        await until { source.quietProbes == 1 }

        for s in 7...11 {
            await play(quiet(at: .seconds(s)))
        }
        XCTAssertEqual(source.quietProbes, 1, "a full timeout from the try")
        XCTAssertEqual(source.rebuilds, 0, "never played, so never missed")

        await play(quiet(at: .seconds(12)))
        await until { source.quietProbes == 2 }
        XCTAssertEqual(source.quietProbes, 2)
        XCTAssertEqual(events, [.started])

        c.stop()
        await c.untilWrittenOut()
        XCTAssertTrue(try savedFile().complete)
        XCTAssertEqual(records.first?.events, [
            .init(.probeUnplayable, atS: 6.1),
            .init(.probeUnplayable, atS: 12.1),
        ])
    }

    /// The quiet probe is our own tone, not anyone speaking. Heard every
    /// few seconds through a long silence, it must not buy the meeting
    /// another quiet hour: the nudge still comes once, on time.
    func testAQuietProbeHeardIsNotSomebodySpeaking() async throws {
        source.anythingIsPlaying = true
        source.hearsTheQuietProbe = true
        let c = coordinator(thresholds: .init(
            probeTimeout: .seconds(1), silenceTimeout: .seconds(5),
            silenceFloor: 0.001, quietNudgeAfter: .seconds(30),
            quietProbeWindow: .seconds(2)))
        c.start()
        await source.awaitStart()
        await play(loud(at: .zero))

        for s in 2...45 {
            await play(quiet(at: .seconds(s)))
        }

        // asked at 6.1, 12.1, 18.1, 24.1, 30.1, 36.1 and 42.1, and heard
        // each time; the nudge at 31.1.
        XCTAssertEqual(source.quietProbes, 7)
        XCTAssertEqual(source.rebuilds, 0)
        XCTAssertEqual(events, [.started, .nudge])
    }

    // MARK: - a tap that stops calling back

    /// The mac wakes and the tap has not called back since it slept: a gap
    /// at once, and a rebuild only once the hardware has had a moment to
    /// settle, so the rebuild does not race the device coming back.
    func testATapThatStopsCallingBackIsRebuiltOnceTheHardwareHasSettled() async throws {
        let clock = FakeClock()
        let c = coordinator(
            thresholds: .init(
                probeTimeout: .seconds(1), silenceTimeout: .seconds(5),
                silenceFloor: 0.001, quietNudgeAfter: .seconds(3_600),
                quietProbeWindow: .seconds(2),
                settleBeforeRebuild: .milliseconds(500)),
            clock: clock)
        c.start()
        await source.awaitStart()
        await play(loud(at: .zero), loud(at: .seconds(1)))

        // asleep for a minute.
        clock.advance(by: .seconds(60))
        source.skip(to: .seconds(60))
        let woke = ContinuousClock.now
        c.probeTapIsAlive()

        XCTAssertEqual(c.state, .rebuilding)
        XCTAssertEqual(events, [.started, .gapBegan])
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(source.rebuilds, 0, "the hardware is still settling")

        await until { events.contains(.gapEnded) }
        XCTAssertEqual(source.rebuilds, 1)
        let waited = try XCTUnwrap(source.rebuiltAt.first) - woke
        XCTAssertGreaterThanOrEqual(waited, .milliseconds(500))
        XCTAssertEqual(events, [.started, .gapBegan, .gapEnded])
        XCTAssertEqual(c.state, .recording)

        c.stop()
        await c.untilWrittenOut()
        XCTAssertEqual(records.first?.events, [
            .init(.gapBegan, atS: 2),
            .init(.gapEnded, atS: 60.3),
        ])
    }

    // MARK: - a rebuild that throws

    /// The device is not back yet the first two times. The rebuild is tried
    /// again, further apart each time, and the third works: one gap, closed
    /// when the rebuilt tap hears its start sound, and nothing else to say.
    func testARebuildThatThrowsTwiceThenWorksIsOneGap() async throws {
        source.rebuildsThatFail = 2
        let clock = FakeClock()
        let c = coordinator(thresholds: retrying, clock: clock)
        c.start()
        await source.awaitStart()
        await play(loud(at: .zero), loud(at: .seconds(1)))

        clock.advance(by: .seconds(60))
        source.skip(to: .seconds(60))
        c.probeTapIsAlive()
        await until { events.contains(.gapEnded) }

        XCTAssertEqual(source.rebuilds, 3)
        let at = source.rebuiltAt
        guard at.count == 3 else { return }
        XCTAssertGreaterThanOrEqual(at[1] - at[0], .milliseconds(100))
        XCTAssertGreaterThanOrEqual(at[2] - at[1], .milliseconds(200))
        XCTAssertEqual(events, [.started, .gapBegan, .gapEnded])
        XCTAssertEqual(c.state, .recording)
        XCTAssertNil(c.problem)

        c.stop()
        await c.untilWrittenOut()
        XCTAssertEqual(try savedFile().gapCount, 1)
        XCTAssertEqual(records.first?.events, [
            .init(.gapBegan, atS: 2),
            .init(.rebuildFailed, atS: 60),
            .init(.rebuildFailed, atS: 60),
            .init(.gapEnded, atS: 60.3),
        ])
    }

    /// Three tries and the device is still not there. The meeting does not
    /// end and no window opens: it has a problem, said on the lamp, and
    /// goes on recording your side with the gap open. Stopped like that, the
    /// file says it is not complete, with the gap running to the end.
    func testARebuildThatThrowsThreeTimesIsAProblemTheMeetingRecordsThrough() async throws {
        source.rebuildsThatFail = 1_000
        let clock = FakeClock()
        let c = coordinator(thresholds: retrying, clock: clock)
        c.start()
        await source.awaitStart()
        await play(loud(at: .zero), loud(at: .seconds(1)))

        clock.advance(by: .seconds(60))
        source.skip(to: .seconds(60))
        c.probeTapIsAlive()
        await until { c.problem != nil }

        XCTAssertEqual(source.rebuilds, 3)
        XCTAssertEqual(c.problem, .cannotHearTheCall)
        XCTAssertEqual(c.state, .rebuilding)
        XCTAssertTrue(c.isRecording)
        XCTAssertEqual(events, [.started, .gapBegan, .problemBegan(.cannotHearTheCall)])
        XCTAssertEqual(events.last?.hudText, "can't hear the call — still recording your side")

        // the mic still delivers; the far side is nothing.
        await play(voice(at: .seconds(60)), voice(at: .seconds(61)))
        XCTAssertEqual(transcriber.fed.map(\.at), [.zero, .seconds(1), .seconds(60), .seconds(61)])
        XCTAssertFalse(events.contains(.cannotHear))

        c.stop()
        await c.untilWrittenOut()
        let saved = try savedFile()
        XCTAssertFalse(saved.complete)
        let body = try String(contentsOf: saved.fileURL, encoding: .utf8)
        XCTAssertTrue(body.contains("- [2.0, 62.0]"), body)
        XCTAssertEqual(records.first?.events, [
            .init(.gapBegan, atS: 2),
            .init(.rebuildFailed, atS: 60),
            .init(.rebuildFailed, atS: 60),
            .init(.rebuildFailed, atS: 60),
            .init(.problemBegan, atS: 60),
        ])
    }

    /// With the problem standing the tap is tried again now and then, and
    /// the first that works ends it: the problem clears, the gap closes
    /// where the rebuilt tap heard its start sound, and the lamp says the
    /// call is heard again.
    func testWithTheProblemStandingALaterRebuildThatWorksClearsIt() async throws {
        // three in a row, then the first try with the problem standing.
        source.rebuildsThatFail = 4
        let clock = FakeClock()
        let c = coordinator(thresholds: retrying, clock: clock)
        c.start()
        await source.awaitStart()
        await play(loud(at: .zero), loud(at: .seconds(1)))

        clock.advance(by: .seconds(60))
        source.skip(to: .seconds(60))
        c.probeTapIsAlive()
        await until { c.problem != nil }
        await until { c.problem == nil }

        XCTAssertEqual(source.rebuilds, 5)
        let at = source.rebuiltAt
        guard at.count == 5 else { return }
        XCTAssertGreaterThanOrEqual(at[3] - at[2], .milliseconds(300))
        XCTAssertGreaterThanOrEqual(at[4] - at[3], .milliseconds(300))
        XCTAssertEqual(c.state, .recording)
        XCTAssertEqual(events, [
            .started, .gapBegan,
            .problemBegan(.cannotHearTheCall), .problemCleared(.cannotHearTheCall),
        ])
        XCTAssertEqual(events.last?.hudText, "hearing the call again")

        c.stop()
        await c.untilWrittenOut()
        let saved = try savedFile()
        XCTAssertEqual(saved.gapCount, 1)
        let body = try String(contentsOf: saved.fileURL, encoding: .utf8)
        XCTAssertTrue(body.contains("- [2.0, 60.3]"), body)
        // the tries in a row are each kept; the one with the problem
        // standing is the problem's, and not kept again.
        XCTAssertEqual(records.first?.events, [
            .init(.gapBegan, atS: 2),
            .init(.rebuildFailed, atS: 60),
            .init(.rebuildFailed, atS: 60),
            .init(.rebuildFailed, atS: 60),
            .init(.problemBegan, atS: 60),
            .init(.gapEnded, atS: 60.3),
            .init(.problemCleared, atS: 60.3),
        ])
    }

    /// A rebuild can come back without complaint and still hear nothing —
    /// 002 §6's dead tap is all `noErr`. A rebuilt tap that does not hear
    /// its own start sound is a try that failed like any other: tried
    /// again, and never taken for a recovery.
    func testARebuiltTapThatDoesNotHearItsStartSoundIsATryThatFailed() async throws {
        source.rebuiltTapsThatHearNothing = 1
        let clock = FakeClock()
        var thresholds = retrying
        thresholds.probeTimeout = .milliseconds(300)
        let c = coordinator(thresholds: thresholds, clock: clock)
        c.start()
        await source.awaitStart()
        await play(loud(at: .zero), loud(at: .seconds(1)))

        clock.advance(by: .seconds(60))
        source.skip(to: .seconds(60))
        c.probeTapIsAlive()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(source.rebuilds, 1)
        XCTAssertEqual(c.state, .rebuilding, "nothing heard yet")

        await until { events.contains(.gapEnded) }
        XCTAssertEqual(source.rebuilds, 2)
        let at = source.rebuiltAt
        guard at.count == 2 else { return }
        XCTAssertGreaterThanOrEqual(at[1] - at[0], .milliseconds(400))
        XCTAssertEqual(events, [.started, .gapBegan, .gapEnded])

        c.stop()
        await c.untilWrittenOut()
        XCTAssertEqual(records.first?.events, [
            .init(.gapBegan, atS: 2),
            .init(.probeUnheard, atS: 60),
            .init(.gapEnded, atS: 60.3),
        ])
    }

    /// A settle, then three tries in a row 100 ms and 200 ms apart, then
    /// one every 300 ms with the problem standing.
    private var retrying: MeetingThresholds {
        .init(
            probeTimeout: .seconds(1), silenceTimeout: .seconds(5),
            silenceFloor: 0.001, quietNudgeAfter: .seconds(3_600),
            quietProbeWindow: .seconds(2),
            settleBeforeRebuild: .milliseconds(50),
            rebuildSpacing: [.milliseconds(100), .milliseconds(200)],
            retryWhileTheProblemStands: .milliseconds(300))
    }

    // MARK: - helpers

    private func savedFile() throws -> MeetingSummary {
        try XCTUnwrap(
            MeetingTranscriptFile.listAll(in: dir.appendingPathComponent("docs")).first)
    }

    /// The turns of the saved file, as its body has them.
    private func savedLines() throws -> [String] {
        let body = try String(contentsOf: try savedFile().fileURL, encoding: .utf8)
        return body.split(separator: "\n").filter { $0.hasPrefix("[") }.map(String.init)
    }

    /// The far side as the spool wrote it, read from the audio the meeting
    /// kept once its file was written.
    private func spooledThem() throws -> [Float]? {
        let kept = try FileManager.default.contentsOfDirectory(
            at: dir.appendingPathComponent("meeting-audio"), includingPropertiesForKeys: nil)
        return try kept.first { $0.pathExtension == "caf" }.map { try SpoolAudioFile.read($0).them }
    }

    private func rms<S: Sequence>(_ samples: S) -> Float where S.Element == Float {
        var sum: Float = 0
        var n: Float = 0
        for s in samples {
            sum += s * s
            n += 1
        }
        return n == 0 ? 0 : (sum / n).squareRoot()
    }

    /// Half a second of both sides talking.
    private func both(at: Duration) -> MeetingAudioChunk {
        let n = 8_000
        return .init(you: Array(repeating: 0.05, count: n),
                     them: (0..<n).map { sin(Float($0) * 0.05) * 0.3 }, at: at)
    }

    /// Half a second of the far side talking, and you not.
    private func them(at: Duration) -> MeetingAudioChunk {
        let n = 8_000
        return .init(you: Array(repeating: 0, count: n),
                     them: (0..<n).map { sin(Float($0) * 0.05) * 0.3 }, at: at)
    }

    /// Half a second of nothing on either side.
    private func silent(at: Duration) -> MeetingAudioChunk {
        .init(you: Array(repeating: 0, count: 8_000),
              them: Array(repeating: 0, count: 8_000), at: at)
    }

    /// The far side talking, and you.
    private func loud(at: Duration) -> MeetingAudioChunk {
        let n = 16_000
        return .init(you: Array(repeating: 0.05, count: n),
                     them: (0..<n).map { sin(Float($0) * 0.05) * 0.3 }, at: at)
    }

    /// You talking, and nothing from the far side.
    private func voice(at: Duration) -> MeetingAudioChunk {
        .init(you: Array(repeating: 0.05, count: 16_000),
              them: Array(repeating: 0, count: 16_000), at: at)
    }

    /// A tenth of a second of nothing on either side. Short, so an hour of
    /// it is not an hour of spool.
    private func quiet(at: Duration) -> MeetingAudioChunk {
        .init(you: Array(repeating: 0, count: 1_600),
              them: Array(repeating: 0, count: 1_600), at: at)
    }

    /// The quiet probe as the tap hears it: 0.3 s of a 1 kHz tone at
    /// -40 dBFS, RMS about 0.007.
    private func tone(at: Duration) -> MeetingAudioChunk {
        let n = 4_800
        return .init(you: Array(repeating: 0, count: n),
                     them: (0..<n).map { sin(Float($0) * 2 * .pi * 1_000 / 16_000) * 0.01 },
                     at: at)
    }

    /// Each chunk, and time for the coordinator to have taken it in before
    /// the next: a tone the source plays in answer lands in between.
    private func play(_ chunks: MeetingAudioChunk...) async {
        for chunk in chunks {
            source.send(chunk)
            try? await Task.sleep(for: .milliseconds(80))
        }
    }

    /// Until `done`, or two seconds, so a test against code that never gets
    /// there fails instead of hanging.
    private func until(_ done: () -> Bool) async {
        for _ in 0..<200 where !done() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: .milliseconds(50))
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

/// The tap, and the two tones it plays: the start sound on every start and
/// rebuild, and the quiet probe when asked.
private final class FakeSource: MeetingAudioSource, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<MeetingAudioChunk>.Continuation?
    private var starts = 0
    private var startsSeen = 0
    private var nextAt: Duration = .zero
    private var _rebuilds = 0
    private var _quietProbes = 0
    private var _anythingIsPlaying: Bool?

    var rebuilds: Int { lock.withLock { _rebuilds } }
    var quietProbes: Int { lock.withLock { _quietProbes } }

    /// Whether the start sound can be played: false is a mac with no
    /// output, where it never sounds and the tap has nothing to hear.
    var startSoundPlays: Bool {
        get { lock.withLock { _startSoundPlays } }
        set { lock.withLock { _startSoundPlays = newValue } }
    }
    private var _startSoundPlays = true

    var startSoundPlayed: Bool? { startSoundPlays }

    var anythingIsPlaying: Bool? {
        get { lock.withLock { _anythingIsPlaying } }
        set { lock.withLock { _anythingIsPlaying = newValue } }
    }

    func start() async throws -> AsyncStream<MeetingAudioChunk> {
        let (stream, continuation) = AsyncStream<MeetingAudioChunk>.makeStream()
        lock.withLock {
            self.continuation = continuation
            starts += 1
        }
        return stream
    }

    /// When each rebuild was asked for, by the real clock.
    var rebuiltAt: [ContinuousClock.Instant] { lock.withLock { _rebuiltAt } }
    private var _rebuiltAt: [ContinuousClock.Instant] = []

    /// The real source stamps the first chunk after an outage past it, so
    /// the meeting stays on one clock: the next chunk this sends is.
    func skip(to at: Duration) {
        lock.withLock { nextAt = max(nextAt, at) }
    }

    /// How many rebuilds from now come back without a word of complaint
    /// and a tap that hears nothing: every call `noErr`, every buffer zero.
    var rebuiltTapsThatHearNothing: Int {
        get { lock.withLock { _rebuiltTapsThatHearNothing } }
        set { lock.withLock { _rebuiltTapsThatHearNothing = newValue } }
    }
    private var _rebuiltTapsThatHearNothing = 0

    /// How many rebuilds from now throw, the device not there yet.
    var rebuildsThatFail: Int {
        get { lock.withLock { _rebuildsThatFail } }
        set { lock.withLock { _rebuildsThatFail = newValue } }
    }
    private var _rebuildsThatFail = 0

    /// A rebuilt tap plays the start sound, and hears it come back a moment
    /// later as far-side audio, the way the real one does.
    func rebuild() async throws {
        let at = try lock.withLock { () throws -> Duration? in
            _rebuilds += 1
            _rebuiltAt.append(ContinuousClock.now)
            if _rebuildsThatFail > 0 {
                _rebuildsThatFail -= 1
                throw DeviceGone()
            }
            if _rebuiltTapsThatHearNothing > 0 {
                _rebuiltTapsThatHearNothing -= 1
                return nil
            }
            return _startSoundPlays ? nextAt : nil
        }
        guard let at else { return }
        let n = 4_800
        send(.init(you: Array(repeating: 0, count: n),
                   them: (0..<n).map { sin(Float($0) * 0.05) * 0.3 }, at: at))
    }

    /// While set, the quiet probe comes back through the tap a moment after
    /// it is asked for, the way it does on a working one.
    var hearsTheQuietProbe: Bool {
        get { lock.withLock { _hearsTheQuietProbe } }
        set { lock.withLock { _hearsTheQuietProbe = newValue } }
    }
    private var _hearsTheQuietProbe = false

    /// While set, the quiet probe cannot be played at all: no output.
    var quietProbeCannotPlay: Bool {
        get { lock.withLock { _quietProbeCannotPlay } }
        set { lock.withLock { _quietProbeCannotPlay = newValue } }
    }
    private var _quietProbeCannotPlay = false

    func playQuietProbe() async throws {
        let (hears, cannotPlay, at) = lock.withLock { () -> (Bool, Bool, Duration) in
            _quietProbes += 1
            return (_hearsTheQuietProbe, _quietProbeCannotPlay, nextAt)
        }
        if cannotPlay { throw NoOutput() }
        guard hears else { return }
        let n = 4_800
        send(.init(you: Array(repeating: 0, count: n),
                   them: (0..<n).map { sin(Float($0) * 2 * .pi * 1_000 / 16_000) * 0.01 },
                   at: at))
    }

    func stop() async {
        let continuation = lock.withLock { () -> AsyncStream<MeetingAudioChunk>.Continuation? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.finish()
    }

    func send(_ chunk: MeetingAudioChunk) {
        let continuation = lock.withLock { () -> AsyncStream<MeetingAudioChunk>.Continuation? in
            nextAt = chunk.at + chunk.duration
            return self.continuation
        }
        continuation?.yield(chunk)
    }

    /// Until the tap has been opened once more than the last call saw, or
    /// two seconds.
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

private struct DeviceGone: Error {}
private struct NoOutput: Error {}
private struct WillNotLoad: Error {}

/// What the coordinator took to keep the mac awake, and gave back.
@MainActor
private final class Wakefulness {
    var held = 0
    var released = 0
}

/// Counts what it is fed; says nothing.
private final class FakeTranscriber: MeetingTranscriber, @unchecked Sendable {
    let lines: AsyncStream<LiveLine>
    private let lock = NSLock()
    private var _fed: [MeetingAudioChunk] = []
    private var _willNotLoad = false

    init() {
        (lines, _) = AsyncStream<LiveLine>.makeStream()
    }

    var fed: [MeetingAudioChunk] {
        lock.withLock { _fed }
    }

    /// While set, the model will not load.
    var willNotLoad: Bool {
        get { lock.withLock { _willNotLoad } }
        set { lock.withLock { _willNotLoad = newValue } }
    }

    func begin() async throws {
        if willNotLoad { throw WillNotLoad() }
    }
    func feed(_ chunk: MeetingAudioChunk) async {
        lock.withLock { _fed.append(chunk) }
    }
    /// While set, it writes a turn for every side of every chunk it was fed
    /// with sound in it, at the chunk's stamp: a model that transcribes
    /// whatever it is given, our own tones included.
    var transcribesWhatItIsFed: Bool {
        get { lock.withLock { _transcribesWhatItIsFed } }
        set { lock.withLock { _transcribesWhatItIsFed = newValue } }
    }
    private var _transcribesWhatItIsFed = false

    func finish() async -> [MeetingTurn] {
        guard transcribesWhatItIsFed else { return [] }
        return fed.flatMap { chunk -> [MeetingTurn] in
            var turns: [MeetingTurn] = []
            if chunk.you.contains(where: { abs($0) > 0.001 }) {
                turns.append(.init(speaker: .you, at: chunk.at, text: "you said something"))
            }
            if chunk.themRMS > 0.001 {
                turns.append(.init(speaker: .them(nil), at: chunk.at, text: "they said something"))
            }
            return turns
        }
    }
    func transcribe(you: [Float], them: [Float]) async throws -> [MeetingTurn] { [] }
}

private struct FakeDiarizer: MeetingDiarizer {
    func split(them: [Float], turns: [MeetingTurn]) async -> [MeetingTurn] { turns }
}
