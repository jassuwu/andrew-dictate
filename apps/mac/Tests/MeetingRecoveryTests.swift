import XCTest

/// Recovery, through the coordinator and its fakes: a crash costs time and
/// never the meeting. A spool the app cannot read, or cannot read a model
/// for, is kept and says so; and what was set aside can be tried again.
@MainActor
final class MeetingRecoveryTests: XCTestCase {
    private var dir: URL!
    private var source: FakeSource!
    private var transcribers: FakeTranscribers!
    private var events: [MeetingEvent] = []
    private var records: [MeetingRecord] = []
    /// Meetings a test recorded and left recording, as a crash leaves them:
    /// stopped once the test is over.
    private var recordings: [MeetingCoordinator] = []

    /// 2026-08-23 06:13:20 UTC.
    private let started = Date(timeIntervalSince1970: 1_787_000_000)

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        source = FakeSource()
        transcribers = FakeTranscribers()
        events = []
        records = []
        recordings = []
    }

    override func tearDown() async throws {
        for c in recordings {
            c.stop()
            await c.untilWrittenOut()
        }
        recordings = []
        try? FileManager.default.removeItem(at: dir)
    }

    private var docs: URL { dir.appendingPathComponent("docs") }
    private var spool: MeetingSpool { MeetingSpool(root: dir.appendingPathComponent("spool")) }

    private func coordinator(
        readSpool: @escaping @Sendable (URL) throws -> (you: [Float], them: [Float]) = {
            try SpoolAudioFile.read($0)
        }
    ) -> MeetingCoordinator {
        let c = MeetingCoordinator(
            source: FakeSource(),
            makeTranscriber: { [transcribers] model in try transcribers!.next(for: model) },
            diarizer: FakeDiarizer(),
            spool: spool,
            hookRunner: HookRunner(logURL: dir.appendingPathComponent("hooks.log")),
            readSpool: readSpool,
            preferences: { [unowned self] in
                MeetingPreferences(
                    folder: docs, hook: nil, model: .whisperLargeV3Turbo,
                    keepAudio: .deleteAtOnce)
            }
        )
        c.onEvent = { [weak self] in self?.events.append($0) }
        c.keepMeetingRecord = { [weak self] in self?.records.append($0) }
        return c
    }

    // MARK: - audio it cannot read

    /// A meeting the app cannot make sense of is still the only copy of it.
    /// It is kept where settings says it is, and the record says so — and no
    /// model is loaded for audio that will not read.
    func testAudioThatCannotBeReadIsSetAsideAndTheRecordSaysSo() async throws {
        let handle = try await orphan("teams", started: started)
        try Data("not audio".utf8).write(to: handle.audioURL)
        let c = coordinator()

        c.recoverOrphans()
        await awaitRecords(1)

        XCTAssertEqual(records.map(\.outcome), [.setAsideUnreadable])
        let record = try XCTUnwrap(records.first)
        XCTAssertTrue(record.recovered)
        XCTAssertEqual(record.app, "teams")
        XCTAssertEqual(record.startedAt, started)
        XCTAssertEqual(spool.orphans().count, 0)
        XCTAssertEqual(spool.unreadableCount(), 1)
        XCTAssertEqual(
            try Data(contentsOf: setAsideFolder(of: handle).appendingPathComponent("audio.caf")),
            Data("not audio".utf8))
        XCTAssertEqual(transcribers.made, [])
        XCTAssertEqual(MeetingTranscriptFile.listAll(in: docs).count, 0)
    }

    /// Audio that reads fine and has no frames in it is a meeting that never
    /// captured anything: there is nothing to keep, and the record says why
    /// the folder is gone.
    func testAudioThatReadsAndIsEmptyIsDiscarded() async throws {
        let handle = try spool.begin(.init(
            app: "teams", started: started, engine: "whisperLargeV3Turbo",
            model: .whisperLargeV3Turbo))
        // the file is made and closed with nothing written to it.
        do { _ = try SpoolAudioFile(url: handle.audioURL) }
        let c = coordinator()

        c.recoverOrphans()
        await awaitRecords(1)

        XCTAssertEqual(records.map(\.outcome), [.nothingKept(.spoolEmpty)])
        XCTAssertEqual(records.first?.recovered, true)
        XCTAssertEqual(records.first?.app, "teams")
        XCTAssertFalse(FileManager.default.fileExists(atPath: handle.folder.path))
        XCTAssertEqual(spool.unreadableCount(), 0)
        XCTAssertEqual(transcribers.made, [])
        XCTAssertEqual(MeetingTranscriptFile.listAll(in: docs).count, 0)
    }

    // MARK: - a model that is gone

    /// The model that recorded the meeting was removed since. Any other
    /// meeting model on this mac can read the audio, and the file says
    /// which one did, so nobody reads whisper's words as parakeet's.
    func testRecoveryUsesAnotherInstalledModelAndTheFileSaysWhichOne() async throws {
        try await orphan("teams", started: started, model: .whisperLargeV3)
        transcribers.installed = [.whisperLargeV3Turbo]
        transcribers.transcriber.batchTurns = [
            .init(speaker: .them(nil), at: .zero, text: "recovered words here")]
        let c = coordinator()

        c.recoverOrphans()
        await awaitRecords(1)

        XCTAssertEqual(transcribers.made, [.whisperLargeV3Turbo])
        let file = try XCTUnwrap(MeetingTranscriptFile.listAll(in: docs).first)
        XCTAssertTrue(file.recovered)
        XCTAssertTrue(
            try String(contentsOf: file.fileURL, encoding: .utf8)
                .contains("engine: whisperLargeV3Turbo\n"))
        XCTAssertEqual(records.map(\.outcome), [.saved])
        XCTAssertEqual(records.first?.model, "whisperLargeV3Turbo")
        XCTAssertEqual(spool.orphans().count, 0)
        XCTAssertEqual(spool.unreadableCount(), 0)
    }

    /// Whisper large before turbo before parakeet: the one that translates
    /// first, and the one that only knows english and the european
    /// languages last.
    func testTheModelsAnotherIsChosenFromAreTriedLargeThenTurboThenParakeet() async throws {
        try await orphan("teams", started: started, model: .parakeetV3)
        transcribers.installed = [.whisperLargeV3Turbo, .whisperLargeV3]
        let c = coordinator()
        c.recoverOrphans()
        await awaitRecords(1)
        XCTAssertEqual(transcribers.made, [.whisperLargeV3])

        try await orphan("meet", started: started.addingTimeInterval(60), model: .whisperLargeV3)
        transcribers.installed = [.parakeetV3, .whisperLargeV3Turbo]
        c.recoverOrphans()
        await awaitRecords(2)
        XCTAssertEqual(transcribers.made, [.whisperLargeV3, .whisperLargeV3Turbo])

        try await orphan("zoom", started: started.addingTimeInterval(120), model: .whisperLargeV3)
        transcribers.installed = [.parakeetV3]
        c.recoverOrphans()
        await awaitRecords(3)
        XCTAssertEqual(
            transcribers.made, [.whisperLargeV3, .whisperLargeV3Turbo, .parakeetV3])
        XCTAssertEqual(records.map(\.outcome), [.saved, .saved, .saved])
    }

    /// No meeting model on this mac, so nothing can read the spool and
    /// nothing is wrong with it: no attempt is counted, it is not set aside,
    /// and the lamp does not claim to be writing it out. A later launch,
    /// with a model, does.
    func testRecoveryWithNoModelInstalledLeavesTheSpoolAloneUntilALaterLaunch() async throws {
        let handle = try await orphan("teams", started: started)
        transcribers.installed = []
        transcribers.transcriber.batchTurns = [
            .init(speaker: .them(nil), at: .zero, text: "recovered words here")]
        let c = coordinator()

        c.recoverOrphans()
        await awaitRecords(1)

        XCTAssertEqual(records.map(\.outcome), [.waitingForModel])
        let record = try XCTUnwrap(records.first)
        XCTAssertTrue(record.recovered)
        XCTAssertEqual(record.app, "teams")
        XCTAssertEqual(record.startedAt, started)
        XCTAssertEqual(record.durationS, 1)
        let waiting = spool.orphans()
        XCTAssertEqual(waiting.map(\.handle), [handle])
        XCTAssertNil(waiting.first?.manifest.attempts)
        XCTAssertEqual(spool.unreadableCount(), 0)
        XCTAssertEqual(MeetingTranscriptFile.listAll(in: docs).count, 0)
        XCTAssertFalse(events.contains(.recovering(app: "teams")), "\(events)")
        XCTAssertNil(c.recovering)

        transcribers.installed = [.parakeetV3]
        c.recoverOrphans()
        await awaitRecords(2)

        XCTAssertEqual(records.map(\.outcome), [.waitingForModel, .saved])
        XCTAssertEqual(MeetingTranscriptFile.listAll(in: docs).map(\.recovered), [true])
        XCTAssertEqual(spool.orphans().count, 0)
    }

    // MARK: - trying again

    /// What history's `try again` asks of the coordinator: the recordings
    /// set aside are brought home and written out, and it comes back once
    /// they have been.
    func testTryingAgainBringsASetAsideRecordingBackAndWritesItOut() async throws {
        let handle = try await orphan("teams", started: started)
        spool.setAside(handle)
        transcribers.transcriber.batchTurns = [
            .init(speaker: .them(nil), at: .zero, text: "recovered words here")]
        let c = coordinator()

        await c.tryAgainSetAside()

        XCTAssertEqual(records.map(\.outcome), [.saved])
        XCTAssertEqual(records.first?.recovered, true)
        XCTAssertEqual(MeetingTranscriptFile.listAll(in: docs).map(\.app), ["teams"])
        XCTAssertEqual(spool.unreadableCount(), 0)
        XCTAssertEqual(spool.orphans().count, 0)
    }

    /// It was set aside on two failures and comes back with none counted.
    /// One more that fails is not a third round of launches: it goes
    /// straight back where it was, and the line that counts them still does.
    func testARecordingThatFailsAgainIsSetAsideAgain() async throws {
        let handle = try await orphan("teams", started: started)
        let tried = spool.noteAttempt(handle, manifest: .init(
            app: "teams", started: started, engine: "whisperLargeV3Turbo",
            model: .whisperLargeV3Turbo))
        spool.noteAttempt(handle, manifest: tried)
        spool.setAside(handle)
        transcribers.transcriber.batchFailure = Unreadable()
        let c = coordinator()

        await c.tryAgainSetAside()

        XCTAssertEqual(records.map(\.outcome), [.setAside])
        XCTAssertEqual(records.first?.recovered, true)
        XCTAssertEqual(spool.unreadableCount(), 1)
        XCTAssertEqual(spool.orphans().count, 0)
        XCTAssertEqual(MeetingTranscriptFile.listAll(in: docs).count, 0)
        XCTAssertEqual(
            try Data(contentsOf: setAsideFolder(of: handle).appendingPathComponent("audio.caf"))
                .isEmpty,
            false)

        // and it can be tried again, as often as someone asks.
        transcribers.transcriber.batchFailure = nil
        transcribers.transcriber.batchTurns = [
            .init(speaker: .them(nil), at: .zero, text: "recovered words here")]
        await c.tryAgainSetAside()

        XCTAssertEqual(records.map(\.outcome), [.setAside, .saved])
        XCTAssertEqual(spool.unreadableCount(), 0)
    }

    /// A try that cannot run for want of a model is not a recording that
    /// left the line: it goes back where it was, so the history row still
    /// counts it instead of it quietly waiting in a folder nobody looks in.
    func testTryingAgainWithNoModelInstalledLeavesTheRecordingSetAside() async throws {
        let handle = try await orphan("teams", started: started)
        spool.setAside(handle)
        transcribers.installed = []
        let c = coordinator()

        await c.tryAgainSetAside()

        XCTAssertEqual(records.map(\.outcome), [.waitingForModel])
        XCTAssertEqual(spool.unreadableCount(), 1)
        XCTAssertEqual(spool.orphans().count, 0)
        XCTAssertEqual(MeetingTranscriptFile.listAll(in: docs).count, 0)
    }

    /// Only the recordings that were set aside are tried: a spool that
    /// failed once at this launch has the one try it has left for the next,
    /// and asking for the others again is not a way to spend it.
    func testTryingAgainLeavesOtherOrphansAlone() async throws {
        let waiting = try await orphan("meet", started: started)
        spool.noteAttempt(waiting, manifest: .init(
            app: "meet", started: started, engine: "whisperLargeV3Turbo",
            model: .whisperLargeV3Turbo))
        let aside = try await orphan("teams", started: started.addingTimeInterval(60))
        spool.setAside(aside)
        let c = coordinator()

        await c.tryAgainSetAside()

        XCTAssertEqual(MeetingTranscriptFile.listAll(in: docs).map(\.app), ["teams"])
        XCTAssertEqual(transcribers.made.count, 1)
        XCTAssertEqual(spool.orphans().map(\.handle), [waiting])
        XCTAssertEqual(spool.orphans().first?.manifest.attempts, 1)
    }

    /// A folder whose manifest was lost gets a minimal one when it is
    /// brought back, and is written out as the unnamed meeting it can be
    /// said to be: the audio's own date, the model the app would pick now.
    func testARecordingWithNoManifestIsTriedAsAMeetingStartedWhenItsAudioWasMade() async throws {
        let handle = try await orphan("teams", started: started)
        let madeAt = Date(timeIntervalSince1970: 1_787_100_000)
        try FileManager.default.setAttributes(
            [.creationDate: madeAt], ofItemAtPath: handle.audioURL.path)
        try FileManager.default.removeItem(at: handle.manifestURL)
        XCTAssertEqual(spool.orphans().count, 0)
        XCTAssertEqual(spool.unreadableCount(), 1)
        let c = coordinator()

        await c.tryAgainSetAside()

        let file = try XCTUnwrap(MeetingTranscriptFile.listAll(in: docs).first)
        XCTAssertEqual(file.app, "meeting")
        XCTAssertEqual(file.started, madeAt)
        XCTAssertTrue(file.recovered)
        XCTAssertTrue(
            try String(contentsOf: file.fileURL, encoding: .utf8)
                .contains("engine: whisperLargeV3\n"))
        XCTAssertEqual(spool.unreadableCount(), 0)
    }

    /// One meeting model at a time, whoever asked: a try again while launch
    /// recovery is still reading waits for it, and neither is lost.
    func testTryingAgainWhileRecoveryIsRunningWaitsForItsTurn() async throws {
        try await orphan("teams", started: started)
        let aside = try await orphan("meet", started: started.addingTimeInterval(60))
        spool.setAside(aside)
        transcribers.transcriber.holds = true
        let c = coordinator()

        c.recoverOrphans()
        await held(transcribers.transcriber)
        let again = Task { await c.tryAgainSetAside() }
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(transcribers.made.count, 1, "the second round has no model loaded yet")
        XCTAssertEqual(MeetingTranscriptFile.listAll(in: docs).count, 0)

        transcribers.transcriber.release()
        await again.value
        await awaitRecords(2)

        XCTAssertEqual(MeetingTranscriptFile.listAll(in: docs).map(\.app).sorted(), ["meet", "teams"])
        XCTAssertEqual(records.map(\.outcome), [.saved, .saved])
    }

    // MARK: - the main actor

    /// Three hours of spool is gigabytes and seconds of reading, five
    /// seconds after launch: none of it on the main actor, where the menu
    /// and the lamp would stand still for it.
    func testRecoveryReadsTheSpoolOffTheMainActor() async throws {
        try await orphan("teams", started: started)
        let reads = Reads()
        let c = coordinator(readSpool: { url in
            reads.note(onTheMainThread: Thread.isMainThread)
            return try SpoolAudioFile.read(url)
        })

        c.recoverOrphans()
        await awaitRecords(1)

        XCTAssertEqual(records.map(\.outcome), [.saved])
        XCTAssertEqual(reads.onTheMainThread, [false])
    }

    // MARK: - a meeting with a gap in it

    /// The lid shut ten seconds in and opened ten minutes later, and the
    /// app died four seconds after that: its spool holds fourteen seconds of
    /// a meeting six hundred and four long. The manifest noted the gap as it
    /// began and ended, so the recovered file has it, is not whole, runs as
    /// long as the meeting did, and stamps what was said after the lid where
    /// it was said.
    func testAMeetingRecoveredAfterAGapKeepsItsGapItsLengthAndItsTimes() async throws {
        let clock = FakeClock()
        let live = recording(clock: clock)
        live.start()
        await source.awaitStart()
        await send(0..<10, to: live)
        clock.advance(by: .seconds(600))
        live.probeTapIsAlive()
        await send(600..<604, to: live)
        try theAppDies(recording: live)

        transcribers.transcriber.batchTurns = [
            .init(speaker: .you, at: .seconds(2), text: "before the lid"),
            .init(speaker: .them(nil), at: .seconds(12.5), text: "after the lid"),
        ]
        let c = coordinator()
        c.recoverOrphans()
        await awaitRecords(1)

        let file = try XCTUnwrap(MeetingTranscriptFile.listAll(in: docs).first)
        XCTAssertTrue(file.recovered)
        XCTAssertFalse(file.complete)
        XCTAssertEqual(file.gapCount, 1)
        XCTAssertEqual(file.duration, .seconds(604))
        let body = try String(contentsOf: file.fileURL, encoding: .utf8)
        XCTAssertTrue(body.contains("- [10.0, 601.0]"), body)
        XCTAssertEqual(turns(in: body), [
            "[00:00:02] you: before the lid",
            "[00:10:02] them: after the lid",
        ])
        XCTAssertEqual(records.map(\.outcome), [.saved])
        XCTAssertEqual(records.first?.gaps, 1)
        XCTAssertEqual(records.first?.durationS, 604)
    }

    /// The app died while the lid was still being woken from: the gap was
    /// open, and the spool holds the ten seconds before it. It runs to the
    /// last the meeting was known to have run.
    func testAMeetingThatDiedInAGapIsRecoveredWithTheGapRunningToTheEnd() async throws {
        let clock = FakeClock()
        let live = recording(clock: clock)
        live.start()
        await source.awaitStart()
        await send(0..<10, to: live)
        clock.advance(by: .seconds(600))
        live.probeTapIsAlive()
        try theAppDies(recording: live)

        let c = coordinator()
        c.recoverOrphans()
        await awaitRecords(1)

        let file = try XCTUnwrap(MeetingTranscriptFile.listAll(in: docs).first)
        XCTAssertFalse(file.complete)
        XCTAssertEqual(file.duration, .seconds(600))
        let body = try String(contentsOf: file.fileURL, encoding: .utf8)
        XCTAssertTrue(body.contains("- [10.0, 600.0]"), body)
    }

    /// Stopped with the call still unheard, and quit: the quit's ceiling
    /// cut the write-out short. The stop had already noted where the gap
    /// and the meeting ended, so the recovery says the same as the file
    /// would have.
    func testAStopWhoseFileWasNeverWrittenIsRecoveredAsItStopped() async throws {
        let clock = FakeClock()
        let live = recording(clock: clock)
        live.start()
        await source.awaitStart()
        await send(0..<10, to: live)
        clock.advance(by: .seconds(600))
        live.probeTapIsAlive()
        clock.advance(by: .seconds(30))
        live.stop()
        try theAppDies(recording: live)

        let c = coordinator()
        c.recoverOrphans()
        await awaitRecords(1)

        let file = try XCTUnwrap(MeetingTranscriptFile.listAll(in: docs).first)
        XCTAssertFalse(file.complete)
        XCTAssertEqual(file.duration, .seconds(630))
        let body = try String(contentsOf: file.fileURL, encoding: .utf8)
        XCTAssertTrue(body.contains("- [10.0, 630.0]"), body)
    }

    // MARK: - helpers

    /// A coordinator recording a meeting, on a wall the test moves, with a
    /// spool of its own: what it leaves is copied where the coordinator
    /// under test looks, as a crash would leave it.
    private func recording(clock: FakeClock) -> MeetingCoordinator {
        let liveDocs = dir.appendingPathComponent("live-docs")
        let c = MeetingCoordinator(
            source: source,
            makeTranscriber: { _ in FakeTranscriber() },
            diarizer: FakeDiarizer(),
            spool: liveSpool,
            hookRunner: HookRunner(logURL: dir.appendingPathComponent("hooks.log")),
            now: { clock.now },
            preferences: {
                MeetingPreferences(
                    folder: liveDocs, hook: nil, model: .whisperLargeV3Turbo,
                    keepAudio: .deleteAtOnce)
            }
        )
        recordings.append(c)
        return c
    }

    private var liveSpool: MeetingSpool {
        MeetingSpool(root: dir.appendingPathComponent("live-spool"))
    }

    /// The spool of the meeting `live` is recording, as it stands now, left
    /// where launch looks — and nothing more of that meeting.
    private func theAppDies(recording live: MeetingCoordinator) throws {
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: liveSpool.root.path)
            .filter { !$0.hasPrefix(".") }
        XCTAssertEqual(names.count, 1)
        try fm.createDirectory(at: spool.root, withIntermediateDirectories: true)
        for name in names {
            try fm.copyItem(
                at: liveSpool.root.appendingPathComponent(name),
                to: spool.root.appendingPathComponent(name))
        }
    }

    /// A second of both sides talking for each of `seconds`, taken in: the
    /// meeting's clock is past the last, and a moment more for it to reach
    /// the spool, so the wall moved next does not move under it.
    private func send(_ seconds: Range<Int>, to c: MeetingCoordinator) async {
        for s in seconds {
            source.send(loud(at: .seconds(s)))
        }
        let end = Duration.seconds(seconds.upperBound)
        for _ in 0..<200 where c.elapsed < end {
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: .milliseconds(50))
    }

    /// The turns of a transcript's body, as it has them.
    private func turns(in body: String) -> [String] {
        body.split(separator: "\n").map(String.init).filter { $0.hasPrefix("[0") }
    }

    /// A spool a crash left behind, with a second of audio on it.
    @discardableResult
    private func orphan(
        _ app: String, started: Date, model: MeetingModel = .whisperLargeV3Turbo
    ) async throws -> MeetingSpool.Handle {
        let handle = try spool.begin(.init(
            app: app, started: started, engine: model.rawValue, model: model))
        let file = try SpoolAudioFile(url: handle.audioURL)
        try await file.append(loud(at: .zero))
        return handle
    }

    private func setAsideFolder(of handle: MeetingSpool.Handle) -> URL {
        spool.unreadableFolder.appendingPathComponent(handle.folder.lastPathComponent)
    }

    private func loud(at: Duration) -> MeetingAudioChunk {
        let n = 16_000
        return .init(you: Array(repeating: 0.05, count: n),
                     them: (0..<n).map { sin(Float($0) * 0.05) * 0.3 }, at: at)
    }

    /// Until the transcriber is parked in its hold, or two seconds, so a
    /// test against code that never gets there fails instead of hanging.
    private func held(_ transcriber: FakeTranscriber) async {
        for _ in 0..<200 where !transcriber.isWaiting {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Until `count` records have arrived, or two seconds, so an ending that
    /// never leaves one fails the test instead of hanging it.
    private func awaitRecords(_ count: Int) async {
        for _ in 0..<200 where records.count < count {
            try? await Task.sleep(for: .milliseconds(10))
        }
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

/// The tap. Recovery never opens it; a meeting recorded to leave a spool
/// behind is handed what the test sends.
private final class FakeSource: MeetingAudioSource, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<MeetingAudioChunk>.Continuation?
    private var starts = 0

    func start() async throws -> AsyncStream<MeetingAudioChunk> {
        let (stream, continuation) = AsyncStream<MeetingAudioChunk>.makeStream()
        lock.withLock {
            self.continuation = continuation
            starts += 1
        }
        return stream
    }

    func rebuild() async throws {}

    func stop() async {
        lock.withLock { () -> AsyncStream<MeetingAudioChunk>.Continuation? in
            defer { continuation = nil }
            return continuation
        }?.finish()
    }

    func send(_ chunk: MeetingAudioChunk) {
        _ = lock.withLock { continuation }?.yield(chunk)
    }

    /// Until the tap has been opened, or two seconds.
    func awaitStart() async {
        for _ in 0..<200 {
            if lock.withLock({ starts > 0 }) { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private struct Unreadable: Error {}

/// Where each read of a spool ran.
private final class Reads: @unchecked Sendable {
    private let lock = NSLock()
    private var _onTheMainThread: [Bool] = []

    var onTheMainThread: [Bool] {
        lock.withLock { _onTheMainThread }
    }

    func note(onTheMainThread: Bool) {
        lock.withLock { _onTheMainThread.append(onTheMainThread) }
    }
}

/// One per reading, the way the app builds them, for the models that are on
/// this mac: asking for one that is not throws what the app's own does.
private final class FakeTranscribers: @unchecked Sendable {
    private let lock = NSLock()
    private var _installed = Set(MeetingModel.allCases)
    private var _made: [MeetingModel] = []
    /// the one every transcriber made is.
    let transcriber = FakeTranscriber()

    /// The models that are on this mac, from now on.
    var installed: Set<MeetingModel> {
        get { lock.withLock { _installed } }
        set { lock.withLock { _installed = newValue } }
    }

    /// The model each transcriber that was made was made for, in order.
    var made: [MeetingModel] {
        lock.withLock { _made }
    }

    func next(for model: MeetingModel) throws -> FakeTranscriber {
        try lock.withLock {
            guard _installed.contains(model) else {
                throw MeetingModel.NotInstalled(model: model)
            }
            _made.append(model)
            return transcriber
        }
    }
}

/// While `holds` is set, `transcribe` waits for the test to `release()` it —
/// a recovery still running.
private final class FakeTranscriber: MeetingTranscriber, @unchecked Sendable {
    var batchTurns: [MeetingTurn] = []
    /// what a spool the engine cannot read does at every launch.
    var batchFailure: (any Error)?
    /// what it says its decoding came to. nil keeps no count.
    var tally: StretchTally?
    let lines: AsyncStream<LiveLine>
    private let lock = NSLock()
    private var _holds = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init() {
        (lines, _) = AsyncStream<LiveLine>.makeStream()
    }

    var holds: Bool {
        get { lock.withLock { _holds } }
        set { lock.withLock { _holds = newValue } }
    }

    var isWaiting: Bool {
        lock.withLock { !waiting.isEmpty }
    }

    func begin() async throws {}
    func feed(_ chunk: MeetingAudioChunk) async {}
    func finish() async -> [MeetingTurn] { [] }
    func decodeTally() async -> StretchTally? { tally }
    func transcribe(you: [Float], them: [Float]) async throws -> [MeetingTurn] {
        await heldUntilReleased()
        if let batchFailure { throw batchFailure }
        return batchTurns
    }

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
    func split(them: [Float], turns: [MeetingTurn]) async -> [MeetingTurn] { turns }
}
