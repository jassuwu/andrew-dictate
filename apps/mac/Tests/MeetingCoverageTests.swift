import XCTest

/// The coverage check, through the coordinator and its fakes: at the stop,
/// before any audio is let go, what was transcribed is held against what was
/// said. Judged by what a person or an agent would notice — the files, their
/// front matter and lines, the lamp, the hook, the record, the audio left.
@MainActor
final class MeetingCoverageTests: XCTestCase {
    private var dir: URL!
    private var source: FakeSource!
    private var transcribers: FakeTranscribers!
    private var events: [MeetingEvent] = []
    private var records: [MeetingRecord] = []
    private var hook: URL?

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-coverage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        source = FakeSource()
        transcribers = FakeTranscribers()
        events = []
        records = []
        hook = nil
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private var docs: URL { dir.appendingPathComponent("docs") }
    private var spool: MeetingSpool { MeetingSpool(root: dir.appendingPathComponent("spool")) }

    private func coordinator() -> MeetingCoordinator {
        let c = MeetingCoordinator(
            source: source,
            makeTranscriber: { [transcribers] model in try transcribers!.next(for: model) },
            diarizer: FakeDiarizer(),
            spool: spool,
            hookRunner: HookRunner(logURL: dir.appendingPathComponent("hooks.log")),
            thresholds: .init(
                probeTimeout: .seconds(1), silenceTimeout: .seconds(600),
                silenceFloor: 0.001, quietNudgeAfter: .seconds(3_600)),
            preferences: { [unowned self] in
                MeetingPreferences(folder: docs, hook: hook, model: .parakeetV3)
            }
        )
        c.onEvent = { [weak self] in self?.events.append($0) }
        c.keepMeetingRecord = { [weak self] in self?.records.append($0) }
        return c
    }

    // MARK: - read again

    /// The engine heard an hour of talk on both sides and gave back nothing.
    /// The audio is still on the spool: it is read again, by a fresh
    /// transcriber for the same model, and the file holds what that found —
    /// written once, never written and then changed.
    func testATranscriberThatReturnsNothingForAnHourOfSpeechIsReadAgainFromTheSpool() async throws {
        let live = FakeTranscriber()
        live.tally = StretchTally(
            decodedYou: 400, decodedThem: 500,
            speechYou: .seconds(1_500), speechThem: .seconds(2_100),
            readYou: .seconds(1_500), readThem: .seconds(2_100))
        let again = FakeTranscriber()
        again.batchTurns = [
            .init(speaker: .you, at: .seconds(1), text: "the deploy is blocked"),
            .init(speaker: .them(nil), at: .seconds(2), text: "since when"),
        ]
        again.tally = StretchTally(
            decodedYou: 1, decodedThem: 1,
            speechYou: .seconds(1), speechThem: .seconds(1),
            readYou: .seconds(1), readThem: .seconds(1))
        transcribers.lineUp(live, again)

        try await meeting(seconds: 2)

        let files = MeetingTranscriptFile.listAll(in: docs)
        XCTAssertEqual(files.count, 1, "written once")
        let file = try XCTUnwrap(files.first)
        XCTAssertEqual(try lines(of: file), [
            "[00:00:01] you: the deploy is blocked",
            "[00:00:02] them 1: since when",
        ])
        XCTAssertEqual(try frontMatter(of: file)["complete"], "true")
        XCTAssertEqual(again.heard, [32_000, 32_000], "the whole spool, both sides")
        XCTAssertEqual(transcribers.made, [.parakeetV3, .parakeetV3])
        XCTAssertEqual(events.filter { $0 == .readingAgain }.count, 1)
        XCTAssertEqual(
            MeetingEvent.readingAgain.hudText,
            "the transcript looked thin — reading the audio again…")
        XCTAssertEqual(events.filter { if case .saved = $0 { true } else { false } }.count, 1)
    }

    // MARK: - still thin

    /// Read again, and still far fewer words than the talk: the file is
    /// written once, with the reading that has more in it, and says it is
    /// not whole and why — in its front matter, and to the hook.
    func testAReadingThatIsStillThinIsWrittenIncompleteWithItsReason() async throws {
        hook = try script("#!/bin/sh\ncat > \"$ANDREW_FOLDER/seen.json\"\nexit 0\n")
        let (live, again) = stillThin()
        transcribers.lineUp(live, again)

        try await meeting(seconds: 2)

        let files = MeetingTranscriptFile.listAll(in: docs)
        XCTAssertEqual(files.count, 1, "written once")
        let file = try XCTUnwrap(files.first)
        XCTAssertFalse(file.complete)
        XCTAssertEqual(try frontMatter(of: file)["complete"], "false")
        XCTAssertEqual(
            try frontMatter(of: file)["reason"], "far fewer words than the talk that was heard")
        XCTAssertEqual(try lines(of: file), ["[00:00:01] them 1: since when exactly"])
        let told = try await toldTheHook(beside: file)
        XCTAssertEqual(told["complete"] as? Bool, false)
    }

