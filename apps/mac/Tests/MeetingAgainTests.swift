import XCTest

/// A meeting's transcript made again from its kept audio, with a model you
/// pick: through the coordinator and its fakes. The meeting is already on
/// disk, as a file and as audio; what a person or an agent would notice is
/// judged — the file at the same path, the lamp, the hook, the record, the
/// label on the audio.
@MainActor
final class MeetingAgainTests: XCTestCase {
    private var dir: URL!
    private var source: FakeSource!
    private var transcribers: FakeTranscribers!
    private var wall: FakeWall!
    private var clock: FakeClock!
    private var events: [MeetingEvent] = []
    private var records: [MeetingRecord] = []
    private var hook: URL?
    private var keepAudio: KeepMeetingAudio = .oneDay

    /// 2026-08-17 20:53:20 UTC: when the meeting started.
    private let started = Date(timeIntervalSince1970: 1_787_000_000)
    /// 2026-09-21 14:13:20 UTC: the day it is made again, a month on.
    private let rerunAt = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-again-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        source = FakeSource()
        transcribers = FakeTranscribers()
        wall = FakeWall(rerunAt)
        clock = FakeClock()
        events = []
        records = []
        hook = nil
        keepAudio = .oneDay
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var docs: URL { dir.appendingPathComponent("docs") }
    private var spool: MeetingSpool { MeetingSpool(root: dir.appendingPathComponent("spool")) }
    private var kept: KeptAudio {
        KeptAudio(root: dir.appendingPathComponent("meeting-audio"), now: { [wall] in wall!.now })
    }

    private func coordinator() -> MeetingCoordinator {
        let clock = clock!
        let c = MeetingCoordinator(
            source: source,
            makeTranscriber: { [transcribers] model in try transcribers!.next(for: model) },
            diarizer: FakeDiarizer(),
            spool: spool,
            hookRunner: HookRunner(logURL: dir.appendingPathComponent("hooks.log")),
            keptAudio: kept,
            thresholds: .init(
                probeTimeout: .seconds(1), silenceTimeout: .seconds(600),
                silenceFloor: 0.001, quietNudgeAfter: .seconds(3_600)),
            now: { clock.now },
            preferences: { [unowned self] in
                MeetingPreferences(
                    folder: docs, hook: hook, model: .parakeetV3, keepAudio: keepAudio)
            }
        )
        c.onEvent = { [weak self] in self?.events.append($0) }
        c.keepMeetingRecord = { [weak self] in self?.records.append($0) }
        return c
    }

    // MARK: - the file

    /// The file is replaced where it is: the body, the engine, who spoke
    /// and how many words are the new reading's, and what the meeting was —
    /// when it began, how long, where audio was lost, whether it was
    /// recovered — is what the file already said.
    func testTheFileIsReplacedAtTheSamePathWithTheNewReading() async throws {
        let gap = MeetingSession.Gap(began: .seconds(5), ended: .seconds(8))
        let file = try await existingMeeting(gaps: [gap], recovered: true)
        let before = try frontMatter(of: file)
        let again = FakeTranscriber()
        again.batchTurns = [
            .init(speaker: .you, at: .seconds(1), text: "namaste"),
            .init(speaker: .them(nil), at: .seconds(2), text: "kaise ho aap theek"),
        ]
        again.tally = passing
        transcribers.lineUp(again)

        await coordinator().transcribeAgain(file, with: .whisperLargeV3)

        XCTAssertEqual(MeetingTranscriptFile.listAll(in: docs).map(\.fileURL), [file])
        let after = try frontMatter(of: file)
        XCTAssertEqual(after["engine"], "whisperLargeV3")
        XCTAssertEqual(after["speakers"], "[you, them 1]")
        XCTAssertEqual(after["words"], "5")
        for key in ["app", "started", "ended", "duration_s", "gaps", "recovered"] {
            XCTAssertEqual(after[key], before[key], key)
        }
        XCTAssertEqual(try lines(of: file), [
            "[00:00:01] you: namaste",
            "[00:00:02] them 1: kaise ho aap theek",
        ])
        XCTAssertEqual(transcribers.made, [.whisperLargeV3])
    }

