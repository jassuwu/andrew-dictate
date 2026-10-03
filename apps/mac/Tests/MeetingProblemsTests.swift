import XCTest

/// A meeting that cannot hear you, or cannot save, says so while it can
/// still be fixed: through the coordinator and its fakes, the problems that
/// stand until they clear, and a start that fails saying which part did.
@MainActor
final class MeetingProblemsTests: XCTestCase {
    private var dir: URL!
    private var source: FakeSource!
    private var transcriber: FakeTranscriber!
    private var events: [MeetingEvent] = []
    private var records: [MeetingRecord] = []
    /// The coordinator `play` waits on.
    private weak var playing: MeetingCoordinator?

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-problems-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        source = FakeSource()
        transcriber = FakeTranscriber()
        events = []
        records = []
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private var spool: MeetingSpool {
        MeetingSpool(root: dir.appendingPathComponent("spool"))
    }

    /// The test's own numbers: a one-second start window, and the mic
    /// given ten seconds of silence, in meeting time.
    private func coordinator(
        thresholds: MeetingThresholds = .init(
            probeTimeout: .seconds(1), silenceTimeout: .seconds(60),
            silenceFloor: 0.001, quietNudgeAfter: .seconds(3_600),
            quietProbeWindow: .seconds(2),
            settleBeforeRebuild: .milliseconds(50)),
        writer: FallibleWriter = FallibleWriter(),
        disk: FakeDisk = FakeDisk(),
        clock: FakeClock = FakeClock()
    ) -> MeetingCoordinator {
        let docs = dir.appendingPathComponent("docs")
        let c = MeetingCoordinator(
            source: source,
            makeTranscriber: { [transcriber] _ in transcriber! },
            diarizer: FakeDiarizer(),
            spool: spool,
            hookRunner: HookRunner(logURL: dir.appendingPathComponent("hooks.log")),
            keptAudio: KeptAudio(
                root: dir.appendingPathComponent("meeting-audio"),
                compress: { _, _ in throw CocoaError(.featureUnsupported) }),
            thresholds: thresholds,
            now: { clock.now },
            keepAwake: .init(hold: { NSObject() }, release: { _ in }),
            openAudioFile: { try writer.open($0) },
            freeSpace: { disk.free(at: $0) },
            preferences: {
                MeetingPreferences(folder: docs, hook: nil, model: .whisperLargeV3Turbo)
            }
        )
        c.onEvent = { [weak self] in self?.events.append($0) }
        c.keepMeetingRecord = { [weak self] in self?.records.append($0) }
        playing = c
        return c
    }

    // MARK: - the mic

    /// The call talks for ten seconds and the mic hands over nothing but
    /// silence: a problem naming the mic, said on the lamp, until the mic
    /// is heard again.
    func testAMicSilentWhileTheCallTalksIsAProblemNamingItUntilItIsHeard() async throws {
        source.micName = "MacBook Pro Microphone"
        let c = coordinator()
        c.start()
        await source.awaitStart()
        await play(both(at: .zero))
        for s in 1...9 {
            await play(theyTalk(at: .seconds(s)))
        }
        XCTAssertEqual(c.problems, [], "nine seconds is not ten")

        await play(theyTalk(at: .seconds(10)))
        XCTAssertEqual(c.problems, [.cannotHearYourMic("MacBook Pro Microphone")])
        XCTAssertEqual(events, [.started, .problemBegan(.cannotHearYourMic("MacBook Pro Microphone"))])
        XCTAssertEqual(events.last?.hudText, "can't hear your mic — macbook pro microphone")

        await play(both(at: .seconds(11)))
        XCTAssertEqual(c.problems, [])
        XCTAssertEqual(events.last, .problemCleared(.cannotHearYourMic("MacBook Pro Microphone")))
        XCTAssertEqual(events.last?.hudText, "hearing your mic again")

        c.stop()
        await c.untilWrittenOut()
        XCTAssertEqual(records.first?.events, [
            .init(.init(rawValue: "mic-silent"), atS: 11),
            .init(.init(rawValue: "mic-silent-cleared"), atS: 12),
        ])
    }

    /// Half a minute with nothing from either side: a quiet room, or no
    /// call at all. A mic is not missed when there is nobody to answer.
    func testBothSidesSilentIsNothingToSay() async throws {
        source.micName = "MacBook Pro Microphone"
        let c = coordinator()
        c.start()
        await source.awaitStart()
        await play(both(at: .zero))
        for s in 1...30 {
            await play(silent(at: .seconds(s)))
        }

        XCTAssertEqual(c.problems, [])
        XCTAssertEqual(events, [.started])
        c.stop()
        await c.untilWrittenOut()
        XCTAssertEqual(records.first?.events, [])
    }