    /// The lamp does not say `saved` as if all were well: it says the file
    /// is not whole and that the audio is still there.
    func testTheLampSaysAMeetingThatStayedThinIsIncompleteAndItsAudioKept() async throws {
        let (live, again) = stillThin()
        transcribers.lineUp(live, again)

        try await meeting(seconds: 2)

        let saved = events.compactMap { if case .saved = $0 { $0 } else { nil } }
        XCTAssertEqual(saved.map(\.hudText), ["saved · incomplete, audio kept"])
    }

    /// The audio of a meeting that stayed thin is all there is to check the
    /// file against, or to read it again from: it is kept. It is not a
    /// spool a crash left, either — the next launch does not write the
    /// meeting out a second time.
    func testTheAudioOfAMeetingThatStayedThinIsKeptAndIsNotAnOrphan() async throws {
        let (live, again) = stillThin()
        transcribers.lineUp(live, again)

        try await meeting(seconds: 2)

        XCTAssertEqual(try keptSpools(), 1)
        XCTAssertEqual(spool.orphans().count, 0)
        let launch = coordinator()
        launch.recoverOrphans()
        await settle()
        XCTAssertEqual(MeetingTranscriptFile.listAll(in: docs).count, 1)
        XCTAssertEqual(try keptSpools(), 1)
    }

