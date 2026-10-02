import AVFoundation
import XCTest

/// Kept audio, through the coordinator and its fakes: after a meeting's file
/// is written its spool does not vanish, it is compressed into the app's
/// private folder for as long as the setting says, and a wall the test moves
/// by hand decides when that is up. Judged by the files a person or an agent
/// would find there.
@MainActor
final class KeptAudioTests: XCTestCase {
    private var dir: URL!
    private var source: FakeSource!
    private var transcribers: FakeTranscribers!
    private var wall: FakeWall!
    private var records: [MeetingRecord] = []
    private var keepAudio: KeepMeetingAudio = .oneDay

    /// 2026-10-02 06:52:31 UTC: when the meeting starts.
    private let started = Date(timeIntervalSince1970: 1_790_923_951)
    /// An hour on, when it is written out.
    private let writtenAt = Date(timeIntervalSince1970: 1_790_927_551)

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kept-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        source = FakeSource()
        transcribers = FakeTranscribers()
        wall = FakeWall(writtenAt)
        records = []
        keepAudio = .oneDay
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var docs: URL { dir.appendingPathComponent("docs") }
    private var audioFolder: URL { dir.appendingPathComponent("meeting-audio") }
    private var kept: KeptAudio { KeptAudio(root: audioFolder, now: { [wall] in wall!.now }) }

    private func coordinator(kept: KeptAudio? = nil, spool: MeetingSpool? = nil) -> MeetingCoordinator {
        let started = started
        let c = MeetingCoordinator(
            source: source,
            makeTranscriber: { [transcribers] _ in transcribers!.next() },
            diarizer: FakeDiarizer(),
            spool: spool ?? MeetingSpool(root: dir.appendingPathComponent("spool")),
            hookRunner: HookRunner(logURL: dir.appendingPathComponent("hooks.log")),
            keptAudio: kept ?? self.kept,
            thresholds: .init(
                probeTimeout: .seconds(1), silenceTimeout: .seconds(600),
                silenceFloor: 0.001, quietNudgeAfter: .seconds(3_600)),
            date: { started },
            preferences: { [unowned self] in
                MeetingPreferences(
                    folder: docs, hook: nil, model: .parakeetV3, keepAudio: keepAudio)
            }
        )
        c.keepMeetingRecord = { [weak self] in self?.records.append($0) }
        return c
    }

    // MARK: - kept after a pass

    /// One day, the default: the meeting's audio is in the app's own folder,
    /// compressed, with a label beside it saying whose it is and until
    /// when. The spool it came from is gone.
    func testAfterAPassTheAudioIsKeptForADayAndTheSpoolIsGone() async throws {
        transcribers.lineUp(healthy())

        try await meeting(seconds: 2)

        let transcript = try XCTUnwrap(MeetingTranscriptFile.listAll(in: docs).first)
        XCTAssertEqual(try keptFiles().map(\.pathExtension), ["json", "m4a"])
        let label = try keptLabel()
        XCTAssertEqual(label["transcript"] as? String, transcript.fileURL.path)
        XCTAssertEqual(label["started"] as? String, "2026-10-02T06:52:31Z")
        XCTAssertEqual(label["model"] as? String, "parakeetV3")
        XCTAssertEqual(label["until"] as? String, "2026-10-03T07:52:31Z")
        XCTAssertEqual(label["untilDeleted"] as? Bool, false)
        XCTAssertEqual(try spoolFolders(), 0)
        XCTAssertEqual(records.first?.audioKept, true)
        XCTAssertEqual(records.first?.audioKeptUntil, writtenAt.addingTimeInterval(86_400))
    }