    /// The mac's input muted on purpose is silent on purpose. It ends a
    /// problem that stood, and the lamp says why; while it lasts the call
    /// can talk as long as it likes and nothing is said; the record notes
    /// both ends of it.
    func testAMutedMicIsNotAFaultAndEndsTheProblemThatStood() async throws {
        source.micName = "MacBook Pro Microphone"
        let c = coordinator()
        c.start()
        await source.awaitStart()
        await play(both(at: .zero))
        for s in 1...10 {
            await play(theyTalk(at: .seconds(s)))
        }
        XCTAssertEqual(c.problems, [.cannotHearYourMic("MacBook Pro Microphone")])

        source.tell(.init(kind: .micMuted, mic: "MacBook Pro Microphone", at: .seconds(11)))
        await until { c.problems.isEmpty }
        XCTAssertEqual(c.problems, [])
        XCTAssertEqual(events.last, .micMuted)
        XCTAssertEqual(events.last?.hudText, "your mic is muted")

        for s in 11...25 {
            await play(theyTalk(at: .seconds(s)))
        }
        XCTAssertEqual(c.problems, [], "muted is not a fault")

        source.tell(.init(kind: .micUnmuted, mic: "MacBook Pro Microphone", at: .seconds(26)))
        await until { events.last == .micUnmuted }
        XCTAssertNil(events.last?.hudText)
        await play(both(at: .seconds(26)))
        XCTAssertEqual(events, [
            .started, .problemBegan(.cannotHearYourMic("MacBook Pro Microphone")),
            .micMuted, .micUnmuted,
        ])

        c.stop()
        await c.untilWrittenOut()
        XCTAssertEqual(records.first?.events, [
            .init(.init(rawValue: "mic-silent"), atS: 11),
            .init(.init(rawValue: "mic-muted"), atS: 11),
            .init(.init(rawValue: "mic-silent-cleared"), atS: 11),
            .init(.init(rawValue: "mic-unmuted"), atS: 26),
        ])
    }

    /// The mic was muted before the meeting began: said once the meeting
    /// is recording, after `recording a meeting`, so that line does not
    /// cover it.
    func testAMicMutedFromTheStartIsSaidOnceTheMeetingRecords() async throws {
        let c = coordinator()
        c.start()
        await source.awaitStart()
        source.tell(.init(kind: .micMuted, mic: "MacBook Pro Microphone", at: .zero))
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(events, [], "nothing is recording yet")

        await play(both(at: .zero))
        XCTAssertEqual(events, [.started, .micMuted])
    }

    // MARK: - the audio

    /// The spool will not take the audio. The meeting goes on — the live
    /// transcript is still fed — with a problem said on the lamp, every
    /// chunk that did not go in is counted, and the first that does go in
    /// ends it.
    func testAnAudioWriteThatFailsIsAProblemTheMeetingTranscribesThrough() async throws {
        let writer = FallibleWriter()
        let c = coordinator(writer: writer)
        c.start()
        await source.awaitStart()
        await play(both(at: .zero))

        writer.fails = true
        await play(both(at: .seconds(1)), both(at: .seconds(2)), both(at: .seconds(3)))
        XCTAssertEqual(c.problems, [.cannotSaveTheAudio])
        XCTAssertEqual(c.state, .recording)
        XCTAssertEqual(events, [.started, .problemBegan(.cannotSaveTheAudio)])
        XCTAssertEqual(events.last?.hudText, "can't save the audio — still transcribing")
        XCTAssertEqual(transcriber.fed.map(\.at), [.zero, .seconds(1), .seconds(2), .seconds(3)])

        writer.fails = false
        await play(both(at: .seconds(4)))
        XCTAssertEqual(c.problems, [])
        XCTAssertEqual(events.last, .problemCleared(.cannotSaveTheAudio))
        XCTAssertEqual(events.last?.hudText, "saving the audio again")

        c.stop()
        await c.untilWrittenOut()
        XCTAssertEqual(records.first?.spoolWriteFailures, 3)
        XCTAssertEqual(records.first?.events, [
            .init(.init(rawValue: "audio-unsaved"), atS: 2),
            .init(.init(rawValue: "audio-unsaved-cleared"), atS: 5),
        ])
    }