    // MARK: - the record

    /// One record per rerun, marked as one: the model it read with, how the
    /// check came out and on what numbers, the turns and words of each side,
    /// and how long it took, from asking to the file being replaced.
    func testARerunLeavesOneRecordMarkedAsOne() async throws {
        let gap = MeetingSession.Gap(began: .seconds(5), ended: .seconds(8))
        let file = try await existingMeeting(gaps: [gap], recovered: true, audioUntil: nil)
        let again = FakeTranscriber()
        again.batchTurns = [
            .init(speaker: .you, at: .seconds(1), text: "namaste"),
            .init(speaker: .them(nil), at: .seconds(2), text: "kaise ho aap theek"),
            .init(speaker: .them(nil), at: .seconds(60), text: "dhanyavaad"),
        ]
        again.tally = passing
        again.onTranscribe = { [clock] in clock!.advance(by: .seconds(83)) }
        transcribers.lineUp(again)

        await coordinator().transcribeAgain(file, with: .whisperLargeV3)

        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertTrue(record.again)
        XCTAssertEqual(record.outcome, .saved)
        XCTAssertEqual(record.app, "zoom")
        XCTAssertEqual(record.model, "whisperLargeV3")
        XCTAssertEqual(record.startedAt, started)
        XCTAssertEqual(record.durationS, 6_120)
        XCTAssertEqual(record.gaps, 1)
        XCTAssertEqual(record.gapsLostS, 3)
        XCTAssertTrue(record.recovered)
        XCTAssertEqual(record.you, .init(turns: 1, words: 1))
        XCTAssertEqual(record.them, .init(turns: 2, words: 5))
        XCTAssertEqual(record.toDiskS, 83)
        XCTAssertEqual(record.coverage, .init(
            result: .pass, speechYouS: 1, speechThemS: 1, unreadYouS: 0, unreadThemS: 0,
            bleed: 0, farSideLoudS: 2))
        XCTAssertEqual(record.audioKept, true)
        XCTAssertEqual(record.audioKeptUntil, Date(timeIntervalSince1970: 1_790_086_400))
    }

    // MARK: - the lamp

    /// It says it started, and that it finished, in the words a save uses.
    func testTheLampSaysItStartedAndThatItFinished() async throws {
        let file = try await existingMeeting()
        let again = FakeTranscriber()
        again.batchTurns = [.init(speaker: .you, at: .seconds(1), text: "namaste")]
        again.tally = passing
        transcribers.lineUp(again)

        await coordinator().transcribeAgain(file, with: .whisperLargeV3)

        let summary = MeetingSummary(
            fileURL: file, app: "zoom", started: started, duration: .seconds(6_120),
            complete: true, gapCount: 0, recovered: false)
        XCTAssertEqual(events, [
            .transcribingAgain(.whisperLargeV3),
            .transcribedAgain(summary, .whisperLargeV3),
        ])
        XCTAssertEqual(events.map(\.hudText), [
            "transcribing again with whisper large…",
            "transcribed again · whisper large",
        ])
    }

    /// Done is not always whole, and the lamp never says it was, in the
    /// two ways a save already tells it.
    func testTheLampDoesNotCallAnIncompleteOneWhole() {
        func said(complete: Bool, gaps: Int) -> String? {
            MeetingEvent.transcribedAgain(
                MeetingSummary(
                    fileURL: URL(fileURLWithPath: "/tmp/a.md"), app: "zoom", started: .now,
                    duration: .seconds(60), complete: complete, gapCount: gaps, recovered: false),
                .whisperLargeV3Turbo
            ).hudText
        }

        XCTAssertEqual(
            said(complete: false, gaps: 0), "transcribed again · whisper turbo · incomplete, audio kept")
        XCTAssertEqual(said(complete: false, gaps: 1), "transcribed again · whisper turbo · 1 gap")
        XCTAssertEqual(said(complete: false, gaps: 2), "transcribed again · whisper turbo · 2 gaps")
    }