    /// The record says so: a save of its own kind, the check's result and
    /// reason, the numbers it was reached from, and the audio kept with no
    /// date to go.
    func testTheRecordOfAMeetingThatStayedThinSaysSo() async throws {
        let (live, again) = stillThin()
        transcribers.lineUp(live, again)

        try await meeting(seconds: 2)

        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.outcome, .savedThin)
        XCTAssertEqual(record.outcome.name, "saved-thin")
        XCTAssertEqual(record.coverage, .init(
            result: .thin, reason: "far fewer words than the talk that was heard",
            speechYouS: 0, speechThemS: 3_600, unreadYouS: 0, unreadThemS: 0,
            bleed: 0, farSideLoudS: 2))
        XCTAssertEqual(record.audioKept, true)
        XCTAssertNil(record.audioKeptUntil)
    }

    /// Reading it again threw: there is only the live reading, and it is
    /// written as it is — not whole, with the reason it was thin, and its
    /// audio kept.
    func testAReadingAgainThatThrowsLeavesTheLiveReadingWrittenIncompleteWithItsAudio() async throws {
        hook = try script("#!/bin/sh\ncat > \"$ANDREW_FOLDER/seen.json\"\nexit 0\n")
        let (live, again) = stillThin()
        again.batchFailure = Unreadable()
        transcribers.lineUp(live, again)

        try await meeting(seconds: 2)

        let files = MeetingTranscriptFile.listAll(in: docs)
        XCTAssertEqual(files.count, 1, "written once")
        let file = try XCTUnwrap(files.first)
        XCTAssertEqual(try frontMatter(of: file)["complete"], "false")
        XCTAssertEqual(
            try frontMatter(of: file)["reason"], "far fewer words than the talk that was heard")
        XCTAssertEqual(try lines(of: file), ["[00:00:01] them 1: hmm right"])
        let told = try await toldTheHook(beside: file)
        XCTAssertEqual(told["complete"] as? Bool, false)
        XCTAssertEqual(try keptSpools(), 1)
        XCTAssertEqual(spool.orphans().count, 0)
        XCTAssertEqual(records.map(\.outcome), [.savedThin])
        XCTAssertEqual(records.first?.coverage?.result, .thin)
        XCTAssertEqual(records.first?.audioKept, true)
    }

    // MARK: - covered

    /// A meeting the transcript covers is written once, from the live
    /// reading, and nothing is read again.
    func testAHealthyMeetingPassesWithOneWriteAndNoReadingAgain() async throws {
        let live = FakeTranscriber()
        live.finalTurns = [
            .init(speaker: .you, at: .seconds(1), text: "the deploy is blocked"),
            .init(speaker: .them(nil), at: .seconds(2), text: "since when"),
        ]
        live.tally = StretchTally(
            decodedYou: 1, decodedThem: 1,
            speechYou: .seconds(1), speechThem: .seconds(1),
            readYou: .seconds(1), readThem: .seconds(1))
        transcribers.lineUp(live)

        try await meeting(seconds: 2)

        let files = MeetingTranscriptFile.listAll(in: docs)
        XCTAssertEqual(files.count, 1)
        let file = try XCTUnwrap(files.first)
        XCTAssertTrue(file.complete)
        XCTAssertEqual(try lines(of: file), [
            "[00:00:01] you: the deploy is blocked",
            "[00:00:02] them 1: since when",
        ])
        XCTAssertEqual(transcribers.made, [.parakeetV3], "read once")
        XCTAssertFalse(events.contains(.readingAgain))
        XCTAssertEqual(records.map(\.outcome), [.saved])
        XCTAssertEqual(records.first?.coverage, .init(
            result: .pass, speechYouS: 1, speechThemS: 1, unreadYouS: 0, unreadThemS: 0,
            bleed: 0, farSideLoudS: 2))
        XCTAssertEqual(records.first?.audioKept, false)
    }

    /// Thin the first time and whole the second: the record says it was
    /// read again, and why.
    func testTheRecordOfAMeetingReadAgainIntoAWholeTranscriptSaysWhy() async throws {
        let live = FakeTranscriber()
        live.tally = StretchTally(
            decodedYou: 70, failed: 30, speechYou: .seconds(100), readYou: .seconds(70))
        let again = FakeTranscriber()
        again.batchTurns = [.init(speaker: .you, at: .seconds(1), text: "the deploy is blocked")]
        again.tally = StretchTally(decodedYou: 1, speechYou: .seconds(1), readYou: .seconds(1))
        transcribers.lineUp(live, again)

        try await meeting(seconds: 2)

        XCTAssertEqual(records.map(\.outcome), [.saved])
        XCTAssertEqual(records.first?.coverage, .init(
            result: .passAfterRerun, reason: "some of what was said could not be read",
            speechYouS: 1, speechThemS: 0, unreadYouS: 0, unreadThemS: 0,
            bleed: 0, farSideLoudS: 2))
    }

    /// A call where nobody said anything: whole, and the page says why it is
    /// empty instead of looking like a transcript that lost everything.
    func testAMeetingWhereNobodySpokePassesAndSaysSo() async throws {
        let live = FakeTranscriber()
        live.tally = StretchTally()
        transcribers.lineUp(live)

        try await meeting(seconds: 2)

        let file = try XCTUnwrap(MeetingTranscriptFile.listAll(in: docs).first)
        XCTAssertTrue(file.complete)
        XCTAssertEqual(try frontMatter(of: file)["complete"], "true")
        XCTAssertEqual(try body(of: file), ["> nobody spoke"])
        XCTAssertEqual(records.first?.coverage?.result, .pass)
    }

    // MARK: - what the spool says on its own

    /// A minute of the far side talking on the spool, and a transcriber
    /// that never heard any of it — fed nothing, it counted nothing and
    /// wrote nothing. Only the spool can tell, and it does.
    func testTheFarSideLoudInTheSpoolWithATranscriberThatWasNeverFedIsThin() async throws {
        let live = FakeTranscriber()
        live.tally = StretchTally()
        transcribers.lineUp(live, FakeTranscriber())

        try await meeting(seconds: 61)

        let file = try XCTUnwrap(MeetingTranscriptFile.listAll(in: docs).first)
        XCTAssertEqual(try frontMatter(of: file)["complete"], "false")
        XCTAssertEqual(
            try frontMatter(of: file)["reason"],
            "the other side was heard and nothing of it was read")
        XCTAssertEqual(records.map(\.outcome), [.savedThin])
        XCTAssertEqual(records.first?.coverage?.farSideLoudS, 61)
        XCTAssertEqual(try keptSpools(), 1)
    }

    // MARK: - recovery

    /// A spool a crash left is read whole at the next launch, and that
    /// reading is checked like any other. Thin, it is written once, not
    /// whole and saying why, and its audio stays — it is not read a second
    /// time, because it was already read from the spool.
    func testARecoveredSpoolGoesThroughTheCheck() async throws {
        try await orphan(seconds: 2)
        let recovering = FakeTranscriber()
        recovering.tally = StretchTally(
            decodedThem: 900, speechThem: .seconds(3_600), readThem: .seconds(3_600))
        transcribers.lineUp(recovering)

        let c = coordinator()
        c.recoverOrphans()
        await waitFor { !records.isEmpty }
        await c.untilWrittenOut()

        let files = MeetingTranscriptFile.listAll(in: docs)
        XCTAssertEqual(files.count, 1)
        let file = try XCTUnwrap(files.first)
        XCTAssertTrue(file.recovered)
        XCTAssertEqual(try frontMatter(of: file)["complete"], "false")
        XCTAssertEqual(
            try frontMatter(of: file)["reason"], "far fewer words than the talk that was heard")
        XCTAssertEqual(transcribers.made, [.whisperLargeV3Turbo], "read once")
        XCTAssertFalse(events.contains(.readingAgain))
        XCTAssertEqual(try keptSpools(), 1)
        XCTAssertEqual(spool.orphans().count, 0)
        XCTAssertEqual(records.map(\.outcome), [.savedThin])
        XCTAssertEqual(records.first?.recovered, true)
        XCTAssertEqual(records.first?.coverage?.result, .thin)
    }

    // MARK: - helpers

    /// A spool a crash left behind, `seconds` of it loud on both sides.
    private func orphan(seconds: Int) async throws {
        let handle = try spool.begin(.init(
            app: "teams", started: Date(timeIntervalSince1970: 1_787_000_000),
            engine: "whisper-large-v3-turbo", model: .whisperLargeV3Turbo))
        let file = try SpoolAudioFile(url: handle.audioURL)
        for s in 0..<seconds {
            try await file.append(loud(at: .seconds(s)))
        }
    }

    /// What follows the front matter, line by line, blank lines left out.
    private func body(of file: MeetingSummary) throws -> [String] {
        let text = try String(contentsOf: file.fileURL, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let closing = try XCTUnwrap(lines.dropFirst().firstIndex(of: "---"))
        return lines[(closing + 1)...].filter { !$0.isEmpty }
    }

    /// Spool folders with their audio still in them.
    private func keptSpools() throws -> Int {
        let root = dir.appendingPathComponent("spool")
        return try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { !$0.hasPrefix(".") }
            .filter {
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent($0).appendingPathComponent("audio.caf").path)
            }
            .count
    }

    private func settle(for seconds: Double = 0.3) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// A live reading of an hour of their talk that came to two words, and
    /// a reading again from the spool that came to three: more, and no
    /// better.
    private func stillThin() -> (FakeTranscriber, FakeTranscriber) {
        let live = FakeTranscriber()
        live.finalTurns = [.init(speaker: .them(nil), at: .seconds(1), text: "hmm right")]
        live.tally = StretchTally(
            decodedThem: 900, speechThem: .seconds(3_600), readThem: .seconds(3_600))
        let again = FakeTranscriber()
        again.batchTurns = [.init(speaker: .them(nil), at: .seconds(1), text: "since when exactly")]
        again.tally = StretchTally(
            decodedThem: 900, speechThem: .seconds(3_600), readThem: .seconds(3_600))
        return (live, again)
    }

    /// What the hook was handed on stdin, as a hook that saves it beside the
    /// transcript left it. The hook runs after the file is written, so this
    /// waits for it.
    private func toldTheHook(beside file: MeetingSummary) async throws -> [String: Any] {
        let url = file.fileURL.deletingLastPathComponent().appendingPathComponent("seen.json")
        // `cat >` makes the file before it has written to it.
        await waitFor {
            (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) != nil
        }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try XCTUnwrap(object as? [String: Any])
    }

    private func script(_ text: String) throws -> URL {
        let url = dir.appendingPathComponent("hook.sh")
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

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

    /// The turn lines of a saved transcript.
    private func lines(of file: MeetingSummary) throws -> [String] {
        let body = try String(contentsOf: file.fileURL, encoding: .utf8)
        return body.split(separator: "\n").filter { $0.hasPrefix("[") }.map(String.init)
    }

    /// Its front matter, key to value as written.
    private func frontMatter(of file: MeetingSummary) throws -> [String: String] {
        let body = try String(contentsOf: file.fileURL, encoding: .utf8)
        var fields: [String: String] = [:]
        for line in body.split(separator: "\n").dropFirst() {
            if line == "---" { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields[String(line[..<colon])] = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
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

private struct Unreadable: Error {}

/// One per reading, the way the app builds them: the meeting's own, then a
/// fresh one for each time its spool is read again. Past the ones lined up,
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
    /// What it says its decoding came to, live or read whole. nil keeps no
    /// count.
    var tally: StretchTally?
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