    /// Half a gigabyte free on the spool's disk when the meeting starts: it
    /// starts all the same, and says the disk is nearly full until a look
    /// a minute later finds room again.
    func testLowDiskAtTheStartIsSaidAndTheMeetingRecordsAllTheSame() async throws {
        let disk = FakeDisk(free: 500_000_000)
        let c = coordinator(disk: disk)
        c.start()
        await source.awaitStart()
        await play(both(at: .zero))
        await until { !c.problems.isEmpty }

        XCTAssertEqual(c.problems, [.diskNearlyFull])
        XCTAssertEqual(c.state, .recording)
        XCTAssertEqual(events, [.started, .problemBegan(.diskNearlyFull)])
        XCTAssertEqual(events.last?.hudText, "disk nearly full")
        XCTAssertEqual(disk.lookedAt.map(\.path), [dir.appendingPathComponent("spool").path])

        disk.free = 5_000_000_000
        for s in 1...59 {
            await play(both(at: .seconds(s)))
        }
        XCTAssertEqual(c.problems, [.diskNearlyFull], "looked at once a minute")

        await play(both(at: .seconds(60)))
        await until { c.problems.isEmpty }
        XCTAssertEqual(c.problems, [])
        XCTAssertEqual(events.last, .problemCleared(.diskNearlyFull))
        XCTAssertEqual(events.last?.hudText, "the disk has room again")

        c.stop()
        await c.untilWrittenOut()
        XCTAssertEqual(records.first?.events, [
            .init(.init(rawValue: "disk-nearly-full"), atS: 1),
            .init(.init(rawValue: "disk-nearly-full-cleared"), atS: 61),
        ])
    }

    // MARK: - the call unheard

    /// The tap cannot be rebuilt, and the source could not keep even the
    /// mic going on its own: nothing at all is being recorded, and the
    /// lamp must not say your side is. Once a later try brings the mic back
    /// alone, it says the call is unheard and your side recorded.
    func testWithNothingDeliveredTheLampDoesNotClaimYourSideIsRecorded() async throws {
        source.rebuildsFail = true
        source.capturing = .nothing
        let clock = FakeClock()
        let c = coordinator(thresholds: retrying, clock: clock)
        c.start()
        await source.awaitStart()
        await play(both(at: .zero), both(at: .seconds(1)))

        clock.advance(by: .seconds(60))
        c.probeTapIsAlive()
        await until { c.problem != nil }
        XCTAssertEqual(c.problems, [.cannotHearAnything])
        XCTAssertEqual(events.last, .problemBegan(.cannotHearAnything))
        XCTAssertEqual(events.last?.hudText, "can't hear the call or your mic — still trying")

        source.capturing = .yourSideAlone
        await until { c.problem == .cannotHearTheCall }
        XCTAssertEqual(c.problems, [.cannotHearTheCall])
        XCTAssertEqual(events.last?.hudText, "can't hear the call — still recording your side")

        c.stop()
        await c.untilWrittenOut()
        XCTAssertEqual(
            records.first?.events.filter { $0.label == .problemBegan }.count, 1,
            "the same problem in new words is noted once")
    }

    /// The tap cannot be rebuilt and the source keeps the mic going alone,
    /// the far side silence: the lamp says your side is still recorded,
    /// and it is — what you say reaches the transcriber, and the far
    /// side's silence is no reason to say the mic is not heard.
    func testWithTheCallUnheardYourSideIsStillTranscribed() async throws {
        source.rebuildsFail = true
        source.capturing = .yourSideAlone
        source.micName = "MacBook Pro Microphone"
        let clock = FakeClock()
        let c = coordinator(thresholds: retrying, clock: clock)
        c.start()
        await source.awaitStart()
        await play(both(at: .zero), both(at: .seconds(1)))

        clock.advance(by: .seconds(60))
        c.probeTapIsAlive()
        await until { c.problem != nil }
        XCTAssertEqual(c.problems, [.cannotHearTheCall])
        XCTAssertEqual(events.last?.hudText, "can't hear the call — still recording your side")

        for s in 60...75 {
            await play(you(at: .seconds(s)))
        }
        let fed = transcriber.fed.filter { $0.at >= .seconds(60) }
        XCTAssertEqual(fed.count, 16)
        XCTAssertTrue(fed.allSatisfy { $0.youRMS > 0.01 && $0.themRMS == 0 })
        XCTAssertEqual(c.problems, [.cannotHearTheCall])
        XCTAssertEqual(c.state, .rebuilding)
    }

    /// Your side kept coming from the mic alone while a later try built the
    /// whole rig again, slowly. The rebuilt tap's start sound is ours, not
    /// the call: its window runs from the first chunk with the far side in
    /// it again, not from one of the mic's own while the tap was still being
    /// built — so the chirp never reaches the transcriber as somebody
    /// speaking, and it ends the problem.
    func testTheStartSoundAfterTheMicWasAloneIsNotTheCall() async throws {
        source.rebuildsFail = true
        source.capturing = .yourSideAlone
        let clock = FakeClock()
        let c = coordinator(thresholds: retrying, clock: clock)
        c.start()
        await source.awaitStart()
        await play(both(at: .zero), both(at: .seconds(1)))
        clock.advance(by: .seconds(60))
        c.probeTapIsAlive()
        await until { c.problem != nil }
        await play(you(at: .seconds(60)))

        source.rebuildTakes = .milliseconds(600)
        source.rebuildsFail = false
        var s = 61
        while !events.contains(.problemCleared(.cannotHearTheCall)), s < 200 {
            await play(you(at: .seconds(s)))
            s += 1
        }

        XCTAssertEqual(events.last, .problemCleared(.cannotHearTheCall))
        XCTAssertGreaterThan(s, 64, "the mic alone went on for longer than the start window")
        let fed = transcriber.fed.filter { $0.at >= .seconds(60) }
        XCTAssertEqual(fed.filter { $0.themRMS > 0 }.count, 0, "the start sound is ours")
    }

