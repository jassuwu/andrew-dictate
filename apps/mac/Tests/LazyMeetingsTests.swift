import XCTest

/// a mac that only dictates pays nothing for meetings: launch builds no
/// coordinator, no notifier, and walks no transcripts folder, and every
/// question the menu, the badge and the dictation key ask is answered
/// without building one.
@MainActor
final class LazyMeetingsTests: XCTestCase {
    private var dir: URL!
    private var spool: MeetingSpool!
    private var transcripts: URL!
    private var coordinatorsBuilt = 0
    private var notifiersBuilt = 0
    private var callMonitorsBuilt = 0
    private var mic: IdleMic!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lazy-meetings-\(UUID().uuidString)")
        // the spool folder is not made: a mac that never recorded a meeting
        // has none.
        spool = MeetingSpool(root: dir.appendingPathComponent("spool"))
        transcripts = dir.appendingPathComponent("transcripts")
        coordinatorsBuilt = 0
        notifiersBuilt = 0
        callMonitorsBuilt = 0
        mic = IdleMic()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    func testALaunchWithNoMeetingModelAndNoSpoolBuildsNothing() async throws {
        let transcript = try oldTranscript()
        let meetings = holder()

        let recovery = meetings.launch(
            setUp: false, watchesForCalls: false, transcripts: transcripts,
            spool: spool, recoveryDelay: .zero)

        XCTAssertNil(recovery)
        // everything the menu, the badge and the key read, and everything
        // a stray click can reach without a meeting running
        XCTAssertFalse(meetings.isRecording)
        XCTAssertFalse(meetings.isWritingOut)
        await meetings.untilWrittenOut()
        XCTAssertEqual(meetings.elapsed, .zero)
        XCTAssertNil(meetings.recovering)
        XCTAssertEqual(meetings.dictationResponse, .allow)
        XCTAssertNil(meetings.currentCall)
        XCTAssertNil(meetings.unrecordedCall)
        meetings.probeTapIsAlive()
        meetings.keepGoing()
        meetings.stop()
        meetings.withdrawNudge()
        meetings.recordingChanged()
        meetings.declineTheCall()

        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(coordinatorsBuilt, 0)
        XCTAssertEqual(notifiersBuilt, 0)
        XCTAssertEqual(callMonitorsBuilt, 0)
        XCTAssertEqual(permissions(of: transcript), 0o644)
    }

    func testASpoolLeftByACrashIsWhatBuildsTheCoordinator() async throws {
        _ = try spool.begin(.init(
            app: "zoom", started: Date(timeIntervalSince1970: 1_787_000_000),
            engine: "whisper-large-v3", model: .whisperLargeV3))
        let meetings = holder()

        let recovery = meetings.launch(
            setUp: false, watchesForCalls: false, transcripts: transcripts,
            spool: spool, recoveryDelay: .zero)
        await recovery?.value

        XCTAssertNotNil(recovery)
        XCTAssertEqual(coordinatorsBuilt, 1)
        XCTAssertEqual(notifiersBuilt, 0)
    }

    /// a model on disk or a chosen folder: the last run's banner still has
    /// a delegate to click through to, and old transcripts get locked down.
    func testAMacSetUpForMeetingsGetsItsNotifierAndItsRepairAtLaunch() async throws {
        let transcript = try oldTranscript()
        let meetings = holder()

        let recovery = meetings.launch(
            setUp: true, watchesForCalls: false, transcripts: transcripts,
            spool: spool, recoveryDelay: .zero)

        XCTAssertNil(recovery)
        XCTAssertEqual(coordinatorsBuilt, 0)
        XCTAssertEqual(notifiersBuilt, 1)
        // a chosen folder with no model is set up for transcripts, not for
        // calls: there is nothing to record one with.
        XCTAssertEqual(callMonitorsBuilt, 0)
        for _ in 0..<100 where permissions(of: transcript) != 0o600 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(permissions(of: transcript), 0o600)
    }

    /// a meeting model on disk: the app listens for the mic being taken,
    /// and builds nothing else to do it.
    func testAMacWithAMeetingModelWatchesForCalls() {
        let meetings = holder()
        var wired = 0
        meetings.onCallMonitorBuilt = { _ in wired += 1 }

        _ = meetings.launch(
            setUp: true, watchesForCalls: true, transcripts: transcripts,
            spool: spool, recoveryDelay: .zero)
        meetings.watchForCalls()

        XCTAssertEqual(callMonitorsBuilt, 1)
        XCTAssertEqual(wired, 1)
        XCTAssertEqual(mic.starts, 1)
        XCTAssertEqual(coordinatorsBuilt, 0)
    }

    func testEachIsBuiltOnceAndWiredBeforeItIsHandedOut() {
        let meetings = holder()
        var wired: [String] = []
        meetings.onCoordinatorBuilt = { _ in wired.append("coordinator") }
        meetings.onNotifierBuilt = { _ in wired.append("notifier") }

        XCTAssertTrue(meetings.coordinator === meetings.coordinator)
        XCTAssertTrue(meetings.notifier === meetings.notifier)

        XCTAssertEqual(coordinatorsBuilt, 1)
        XCTAssertEqual(notifiersBuilt, 1)
        XCTAssertEqual(wired, ["coordinator", "notifier"])
    }

    // MARK: -

    private func holder() -> LazyMeetings {
        let spool = spool!
        let dir = dir!
        return LazyMeetings(
            coordinator: { [weak self] in
                self?.coordinatorsBuilt += 1
                return MeetingCoordinator(
                    source: SilentSource(),
                    makeTranscriber: { _ in throw NoModel() },
                    diarizer: NoDiarizer(),
                    spool: spool,
                    hookRunner: HookRunner(
                        logURL: dir.appendingPathComponent("hooks.log")),
                    preferences: {
                        MeetingPreferences(
                            folder: dir.appendingPathComponent("transcripts"),
                            hook: nil, model: .whisperLargeV3)
                    }
                )
            },
            notifier: { [weak self] in
                self?.notifiersBuilt += 1
                return MeetingNudgeNotifier()
            },
            callMonitor: { [weak self, mic = mic!] in
                self?.callMonitorsBuilt += 1
                return CallMonitor(mic: mic, read: { [] })
            }
        )
    }

    /// a transcript from before the app locked them down: readable by
    /// every account on the mac until launch repairs it.
    private func oldTranscript() throws -> URL {
        let month = transcripts
            .appendingPathComponent(MeetingTranscriptFile.folderName)
            .appendingPathComponent("2026-08")
        try FileManager.default.createDirectory(
            at: month, withIntermediateDirectories: true)
        let file = month.appendingPathComponent("2026-08-29-1402-zoom.md")
        try "---\n---\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: file.path)
        return file
    }

    private func permissions(of url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[
            .posixPermissions] as? Int
    }
}

private struct NoModel: Error {}

/// a mic nobody takes: the monitor listens and is never told to read.
private final class IdleMic: MicUseSignal, @unchecked Sendable {
    private(set) var starts = 0

    func start(onChange: @escaping @Sendable (Bool) -> Void) {
        starts += 1
        onChange(false)
    }

    func stop() {}
}

private struct SilentSource: MeetingAudioSource {
    func start() async throws -> AsyncStream<MeetingAudioChunk> {
        AsyncStream { $0.finish() }
    }

    func rebuild() async throws {}
    func stop() async {}
}

private struct NoDiarizer: MeetingDiarizer {
    func split(them: [Float], turns: [MeetingTurn]) async -> [MeetingTurn] {
        turns
    }
}