    // MARK: - the audio after it

    /// A meeting whose audio was kept until you deleted it because its
    /// transcript was thin, and whose new reading covers what was said, is
    /// an ordinary meeting now: the file is whole, and the audio goes the
    /// way the setting says, a day from now and not from a month ago.
    func testAThinMeetingWhoseRerunPassesBecomesWholeAndItsAudioGetsADate() async throws {
        let file = try await existingMeeting(thin: true, audioUntil: nil)
        XCTAssertEqual(try frontMatter(of: file)["complete"], "false")
        let again = FakeTranscriber()
        again.batchTurns = [
            .init(speaker: .you, at: .seconds(1), text: "the deploy is blocked"),
            .init(speaker: .them(nil), at: .seconds(2), text: "since when"),
        ]
        again.tally = passing
        transcribers.lineUp(again)

        await coordinator().transcribeAgain(file, with: .whisperLargeV3)

        let after = try frontMatter(of: file)
        XCTAssertEqual(after["complete"], "true")
        XCTAssertNil(after["reason"])
        let entry = try XCTUnwrap(kept.entry(for: file), "the audio is never deleted by a rerun")
        XCTAssertEqual(entry.label.until, Date(timeIntervalSince1970: 1_790_086_400))
        XCTAssertEqual(entry.label.model, .whisperLargeV3)
        XCTAssertEqual(entry.label.started, started)
    }

    /// Still far fewer words than the talk: the file is the new reading's
    /// and says it is not whole and why, as a first save would, and the
    /// audio stays until you delete it.
    func testAThinMeetingWhoseRerunIsStillThinStaysIncompleteAndItsAudioStaysKept() async throws {
        let file = try await existingMeeting(thin: true, audioUntil: nil)
        let again = FakeTranscriber()
        again.batchTurns = [.init(speaker: .them(nil), at: .seconds(1), text: "since when exactly")]
        again.tally = StretchTally(
            decodedThem: 900, speechThem: .seconds(3_600), readThem: .seconds(3_600))
        transcribers.lineUp(again)

        await coordinator().transcribeAgain(file, with: .whisperLargeV3)

        let after = try frontMatter(of: file)
        XCTAssertEqual(after["complete"], "false")
        XCTAssertEqual(after["reason"], "far fewer words than the talk that was heard")
        XCTAssertEqual(after["engine"], "whisperLargeV3")
        XCTAssertEqual(try lines(of: file), ["[00:00:01] them 1: since when exactly"])
        let entry = try XCTUnwrap(kept.entry(for: file))
        XCTAssertNil(entry.label.until, "kept until you delete it")
    }

    /// Audio that already has a date keeps it: made again is not a reason
    /// to keep someone's voice longer. The label says the new model.
    func testTheAudioOfAMeetingThatWasNotThinKeepsItsDate() async throws {
        let until = Date(timeIntervalSince1970: 1_790_050_000)
        let file = try await existingMeeting(audioUntil: until)
        let again = FakeTranscriber()
        again.batchTurns = [.init(speaker: .you, at: .seconds(1), text: "namaste")]
        again.tally = passing
        transcribers.lineUp(again)

        await coordinator().transcribeAgain(file, with: .whisperLargeV3)

        let entry = try XCTUnwrap(kept.entry(for: file))
        XCTAssertEqual(entry.label.until, until)
        XCTAssertEqual(entry.label.model, .whisperLargeV3)
    }

    /// With the setting at delete at once, a thin meeting that is whole now
    /// is due now. The rerun does not delete it — the next sweep does, as it
    /// would have for any meeting whose day came.
    func testAThinMeetingWhoseRerunPassesIsDueAtOnceWhenTheSettingSaysDeleteAtOnce() async throws {
        keepAudio = .deleteAtOnce
        let file = try await existingMeeting(thin: true, audioUntil: nil)
        let again = FakeTranscriber()
        again.batchTurns = [.init(speaker: .you, at: .seconds(1), text: "namaste")]
        again.tally = passing
        transcribers.lineUp(again)

        await coordinator().transcribeAgain(file, with: .whisperLargeV3)

        let entry = try XCTUnwrap(kept.entry(for: file), "not deleted by the rerun")
        XCTAssertEqual(entry.label.until, rerunAt)
    }