    /// The far side went quiet while something played, and the tap did not
    /// hear the quiet probe: taken for dead. The rig goes on delivering your
    /// side while the new one is built beside it, slowly, and it is the new
    /// rig's start sound that proves the tap, wherever the old rig's chunks
    /// had got to by then. The source says where it played it, and the
    /// window opens there: the chirp is never handed to the transcriber as
    /// somebody speaking, and it ends the gap.
    func testTheStartSoundOfARigBuiltBesideTheLiveOneIsNotTheCall() async throws {
        source.anythingIsPlaying = true
        source.capturing = .bothSides
        source.saysWhereTheStartSoundPlayed = true
        source.rebuildTakes = .milliseconds(800)
        let c = coordinator(thresholds: .init(
            probeTimeout: .seconds(1), silenceTimeout: .seconds(5),
            silenceFloor: 0.001, quietNudgeAfter: .seconds(3_600),
            quietProbeWindow: .seconds(2),
            settleBeforeRebuild: .milliseconds(50)))
        c.start()
        await source.awaitStart()
        await play(both(at: .zero))
        // asked at 7, missed by 10.
        var s = 1
        while !events.contains(.gapBegan), s < 20 {
            await play(you(at: .seconds(s)))
            s += 1
        }
        XCTAssertEqual(events, [.started, .gapBegan])
        while !events.contains(.gapEnded), s < 200 {
            await play(you(at: .seconds(s)))
            s += 1
        }

        XCTAssertEqual(events, [.started, .gapBegan, .gapEnded])
        let played = try XCTUnwrap(source.startSoundAt)
        XCTAssertGreaterThan(played, .seconds(12), "the old rig's chunks went on while it was built")
        let fed = transcriber.fed.filter { $0.at >= .seconds(10) }
        XCTAssertTrue(fed.contains { $0.at == played }, "the start sound reached the transcriber")
        XCTAssertEqual(fed.filter { $0.themRMS > 0 }.count, 0, "the start sound is ours")
    }

    /// A settle, then three tries in a row 100 ms and 200 ms apart, then
    /// one every 300 ms with the problem standing.
    private var retrying: MeetingThresholds {
        .init(
            probeTimeout: .seconds(1), silenceTimeout: .seconds(60),
            silenceFloor: 0.001, quietNudgeAfter: .seconds(3_600),
            quietProbeWindow: .seconds(2),
            settleBeforeRebuild: .milliseconds(50),
            rebuildSpacing: [.milliseconds(100), .milliseconds(200)],
            retryWhileTheProblemStands: .milliseconds(300))
    }

    // MARK: - a mic that never delivers

    /// The default mic is there and never calls back — a headset stuck, an
    /// interface with no clock, a phone's mic over continuity — so the tap
    /// is never heard and nothing ever arrives. Past the probe timeout and
    /// the allowance on the wall, the built-in mic is tried; nothing from
    /// that either, and the start fails as the mic's, naming the one it
    /// was on, rather than getting ready for ever.
    func testAMicThatNeverDeliversAtTheStartIsTriedOnTheBuiltInMicThenNamed() async throws {
        source.micName = "AirPods Pro"
        source.rebuildsDeliverNothing = true
        let clock = FakeClock()
        let c = coordinator(clock: clock)
        c.start()
        await source.awaitStart()
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(source.rebuiltOn, [], "the wall has not moved")

        clock.advance(by: .seconds(4))
        await until { source.rebuiltOn == ["built-in"] }
        XCTAssertEqual(source.rebuiltOn, ["built-in"])
        XCTAssertEqual(c.state, .provingItCanHear)
        XCTAssertEqual(events, [])

        clock.advance(by: .seconds(4))
        await until { c.state == .idle }
        XCTAssertEqual(c.state, .idle, "the start failed")
        c.stop()
        await c.untilWrittenOut()
        XCTAssertEqual(events, [.micFailed("AirPods Pro")])
        XCTAssertEqual(events.first?.hudText, "can't start your mic — airpods pro")
        XCTAssertEqual(records.first?.outcome, .nothingKept(.micFailed))
        XCTAssertEqual(records.first?.events.map(\.label), [.init(rawValue: "mic-delivered-nothing")])
    }