    /// Compressed, not mixed: still two channels at the spool's 16 kHz, and
    /// as private as the spool was — 0600 files in a 0700 folder.
    func testKeptAudioIsTwoChannelsAt16kHzAndPrivate() async throws {
        transcribers.lineUp(healthy())

        try await meeting(seconds: 2)

        let audio = try XCTUnwrap(try keptFiles().first { $0.pathExtension == "m4a" })
        let file = try AVAudioFile(forReading: audio)
        XCTAssertEqual(file.fileFormat.channelCount, 2)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(file.fileFormat.streamDescription.pointee.mFormatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(try permissions(of: audioFolder), 0o700)
        for kept in try keptFiles() {
            XCTAssertEqual(try permissions(of: kept), 0o600, kept.lastPathComponent)
        }
    }

    // MARK: - the sweep

    /// A day and a second later, the sweep deletes it without asking.
    func testKeptAudioIsGoneOnceItsDayIsUpAndTheSweepHasRun() async throws {
        transcribers.lineUp(healthy())
        try await meeting(seconds: 2)
        XCTAssertEqual(kept.all().count, 1)

        wall.advance(by: 86_399)
        kept.sweep()
        XCTAssertEqual(kept.all().count, 1, "not yet")

        wall.advance(by: 1)
        kept.sweep()
        XCTAssertEqual(try keptFiles(), [])
    }

    /// The end of every meeting sweeps too: the last one's day is up by the
    /// time the next one is written out, and only the next one's is left.
    func testTheEndOfTheNextMeetingSweepsWhatIsDue() async throws {
        transcribers.lineUp(healthy(), healthy())
        let c = coordinator()
        try await meeting(seconds: 2, on: c)
        let first = try XCTUnwrap(kept.all().first)

        wall.advance(by: 2 * 86_400)
        try await meeting(seconds: 2, on: c)

        let left = kept.all()
        XCTAssertEqual(left.count, 1)
        XCTAssertNotEqual(left.first?.id, first.id)
        XCTAssertEqual(left.first?.label.until, writtenAt.addingTimeInterval(3 * 86_400))
    }

    /// A thin meeting's audio has no date: a month on, the sweep still
    /// leaves it, and the label says it waits for you.
    func testAThinMeetingsAudioOutlivesItsDay() async throws {
        transcribers.lineUp(thin(), thin())

        try await meeting(seconds: 2)
        wall.advance(by: 30 * 86_400)
        kept.sweep()

        XCTAssertEqual(try keptFiles().map(\.pathExtension), ["json", "m4a"])
        let label = try keptLabel()
        XCTAssertTrue(label["until"] is NSNull)
        XCTAssertEqual(label["untilDeleted"] as? Bool, true)
        XCTAssertEqual(records.first?.audioKept, true)
        XCTAssertNil(records.first?.audioKeptUntil)
    }

    // MARK: - delete at once

    /// Set to delete at once, a meeting that passes keeps nothing: the
    /// spool goes the moment the file is written, as it always did.
    func testDeleteAtOnceLeavesNoAudioAfterAPass() async throws {
        keepAudio = .deleteAtOnce
        transcribers.lineUp(healthy())

        try await meeting(seconds: 2)

        XCTAssertEqual(MeetingTranscriptFile.listAll(in: docs).count, 1)
        XCTAssertEqual(try keptFiles(), [])
        XCTAssertEqual(try spoolFolders(), 0)
        XCTAssertEqual(records.first?.audioKept, false)
    }

    /// Delete at once, and the disk would not let the spool go. The file
    /// is written; the next launch finishes the delete. It does not write
    /// the meeting out a second time, run the hook for it again, or keep
    /// audio the setting said not to.
    func testADeleteAtOnceThatFailedIsFinishedAtTheNextLaunchNotWrittenTwice() async throws {
        keepAudio = .deleteAtOnce
        transcribers.lineUp(healthy())
        let refusing = MeetingSpool(
            root: dir.appendingPathComponent("spool"),
            remove: { _ in throw CocoaError(.fileWriteNoPermission) })

        try await meeting(seconds: 2, on: coordinator(spool: refusing))
        XCTAssertEqual(MeetingTranscriptFile.listAll(in: docs).count, 1)
        XCTAssertEqual(try spoolFolders(), 1, "the disk would not let it go")

        let c = coordinator()
        c.recoverOrphans()
        await waitFor { (try? spoolFolders()) == 0 && !records.isEmpty }
        await waitFor(0.5) { records.count > 1 }

        XCTAssertEqual(MeetingTranscriptFile.listAll(in: docs).count, 1, "not written again")
        XCTAssertEqual(try spoolFolders(), 0)
        XCTAssertEqual(try keptFiles(), [])
        XCTAssertEqual(records.map(\.outcome), [.saved])
    }

    /// …but a thin one keeps its audio whatever the setting says.
    func testDeleteAtOnceStillKeepsAThinMeetingsAudio() async throws {
        keepAudio = .deleteAtOnce
        transcribers.lineUp(thin(), thin())

        try await meeting(seconds: 2)

        XCTAssertEqual(try keptFiles().map(\.pathExtension), ["json", "m4a"])
        XCTAssertEqual(try keptLabel()["untilDeleted"] as? Bool, true)
    }

    // MARK: - a conversion that fails

    /// Compressing failed: the spool's own file is kept as it is, under the
    /// same label, and the spool folder still goes. Audio is never lost to
    /// a conversion.
    func testAFailedCompressionKeepsTheSpoolsOwnFile() async throws {
        transcribers.lineUp(healthy())
        let failing = KeptAudio(
            root: audioFolder, now: { [wall] in wall!.now },
            compress: { _, _ in throw CocoaError(.fileWriteUnknown) })

        try await meeting(seconds: 2, on: coordinator(kept: failing))

        XCTAssertEqual(try keptFiles().map(\.pathExtension), ["caf", "json"])
        let audio = try XCTUnwrap(try keptFiles().first { $0.pathExtension == "caf" })
        XCTAssertEqual(try AVAudioFile(forReading: audio).length, 32_000)
        XCTAssertEqual(try spoolFolders(), 0)
        XCTAssertEqual(failing.all().count, 1)
    }

    // MARK: - from history

    /// `delete audio now` on the meeting's row: the audio and its label go,
    /// the transcript stays.
    func testDeleteAudioNowFromHistoryLeavesOnlyTheTranscript() async throws {
        transcribers.lineUp(healthy())
        try await meeting(seconds: 2)
        let history = MeetingsListModel(keptAudio: kept) { [docs] in
            MeetingTranscriptFile.listAll(in: docs)
        }
        let row = try XCTUnwrap(history.items.first)
        XCTAssertEqual(history.audioNote(for: row)?.hasPrefix("audio until "), true)

        history.deleteAudio(of: row)

        XCTAssertEqual(try keptFiles(), [])
        XCTAssertNil(history.audioNote(for: row))
        XCTAssertEqual(MeetingTranscriptFile.listAll(in: docs).count, 1)
    }

    /// deleting the transcript from history takes its audio with it.
    func testDeletingTheTranscriptFromHistoryDeletesItsAudio() async throws {
        transcribers.lineUp(thin(), thin())
        try await meeting(seconds: 2)
        let history = MeetingsListModel(
            keptAudio: kept,
            trash: { try FileManager.default.removeItem(at: $0) }
        ) { [docs] in
            MeetingTranscriptFile.listAll(in: docs)
        }
        let row = try XCTUnwrap(history.items.first)
        XCTAssertEqual(history.audioNote(for: row), "audio kept")

        history.delete(row)

        XCTAssertEqual(history.items, [])
        XCTAssertEqual(try keptFiles(), [])
    }

    // MARK: - the app stopped while it was keeping

    /// The file was written and the app quit while the audio was being
    /// kept. The next launch does not write the meeting out again: it
    /// finishes keeping the audio, and not knowing for how long, keeps it
    /// until you delete it.
    func testASpoolLeftWhileItsAudioWasBeingKeptIsKeptAtTheNextLaunch() async throws {
        let transcript = docs.appendingPathComponent("meetings/2026-10/2026-10-02-1222-meeting.md")
        try await spoolLeft(writtenTo: transcript)

        let c = coordinator()
        c.recoverOrphans()
        await waitFor { kept.all().count == 1 }
        await c.untilWrittenOut()

        XCTAssertEqual(MeetingTranscriptFile.listAll(in: docs).count, 0, "not written again")
        XCTAssertEqual(try keptFiles().map(\.pathExtension), ["json", "m4a"])
        let label = try keptLabel()
        XCTAssertEqual(label["transcript"] as? String, transcript.path)
        XCTAssertEqual(label["started"] as? String, "2026-10-02T06:52:31Z")
        XCTAssertEqual(label["untilDeleted"] as? Bool, true)
        XCTAssertEqual(try spoolFolders(), 0)
    }

    /// It had got as far as the label: the date on it stands.
    func testASpoolLeftAfterItsLabelWasWrittenKeepsTheLabelsDate() async throws {
        let transcript = docs.appendingPathComponent("meetings/2026-10/2026-10-02-1222-meeting.md")
        let handle = try await spoolLeft(writtenTo: transcript)
        try FileManager.default.createDirectory(at: audioFolder, withIntermediateDirectories: true)
        let until = "2026-10-03T07:52:31Z"
        try Data(#"{"model":"parakeetV3","started":"2026-10-02T06:52:31Z","transcript":"\#(transcript.path)","until":"\#(until)","untilDeleted":false}"#.utf8)
            .write(to: audioFolder.appendingPathComponent("\(handle.folder.lastPathComponent).json"))

        let c = coordinator()
        c.recoverOrphans()
        await waitFor { kept.all().count == 1 }

        XCTAssertEqual(try keptFiles().map(\.pathExtension), ["json", "m4a"])
        XCTAssertEqual(try keptLabel()["until"] as? String, until)
    }

    /// The app was killed after the audio was moved in and before the spool
    /// was let go. The next launch finds the audio already there and takes
    /// it as kept: moving it in again would fail on it at every launch, and
    /// the spool would never be deleted.
    func testAudioAlreadyMovedInIsTakenAsKeptAndTheSpoolGoes() async throws {
        let transcript = docs.appendingPathComponent("meetings/2026-10/2026-10-02-1222-meeting.md")
        let handle = try await spoolLeft(writtenTo: transcript)
        let id = handle.folder.lastPathComponent
        try FileManager.default.createDirectory(at: audioFolder, withIntermediateDirectories: true)
        try KeptAudio.aac(handle.audioURL, audioFolder.appendingPathComponent("\(id).m4a"))
        try Data(#"{"model":"parakeetV3","started":"2026-10-02T06:52:31Z","transcript":"\#(transcript.path)","until":null,"untilDeleted":true}"#.utf8)
            .write(to: audioFolder.appendingPathComponent("\(id).json"))

        let c = coordinator()
        c.recoverOrphans()
        await waitFor { (try? spoolFolders()) == 0 }

        XCTAssertEqual(try spoolFolders(), 0)
        XCTAssertEqual(try keptFiles().map(\.lastPathComponent), ["\(id).json", "\(id).m4a"])
        XCTAssertEqual(MeetingTranscriptFile.listAll(in: docs).count, 0, "not written again")
    }

    /// The spool's own audio would not be deleted once its copy was in. The
    /// spool stays whole, manifest and all — never audio with nothing left
    /// to say whose it is, which a launch would set aside and `try again`
    /// would write out as a second file — and goes at the next launch.
    func testASpoolWhoseAudioWouldNotGoStaysWholeUntilItCan() async throws {
        let transcript = docs.appendingPathComponent("meetings/2026-10/2026-10-02-1222-meeting.md")
        let handle = try await spoolLeft(writtenTo: transcript)
        let spool = MeetingSpool(root: dir.appendingPathComponent("spool"))
        let manifest = try XCTUnwrap(spool.writtenOut().first?.manifest)
        let fm = FileManager.default
        try fm.setAttributes([.immutable: true], ofItemAtPath: handle.audioURL.path)
        defer { try? fm.setAttributes([.immutable: false], ofItemAtPath: handle.audioURL.path) }

        XCTAssertTrue(kept.adopt(handle, manifest: manifest), "the audio is kept")
        XCTAssertTrue(fm.fileExists(atPath: handle.manifestURL.path), "and the spool is whole")
        XCTAssertEqual(spool.orphans().count, 0)
        XCTAssertEqual(spool.unreadableCount(), 0)

        try fm.setAttributes([.immutable: false], ofItemAtPath: handle.audioURL.path)
        XCTAssertTrue(kept.adopt(handle, manifest: manifest))
        XCTAssertEqual(try spoolFolders(), 0)
        XCTAssertEqual(try keptFiles().map(\.pathExtension), ["json", "m4a"])
    }

    /// The compressed copy came out short of the meeting. It is not taken
    /// on trust in place of the only original: the spool's own file is kept
    /// instead, as when compressing fails outright.
    func testACompressedCopyThatComesOutShortIsNotKeptInPlaceOfTheSpool() async throws {
        transcribers.lineUp(healthy())
        let short = KeptAudio(
            root: audioFolder, now: { [wall] in wall!.now },
            compress: { caf, m4a in try Self.aac(caf, m4a, frames: 8_000) })

        try await meeting(seconds: 2, on: coordinator(kept: short))

        XCTAssertEqual(try keptFiles().map(\.pathExtension), ["caf", "json"])
        let audio = try XCTUnwrap(try keptFiles().first { $0.pathExtension == "caf" })
        XCTAssertEqual(try AVAudioFile(forReading: audio).length, 32_000)
        XCTAssertEqual(try spoolFolders(), 0)
    }

    // MARK: - helpers

    /// The first `frames` of a spool as AAC, and no more: an encoder that
    /// stopped short.
    private nonisolated static func aac(_ caf: URL, _ m4a: URL, frames: AVAudioFrameCount) throws {
        let input = try AVAudioFile(forReading: caf, commonFormat: .pcmFormatFloat32, interleaved: false)
        let output = try AVAudioFile(
            forWriting: m4a,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: input.processingFormat.sampleRate,
                AVNumberOfChannelsKey: input.processingFormat.channelCount,
                AVEncoderBitRateKey: KeptAudio.bitRate,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: frames))
        try input.read(into: buffer, frameCount: frames)
        try output.write(from: buffer)
    }

    /// A spool whose meeting was written out into `transcript`, marked to be
    /// kept, with two seconds of audio still in it.
    @discardableResult
    private func spoolLeft(writtenTo transcript: URL) async throws -> MeetingSpool.Handle {
        let spool = MeetingSpool(root: dir.appendingPathComponent("spool"))
        let handle = try spool.begin(.init(
            app: "meeting", started: started, engine: "parakeetV3", model: .parakeetV3))
        let file = try SpoolAudioFile(url: handle.audioURL)
        try await file.append(loud(at: .zero))
        try await file.append(loud(at: .seconds(1)))
        XCTAssertTrue(spool.keep(handle, writtenTo: transcript))
        return handle
    }

    /// A live reading the check finds thin, and a reading again that is no
    /// better.
    private func thin() -> FakeTranscriber {
        let reading = FakeTranscriber()
        reading.tally = StretchTally(
            decodedThem: 900, speechThem: .seconds(3_600), readThem: .seconds(3_600))
        return reading
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? Int)
    }

    /// A live reading the coverage check passes.
    private func healthy() -> FakeTranscriber {
        let live = FakeTranscriber()
        live.finalTurns = [.init(speaker: .you, at: .seconds(1), text: "the deploy is blocked")]
        live.tally = StretchTally(decodedYou: 1, speechYou: .seconds(1), readYou: .seconds(1))
        return live
    }

    /// A meeting `seconds` long, loud on both sides, stopped and written out.
    private func meeting(seconds length: Int, on c: MeetingCoordinator? = nil) async throws {
        let c = c ?? coordinator()
        c.start()
        await source.awaitStart()
        for s in 0..<length {
            source.send(loud(at: Duration.seconds(s)))
        }
        await waitFor { c.elapsed >= Duration.seconds(length) }
        c.stop()
        await c.untilWrittenOut()
    }

    /// What is in the kept audio folder, by name.
    private func keptFiles() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: audioFolder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: audioFolder.path)
            .filter { !$0.hasPrefix(".") }
            .sorted()
            .map { audioFolder.appendingPathComponent($0) }
    }

    /// The one label in the folder, as an agent reading it would.
    private func keptLabel() throws -> [String: Any] {
        let url = try XCTUnwrap(try keptFiles().first { $0.pathExtension == "json" })
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try XCTUnwrap(object as? [String: Any])
    }

    private func spoolFolders() throws -> Int {
        let root = dir.appendingPathComponent("spool")
        guard FileManager.default.fileExists(atPath: root.path) else { return 0 }
        return try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { !$0.hasPrefix(".") }.count
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

/// The date on the wall, moved by hand.
private final class FakeWall: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) {
        self.date = date
    }

    var now: Date {
        lock.withLock { date }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { date = date.addingTimeInterval(interval) }
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
/// each hears nothing and keeps no count.
private final class FakeTranscribers: @unchecked Sendable {
    private let lock = NSLock()
    private var lined: [FakeTranscriber] = []

    func lineUp(_ transcribers: FakeTranscriber...) {
        lock.withLock { lined.append(contentsOf: transcribers) }
    }

    func next() -> FakeTranscriber {
        lock.withLock { lined.isEmpty ? FakeTranscriber() : lined.removeFirst() }
    }
}

private final class FakeTranscriber: MeetingTranscriber, @unchecked Sendable {
    var finalTurns: [MeetingTurn] = []
    var batchTurns: [MeetingTurn] = []
    var tally: StretchTally?
    let lines: AsyncStream<LiveLine>

    init() {
        (lines, _) = AsyncStream<LiveLine>.makeStream()
    }

    func begin() async throws {}
    func feed(_ chunk: MeetingAudioChunk) async {}
    func finish() async -> [MeetingTurn] { finalTurns }
    func decodeTally() async -> StretchTally? { tally }
    func transcribe(you: [Float], them: [Float]) async throws -> [MeetingTurn] { batchTurns }
}

private struct FakeDiarizer: MeetingDiarizer {
    func split(them: [Float], turns: [MeetingTurn]) async -> [MeetingTurn] { turns }
}