    /// A whole transcript is not swapped for a hollow one because you tried
    /// another model on it. It stays as it was, and the lamp says why; the
    /// audio is there to try a third.
    func testAReadingThatIsThinDoesNotReplaceAWholeTranscript() async throws {
        let until = Date(timeIntervalSince1970: 1_790_050_000)
        let file = try await existingMeeting(audioUntil: until)
        let before = try Data(contentsOf: file)
        let again = FakeTranscriber()
        again.batchTurns = [.init(speaker: .them(nil), at: .seconds(1), text: "hmm right")]
        again.tally = StretchTally(
            decodedThem: 900, speechThem: .seconds(3_600), readThem: .seconds(3_600))
        transcribers.lineUp(again)

        await coordinator().transcribeAgain(file, with: .whisperLargeV3Turbo)

        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(events, [
            .transcribingAgain(.whisperLargeV3Turbo),
            .couldNotTranscribeAgain(
                "whisper turbo read it thin: far fewer words than the talk that was heard"),
        ])
        let entry = try XCTUnwrap(kept.entry(for: file))
        XCTAssertEqual(entry.label.until, until)
        XCTAssertEqual(entry.label.model, .parakeetV3, "the label still says what wrote the file")
    }

    // MARK: - when it fails

    /// The model threw. The file is exactly the bytes it was, the lamp says
    /// it could not and that nothing changed, the audio is still there for
    /// another try, and a hook has nothing to be told.
    func testAModelThatThrowsLeavesTheFileExactlyAsItWasAndSaysSo() async throws {
        hook = try script("#!/bin/sh\ntouch \"$ANDREW_FOLDER/hook-ran\"\nexit 0\n")
        let file = try await existingMeeting(thin: true)
        let before = try Data(contentsOf: file)
        let again = FakeTranscriber()
        again.batchFailure = FellOver()
        transcribers.lineUp(again)

        await coordinator().transcribeAgain(file, with: .whisperLargeV3)

        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(events, [
            .transcribingAgain(.whisperLargeV3),
            .couldNotTranscribeAgain("the model fell over"),
        ])
        XCTAssertEqual(
            events.last?.hudText,
            "couldn't transcribe again — the model fell over. the transcript is as it was")
        XCTAssertNotNil(kept.entry(for: file), "the audio is still there")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: file.deletingLastPathComponent().appendingPathComponent("hook-ran").path))
    }

    // MARK: - the hook

    /// The hook runs again for the new file, so an agent's copy of the old
    /// one does not go stale: the same event and the same facts of the
    /// meeting, and one key more that says this is not the first time.
    func testTheHookRunsAgainForTheNewFileAndSaysItIsARerun() async throws {
        hook = try script("""
            #!/bin/sh
            cat > "$ANDREW_FOLDER/seen.json"
            echo "$ANDREW_AGAIN" > "$ANDREW_FOLDER/again.txt"
            exit 0
            """)
        let gap = MeetingSession.Gap(began: .seconds(5), ended: .seconds(8))
        let file = try await existingMeeting(gaps: [gap], recovered: true)
        let again = FakeTranscriber()
        again.batchTurns = [.init(speaker: .you, at: .seconds(1), text: "namaste")]
        again.tally = passing
        transcribers.lineUp(again)

        await coordinator().transcribeAgain(file, with: .whisperLargeV3)

        let told = try await toldTheHook(beside: file)
        XCTAssertEqual(told.payload["again"] as? Bool, true)
        XCTAssertEqual(told.again, "1")
        XCTAssertEqual(told.payload["event"] as? String, "meeting-saved")
        XCTAssertEqual(told.payload["transcript"] as? String, file.path)
        XCTAssertEqual(told.payload["app"] as? String, "zoom")
        XCTAssertEqual(told.payload["started_at"] as? String, "2026-08-17T20:53:20Z")
        XCTAssertEqual(told.payload["duration_s"] as? Int, 6_120)
        XCTAssertEqual(told.payload["complete"] as? Bool, false, "the gap is still in it")
        XCTAssertEqual(told.payload["gaps"] as? [[Double]], [[5, 8]])
        XCTAssertEqual(told.payload["recovered"] as? Bool, true)
    }

    /// A meeting that has just ended is not a rerun, and its hook says so
    /// with the same key, so a script never has to wonder what a missing one
    /// means.
    func testTheHookOfAFirstSaveSaysItIsNotARerun() async throws {
        hook = try script("""
            #!/bin/sh
            cat > "$ANDREW_FOLDER/seen.json"
            echo "$ANDREW_AGAIN" > "$ANDREW_FOLDER/again.txt"
            exit 0
            """)
        let live = FakeTranscriber()
        live.finalTurns = [.init(speaker: .you, at: .seconds(1), text: "the deploy is blocked")]
        live.tally = passing
        transcribers.lineUp(live)

        try await meeting(seconds: 2)

        let file = try XCTUnwrap(MeetingTranscriptFile.listAll(in: docs).first).fileURL
        let told = try await toldTheHook(beside: file)
        XCTAssertEqual(told.payload["again"] as? Bool, false)
        XCTAssertEqual(told.again, "0")
    }

    // MARK: - helpers

    /// A meeting `seconds` long, loud on both sides, stopped and written out.
    private func meeting(seconds: Int) async throws {
        let c = coordinator()
        c.start()
        await source.awaitStart()
        for s in 0..<seconds {
            source.send(loud(at: .seconds(s)))
        }
        await waitFor { c.elapsed >= .seconds(seconds) }
        c.stop()
        await c.untilWrittenOut()
    }

    /// What the hook was handed, as a hook that saves it beside the
    /// transcript left it. It runs after the file is written, so this waits.
    private func toldTheHook(
        beside file: URL
    ) async throws -> (payload: [String: Any], again: String) {
        let folder = file.deletingLastPathComponent()
        let seen = folder.appendingPathComponent("seen.json")
        let flag = folder.appendingPathComponent("again.txt")
        // `cat >` makes the file before it has written to it.
        await waitFor {
            (try? JSONSerialization.jsonObject(with: Data(contentsOf: seen))) != nil
                && ((try? String(contentsOf: flag, encoding: .utf8)) ?? "").hasSuffix("\n")
        }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: seen))
        return (
            try XCTUnwrap(object as? [String: Any]),
            try String(contentsOf: flag, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func script(_ text: String) throws -> URL {
        let url = dir.appendingPathComponent("hook.sh")
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// The tally of a reading that covers what was said.
    private var passing: StretchTally {
        StretchTally(
            decodedYou: 1, decodedThem: 1,
            speechYou: .seconds(1), speechThem: .seconds(1),
            readYou: .seconds(1), readThem: .seconds(1))
    }

    /// A meeting written out a month ago by parakeet, and its audio kept:
    /// the file as `write` leaves it, the audio compressed beside its label.
    @discardableResult
    private func existingMeeting(
        gaps: [MeetingSession.Gap] = [],
        recovered: Bool = false,
        thin: Bool = false,
        audioUntil: Date? = nil
    ) async throws -> URL {
        let url = try MeetingTranscriptFile.write(
            MeetingTranscript(
                app: "zoom", started: started, duration: .seconds(6_120), engine: "parakeetV3",
                gaps: gaps, recovered: recovered,
                reason: thin ? "far fewer words than the talk that was heard" : nil,
                turns: [
                    .init(speaker: .you, at: .seconds(4), text: "hello there"),
                    .init(speaker: .them(nil), at: .seconds(9), text: "hmm right"),
                ]),
            in: docs)
        let handle = try spool.begin(.init(
            app: "zoom", started: started, engine: "parakeetV3", model: .parakeetV3))
        let file = try SpoolAudioFile(url: handle.audioURL)
        for s in 0..<2 {
            try await file.append(loud(at: .seconds(s)))
        }
        XCTAssertTrue(kept.keep(handle, label: .init(
            transcript: url, started: started, model: .parakeetV3, until: audioUntil)))
        return url
    }

    /// The turn lines of a saved transcript.
    private func lines(of file: URL) throws -> [String] {
        let body = try String(contentsOf: file, encoding: .utf8)
        return body.split(separator: "\n").filter { $0.hasPrefix("[") }.map(String.init)
    }

    /// Its front matter, key to value as written; a list is its lines
    /// joined.
    private func frontMatter(of file: URL) throws -> [String: String] {
        let body = try String(contentsOf: file, encoding: .utf8)
        var fields: [String: String] = [:]
        var key: String?
        for line in body.split(separator: "\n").dropFirst() {
            if line == "---" { break }
            if line.hasPrefix("- "), let key {
                fields[key, default: ""] += "|" + line
            } else if let colon = line.firstIndex(of: ":") {
                key = String(line[..<colon])
                fields[key!] = line[line.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return fields
    }

    private func loud(at: Duration) -> MeetingAudioChunk {
        let n = 16_000
        return .init(you: Array(repeating: 0.05, count: n),
                     them: (0..<n).map { sin(Float($0) * 0.05) * 0.3 }, at: at)
    }

    private func waitFor(_ seconds: Double = 5, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

// MARK: - fakes

private struct FellOver: LocalizedError {
    var errorDescription: String? { "the model fell over" }
}

/// A wall the test holds still: what kept audio's dates are read against.
private final class FakeWall: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) {
        self.date = date
    }

    var now: Date {
        lock.withLock { date }
    }
}

/// The coordinator's own clock, held still until a test moves it.
private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private let base = ContinuousClock.now
    private var offset = Duration.zero

    var now: ContinuousClock.Instant {
        lock.withLock { base.advanced(by: offset) }
    }

    func advance(by duration: Duration) {
        lock.withLock { offset += duration }
    }
}

private final class FakeSource: MeetingAudioSource, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<MeetingAudioChunk>.Continuation?
    private var starts = 0
    private var startsSeen = 0

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

/// One per reading, the way the app builds them. Past the ones lined up,
/// each is a transcriber that hears nothing.
private final class FakeTranscribers: @unchecked Sendable {
    private let lock = NSLock()
    private var lined: [FakeTranscriber] = []
    private var models: [MeetingModel] = []

    func lineUp(_ transcribers: FakeTranscriber...) {
        lock.withLock { lined.append(contentsOf: transcribers) }
    }

    /// The model each one was made for, in order.
    var made: [MeetingModel] {
        lock.withLock { models }
    }

    func next(for model: MeetingModel) throws -> FakeTranscriber {
        lock.withLock {
            models.append(model)
            return lined.isEmpty ? FakeTranscriber() : lined.removeFirst()
        }
    }
}

private final class FakeTranscriber: MeetingTranscriber, @unchecked Sendable {
    private let lock = NSLock()
    private var _heard: [Int] = []
    var finalTurns: [MeetingTurn] = []
    var batchTurns: [MeetingTurn] = []
    var batchFailure: (any Error)?
    /// What it says its decoding came to when it read the audio whole. nil
    /// keeps no count.
    var tally: StretchTally?
    /// Runs when it is asked to read the audio whole, before it answers.
    var onTranscribe: (@Sendable () -> Void)?
    let lines: AsyncStream<LiveLine>

    init() {
        (lines, _) = AsyncStream<LiveLine>.makeStream()
    }

    /// The samples of each side it was handed to read whole, when it was.
    var heard: [Int] {
        lock.withLock { _heard }
    }

    func begin() async throws {}
    func feed(_ chunk: MeetingAudioChunk) async {}
    func finish() async -> [MeetingTurn] { finalTurns }
    func decodeTally() async -> StretchTally? { tally }
    func transcribe(you: [Float], them: [Float]) async throws -> [MeetingTurn] {
        lock.withLock { _heard = [you.count, them.count] }
        onTranscribe?()
        if let batchFailure { throw batchFailure }
        return batchTurns
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