    /// The same stuck mic, and the built-in one delivers: its start sound
    /// is heard, and the meeting records on it.
    func testAMicThatNeverDeliversAtTheStartGivesWayToTheBuiltInMic() async throws {
        source.micName = "AirPods Pro"
        let clock = FakeClock()
        let c = coordinator(clock: clock)
        c.start()
        await source.awaitStart()
        clock.advance(by: .seconds(4))
        await until { c.state == .recording }

        XCTAssertEqual(source.rebuiltOn, ["built-in"])
        XCTAssertEqual(c.state, .recording)
        XCTAssertEqual(events, [.started])
    }

    /// The headset stalls mid-call: nothing at all arrives, and the wake
    /// finds the tap silent. Rebuilt on the same mic, the rig delivers
    /// nothing in its time either, so the next try is on the built-in mic;
    /// and with nothing arriving, the lamp says neither side is heard, not
    /// that your side is still recorded.
    func testARebuiltRigThatDeliversNothingIsTriedNextOnTheBuiltInMicAndTheLampSaysSo() async throws {
        source.micName = "AirPods Pro"
        source.rebuildsDeliverNothing = true
        let clock = FakeClock()
        var thresholds = retrying
        thresholds.probeTimeout = .milliseconds(300)
        let c = coordinator(thresholds: thresholds, clock: clock)
        c.start()
        await source.awaitStart()
        await play(both(at: .zero), both(at: .seconds(1)))

        clock.advance(by: .seconds(60))
        c.probeTapIsAlive()
        await until { source.rebuiltOn.count == 1 }
        XCTAssertEqual(source.rebuiltOn, ["default"])
        clock.advance(by: .seconds(5))
        await until { c.problem != nil }

        XCTAssertEqual(Array(source.rebuiltOn.prefix(2)), ["default", "built-in"])
        XCTAssertEqual(c.problems, [.cannotHearAnything])
        XCTAssertEqual(events.last?.hudText, "can't hear the call or your mic — still trying")
    }

    // MARK: - a start that fails

    /// The mic permission was taken back in system settings — or never
    /// given, by a setup for meetings only. Asked before anything is
    /// built: the meeting does not start, the lamp says the mic is not
    /// allowed, and setup is opened at it.
    func testAMicThatIsNotAllowedRefusesTheStartAndOpensSetup() async throws {
        source.micAllowed = false
        let c = coordinator()
        c.start()
        await c.untilWrittenOut()

        XCTAssertEqual(c.state, .idle)
        XCTAssertEqual(events, [.micNotAllowed])
        XCTAssertEqual(events.first?.hudText, "the mic isn't allowed — opening setup")
        XCTAssertEqual(events.first?.opensSetup, true)
        XCTAssertEqual(source.starts, 0, "nothing was built")
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.outcome, .nothingKept(.micNotAllowed))
        XCTAssertEqual(records.first?.outcome.why, "mic-not-allowed")
    }

    /// The tap opened and the mic did not: a usb mic that will not start,
    /// or one gone in the moment it was asked for. The lamp names it, and
    /// no window opens — there is no switch in setup that starts a mic.
    func testAMicThatWouldNotStartIsNamedAndOpensNothing() async throws {
        source.startFails = CaptureFailed(fault: .mic("Yeti"))
        let c = coordinator()
        c.start()
        await source.awaitStart()
        await c.untilWrittenOut()

        XCTAssertEqual(c.state, .idle)
        XCTAssertEqual(events, [.micFailed("Yeti")])
        XCTAssertEqual(events.first?.hudText, "can't start your mic — yeti")
        XCTAssertEqual(events.first?.opensSetup, false)
        XCTAssertEqual(MeetingEvent.micFailed(nil).hudText, "no mic to record you with")
        XCTAssertEqual(records.first?.outcome, .nothingKept(.micFailed))
        XCTAssertEqual(records.first?.outcome.why, "mic-failed")
    }

    /// The tap would not open: the fix is the system-audio switch, so the
    /// lamp says the mac cannot be heard and setup opens at it — and so it
    /// does for an error that does not say which part it was.
    func testATapThatWouldNotOpenCannotHearTheMacAndOpensSetup() async throws {
        source.startFails = CaptureFailed(fault: .tap)
        let c = coordinator()
        c.start()
        await source.awaitStart()
        await c.untilWrittenOut()

        XCTAssertEqual(c.state, .idle)
        XCTAssertEqual(events, [.cannotHear])
        XCTAssertEqual(events.first?.hudText, "can't hear the mac — opening setup")
        XCTAssertEqual(events.first?.opensSetup, true)
        XCTAssertEqual(records.first?.outcome, .nothingKept(.tapNeverHeard))
        XCTAssertEqual(records.first?.outcome.why, "tap-never-heard")

        source.startFails = CocoaError(.featureUnsupported)
        c.start()
        await source.awaitStart()
        await c.untilWrittenOut()
        XCTAssertEqual(events, [.cannotHear, .cannotHear])
    }

    /// The disk is full: the spool's folder was made and its audio file
    /// could not be. The meeting has nowhere to keep its audio, and that is
    /// what the lamp says — not that the model failed — with no window over
    /// it. Nothing is left in the spool for every launch after to build the
    /// meetings for, and the record says why nothing was kept.
    func testASpoolThatCannotBeMadeIsTheDisksFailureAndLeavesNothingBehind() async throws {
        let writer = FallibleWriter()
        writer.opensFail = true
        let c = coordinator(writer: writer)
        c.start()
        await c.untilWrittenOut()

        XCTAssertEqual(c.state, .idle)
        XCTAssertEqual(events.count, 1, "\(events)")
        guard case .spoolFailed(let reason) = events.first else {
            return XCTFail("expected spoolFailed, got \(events)")
        }
        XCTAssertEqual(
            events.first?.hudText, "can't write the meeting's audio to disk — \(reason)")
        XCTAssertEqual(events.first?.opensSetup, false)
        XCTAssertEqual(source.starts, 0, "no tap was opened for it")
        XCTAssertEqual(records.map(\.outcome), [.nothingKept(.spoolFailed)])
        XCTAssertEqual(records.first?.outcome.why, "spool-failed")
        XCTAssertFalse(spool.mayHoldOrphans(), "nothing is left in the spool")
    }

    /// The spool's folder itself could not be made: said the same way.
    func testASpoolFolderThatCannotBeMadeIsSaidTheSameWay() async throws {
        try Data("not a folder".utf8).write(to: spool.root)
        let c = coordinator()
        c.start()
        await c.untilWrittenOut()

        XCTAssertEqual(c.state, .idle)
        guard case .spoolFailed = events.first, events.count == 1 else {
            return XCTFail("expected spoolFailed, got \(events)")
        }
        XCTAssertEqual(records.map(\.outcome), [.nothingKept(.spoolFailed)])
    }

    // MARK: - several at once

    /// The disk nearly full from the start, and the mic gone silent while
    /// the call talks: both stand, the mic first, and each clears on its
    /// own, with the other still said until it does.
    func testTwoProblemsStandAtOnceAndClearOnTheirOwn() async throws {
        source.micName = "AirPods Pro"
        let disk = FakeDisk(free: 500_000_000)
        let c = coordinator(disk: disk)
        c.start()
        await source.awaitStart()
        await play(both(at: .zero))
        await until { !c.problems.isEmpty }
        for s in 1...10 {
            await play(theyTalk(at: .seconds(s)))
        }
        XCTAssertEqual(c.problems, [.cannotHearYourMic("AirPods Pro"), .diskNearlyFull])
        XCTAssertEqual(c.problem, .cannotHearYourMic("AirPods Pro"))

        await play(both(at: .seconds(11)))
        XCTAssertEqual(c.problems, [.diskNearlyFull])

        disk.free = 5_000_000_000
        for s in 12...60 {
            await play(both(at: .seconds(s)))
        }
        await until { c.problems.isEmpty }
        XCTAssertEqual(c.problems, [])
        XCTAssertEqual(events, [
            .started,
            .problemBegan(.diskNearlyFull),
            .problemBegan(.cannotHearYourMic("AirPods Pro")),
            .problemCleared(.cannotHearYourMic("AirPods Pro")),
            .problemCleared(.diskNearlyFull),
        ])
    }

    // MARK: - helpers

    /// A second of both sides talking.
    private func both(at: Duration) -> MeetingAudioChunk {
        let n = 16_000
        return .init(you: Array(repeating: 0.05, count: n),
                     them: (0..<n).map { sin(Float($0) * 0.05) * 0.3 }, at: at)
    }

    /// A second of the far side talking, and the mic handing over silence:
    /// not a quiet room, which is never all zeros, but a mic that is not
    /// there.
    private func theyTalk(at: Duration) -> MeetingAudioChunk {
        let n = 16_000
        return .init(you: Array(repeating: 0, count: n),
                     them: (0..<n).map { sin(Float($0) * 0.05) * 0.3 }, at: at)
    }

    /// A second of you talking, and the far side as a rig with the mic
    /// alone hands it over: silence.
    private func you(at: Duration) -> MeetingAudioChunk {
        .init(you: Array(repeating: 0.05, count: 16_000),
              them: Array(repeating: 0, count: 16_000), at: at)
    }

    /// A second of nothing on either side.
    private func silent(at: Duration) -> MeetingAudioChunk {
        .init(you: Array(repeating: 0, count: 16_000),
              them: Array(repeating: 0, count: 16_000), at: at)
    }

    /// Each chunk, once the coordinator has taken in the one before.
    private func play(_ chunks: MeetingAudioChunk...) async {
        for chunk in chunks {
            source.send(chunk)
            let end = chunk.at + chunk.duration
            for _ in 0..<200 where (playing?.elapsed ?? end) < end {
                try? await Task.sleep(for: .milliseconds(10))
            }
            try? await Task.sleep(for: .milliseconds(20))
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

/// The tap and the mic: chunks as the test sends them, the mic's name, and
/// what it did by itself, told on its own stream.
private final class FakeSource: MeetingAudioSource, @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: AsyncStream<MeetingAudioChunk>.Continuation?
    private var told: AsyncStream<MeetingSourceEvent>.Continuation?
    private var events = AsyncStream<MeetingSourceEvent> { $0.finish() }
    private var _starts = 0
    private var startsSeen = 0

    var micName: String? {
        get { lock.withLock { _micName } }
        set { lock.withLock { _micName = newValue } }
    }
    private var _micName: String?

    var sourceEvents: AsyncStream<MeetingSourceEvent> {
        lock.withLock { events }
    }

    /// How many times the tap was opened.
    var starts: Int {
        lock.withLock { _starts }
    }

    /// Whether the app may use the mic: false is a permission taken back.
    var micAllowed: Bool {
        get { lock.withLock { _micAllowed } }
        set { lock.withLock { _micAllowed = newValue } }
    }
    private var _micAllowed = true

    func micAllowed() async -> Bool {
        micAllowed
    }

    /// What the next start throws, if anything: the tap or the mic that
    /// would not come up.
    var startFails: (any Error)? {
        get { lock.withLock { _startFails } }
        set { lock.withLock { _startFails = newValue } }
    }
    private var _startFails: (any Error)?

    func start() async throws -> AsyncStream<MeetingAudioChunk> {
        let (stream, chunks) = AsyncStream<MeetingAudioChunk>.makeStream()
        let (events, told) = AsyncStream<MeetingSourceEvent>.makeStream()
        let fails = lock.withLock { () -> (any Error)? in
            _starts += 1
            if let fails = _startFails { return fails }
            self.chunks = chunks
            self.told = told
            self.events = events
            return nil
        }
        if let fails { throw fails }
        return stream
    }

    /// While set, every rebuild throws: the tap is not coming back.
    var rebuildsFail: Bool {
        get { lock.withLock { _rebuildsFail } }
        set { lock.withLock { _rebuildsFail = newValue } }
    }
    private var _rebuildsFail = false

    /// How long a rebuild that works takes, on the real clock.
    var rebuildTakes: Duration {
        get { lock.withLock { _rebuildTakes } }
        set { lock.withLock { _rebuildTakes = newValue } }
    }
    private var _rebuildTakes: Duration = .zero

    /// Which mic each rebuild was asked to bring the rig up on: the
    /// default, or the built-in one.
    var rebuiltOn: [String] {
        lock.withLock { _rebuiltOn }
    }
    private var _rebuiltOn: [String] = []

    /// While set, a rebuild comes back without complaint and nothing ever
    /// arrives from it: a mic that is there and does not call back.
    var rebuildsDeliverNothing: Bool {
        get { lock.withLock { _rebuildsDeliverNothing } }
        set { lock.withLock { _rebuildsDeliverNothing = newValue } }
    }
    private var _rebuildsDeliverNothing = false

    func rebuild() async throws {
        lock.withLock { _rebuiltOn.append("default") }
        try await rebuilt()
    }

    func rebuildOnTheBuiltInMic() async throws {
        lock.withLock { _rebuiltOn.append("built-in") }
        try await rebuilt()
    }

    /// One that works brings both sides back and plays the start sound,
    /// which the tap hears a moment later as far-side audio. One that says
    /// where it played it hears it a tenth of a second after it returns,
    /// the way the real tap's chunk comes after the player has started.
    private func rebuilt() async throws {
        if rebuildsFail { throw DeviceGone() }
        if rebuildsDeliverNothing { return }
        try? await Task.sleep(for: rebuildTakes)
        let (at, says) = lock.withLock { () -> (Duration, Bool) in
            _capturing = .bothSides
            if _saysWhereTheStartSoundPlayed { _startSoundAt = nextAt }
            return (nextAt, _saysWhereTheStartSoundPlayed)
        }
        let n = 4_800
        let tone = MeetingAudioChunk(
            you: Array(repeating: 0, count: n),
            them: (0..<n).map { sin(Float($0) * 0.05) * 0.3 }, at: at)
        guard says else { return send(tone) }
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            self.send(tone)
        }
    }

    /// While set, a rebuild says where on its clock it played the start
    /// sound, as the real source does.
    var saysWhereTheStartSoundPlayed: Bool {
        get { lock.withLock { _saysWhereTheStartSoundPlayed } }
        set { lock.withLock { _saysWhereTheStartSoundPlayed = newValue } }
    }
    private var _saysWhereTheStartSoundPlayed = false

    var startSoundAt: Duration? {
        lock.withLock { _startSoundAt }
    }
    private var _startSoundAt: Duration?

    /// What the source last heard of the mac playing anything.
    var anythingIsPlaying: Bool? {
        get { lock.withLock { _anythingIsPlaying } }
        set { lock.withLock { _anythingIsPlaying = newValue } }
    }
    private var _anythingIsPlaying: Bool?

    /// What it says it is delivering: after a rebuild that threw, the mic
    /// alone, or nothing.
    var capturing: MeetingCapture? {
        get { lock.withLock { _capturing } }
        set { lock.withLock { _capturing = newValue } }
    }
    private var _capturing: MeetingCapture?

    func stop() async {
        let (chunks, told) = lock.withLock {
            defer {
                self.chunks = nil
                self.told = nil
            }
            return (self.chunks, self.told)
        }
        chunks?.finish()
        told?.finish()
    }

    func send(_ chunk: MeetingAudioChunk) {
        let chunks = lock.withLock { () -> AsyncStream<MeetingAudioChunk>.Continuation? in
            nextAt = max(nextAt, chunk.at + chunk.duration)
            return self.chunks
        }
        chunks?.yield(chunk)
    }
    private var nextAt: Duration = .zero

    func tell(_ event: MeetingSourceEvent) {
        _ = lock.withLock { told }?.yield(event)
    }

    /// Until the tap has been opened once more than the last call saw, or
    /// two seconds.
    func awaitStart() async {
        for _ in 0..<200 {
            let opened = lock.withLock {
                guard _starts > startsSeen else { return false }
                startsSeen += 1
                return true
            }
            if opened { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

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

private struct DeviceGone: Error {}

/// A start that failed, and the part it failed on.
private struct CaptureFailed: CaptureFailure {
    let fault: CaptureFault
}

/// Keeps what it is fed; says nothing.
private final class FakeTranscriber: MeetingTranscriber, @unchecked Sendable {
    let lines: AsyncStream<LiveLine>
    private let lock = NSLock()
    private var _fed: [MeetingAudioChunk] = []

    init() {
        (lines, _) = AsyncStream<LiveLine>.makeStream()
    }

    var fed: [MeetingAudioChunk] {
        lock.withLock { _fed }
    }

    func begin() async throws {}
    func feed(_ chunk: MeetingAudioChunk) async {
        lock.withLock { _fed.append(chunk) }
    }
    func finish() async -> [MeetingTurn] { [] }
    func transcribe(you: [Float], them: [Float]) async throws -> [MeetingTurn] { [] }
}

/// The spool's audio file, which can be told to refuse what it is given:
/// the disk full, or the file gone from under it.
private final class FallibleWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var _fails = false
    private var _opensFail = false

    var fails: Bool {
        get { lock.withLock { _fails } }
        set { lock.withLock { _fails = newValue } }
    }

    /// While set, the audio file cannot be made at all: a full disk.
    var opensFail: Bool {
        get { lock.withLock { _opensFail } }
        set { lock.withLock { _opensFail = newValue } }
    }

    func open(_ url: URL) throws -> any MeetingAudioWriter {
        if opensFail { throw CocoaError(.fileWriteOutOfSpace) }
        return Writer(file: try SpoolAudioFile(url: url), owner: self)
    }

    private struct Writer: MeetingAudioWriter {
        let file: SpoolAudioFile
        let owner: FallibleWriter

        func append(_ chunk: MeetingAudioChunk) async throws {
            if owner.fails { throw CocoaError(.fileWriteOutOfSpace) }
            try await file.append(chunk)
        }
    }
}

/// The disk the spool is on: as much free as the test says, ten gigabytes
/// unless it says otherwise, and where it was asked about.
private final class FakeDisk: @unchecked Sendable {
    private let lock = NSLock()
    private var _free: Int64
    private var _lookedAt: [URL] = []

    init(free: Int64 = 10_000_000_000) {
        _free = free
    }

    var free: Int64 {
        get { lock.withLock { _free } }
        set { lock.withLock { _free = newValue } }
    }

    /// Each folder asked about, once over: a minute's looks are one.
    var lookedAt: [URL] {
        lock.withLock { _lookedAt }
    }

    func free(at url: URL) -> Int64? {
        lock.withLock {
            if !_lookedAt.contains(url) { _lookedAt.append(url) }
            return _free
        }
    }
}

private struct FakeDiarizer: MeetingDiarizer {
    func split(them: [Float], turns: [MeetingTurn]) async -> [MeetingTurn] { turns }
}
