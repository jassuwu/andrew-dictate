import XCTest

/// The call watcher fed by a fake mic and a fake Core Audio, in simulated
/// time: what the monitor reads, when, and what it says.
@MainActor
final class CallMonitorTests: XCTestCase {
    private let ours: Int32 = 500
    private var clock: SimulatedTime!
    private var mic: FakeMicSignal!
    private var audio: FakeCoreAudio!
    private var reads: Int { audio.reads }
    private var processes: [AudioProcess] {
        get { audio.processes }
        set { audio.processes = newValue }
    }
    private var suggestions: [CallWatcher.Suggestion] = []

    override func setUp() async throws {
        clock = SimulatedTime()
        mic = FakeMicSignal()
        audio = FakeCoreAudio()
        suggestions = []
    }

    private func monitor(isRecording: Bool = false) -> CallMonitor {
        let clock = clock!
        let audio = audio!
        let monitor = CallMonitor(
            mic: mic,
            read: {
                await MainActor.run {
                    audio.reads += 1
                    return audio.processes
                }
            },
            ownPID: ours,
            now: { clock.now },
            sleep: { duration in
                clock.advance(duration)
                await Task.yield()
            }
        )
        monitor.isRecording = { isRecording }
        monitor.onSuggestion = { [weak self] in self?.suggestions.append($0) }
        return monitor
    }

    /// Lets the monitor run in simulated time until `done` or a ceiling.
    private func run(until done: () -> Bool, for limit: Duration = .seconds(600)) async {
        let start = clock.now
        while !done(), clock.now - start < limit {
            await Task.yield()
        }
    }

    func testNothingIsReadWhileNobodyHoldsTheMic() async {
        let monitor = monitor()
        monitor.start()
        mic.say(false)

        for _ in 0..<50 { await Task.yield() }

        XCTAssertEqual(reads, 0)
        monitor.stop()
    }

    func testACallAppOnTheMicAndPlayingIsSuggestedOnce() async {
        processes = [
            AudioProcess(pid: 900, bundleID: "us.zoom.xos", isRunningInput: true, isRunningOutput: true)
        ]
        let monitor = monitor()
        monitor.start()
        mic.say(true)

        await run(until: { clock.now >= .seconds(60) })

        XCTAssertEqual(suggestions, [.record("zoom")])
        XCTAssertEqual(monitor.currentCall, "zoom")
        XCTAssertEqual(monitor.unrecordedCall, "zoom")
        monitor.stop()
    }

    /// Dictation takes the mic, and pre-roll keeps it: the listener fires
    /// for us like for anyone. The reads find nobody but us, nothing is
    /// suggested, and the reads slow to one every ten seconds.
    func testOurOwnMicIsNoCallAndIsReadRarely() async {
        processes = [
            AudioProcess(pid: ours, bundleID: "gg.jass.dictate", isRunningInput: true, isRunningOutput: true)
        ]
        let monitor = monitor()
        monitor.start()
        mic.say(true)

        await run(until: { clock.now >= .seconds(60) })

        XCTAssertEqual(suggestions, [])
        XCTAssertNil(monitor.currentCall)
        // read at once, then every ten seconds: not thirty reads a minute.
        XCTAssertGreaterThanOrEqual(reads, 6)
        XCTAssertLessThanOrEqual(reads, 8)
        monitor.stop()
    }

    /// A recording is read throughout, so the call app letting go of the mic
    /// and the speakers is seen, and asked about once, thirty seconds on.
    func testARecordedCallThatEndsIsAskedAboutOnce() async {
        processes = [
            AudioProcess(pid: 900, bundleID: "us.zoom.xos", isRunningInput: true, isRunningOutput: true)
        ]
        let monitor = monitor(isRecording: true)
        monitor.start()
        mic.say(true)
        await run(until: { monitor.currentCall == "zoom" })
        XCTAssertEqual(suggestions, [])

        processes = []
        let ended = clock.now
        await run(until: { !suggestions.isEmpty })

        XCTAssertEqual(suggestions, [.stop("zoom")])
        // thirty seconds from the first read that found nobody, which is up
        // to one read after the app let go, and seen on the next read after
        // that: between thirty and thirty-four.
        XCTAssertEqual(clock.now - ended, .seconds(32), accuracy: .seconds(2))
        await run(until: { false }, for: .seconds(120))
        XCTAssertEqual(suggestions, [.stop("zoom")])
        monitor.stop()
    }

    /// Nothing recording, and the call app let go of the mic: there is
    /// nothing to read, so nothing is. The call ends thirty seconds on and
    /// the monitor stops.
    func testAnUnrecordedCallWindsDownWithoutReadingAndThenStops() async {
        processes = [
            AudioProcess(pid: 900, bundleID: "us.zoom.xos", isRunningInput: true, isRunningOutput: true)
        ]
        let monitor = monitor()
        monitor.start()
        mic.say(true)
        await run(until: { monitor.currentCall == "zoom" })

        mic.say(false)
        // the change lands on the main actor a turn later; a read already
        // under way when it does is the last one.
        for _ in 0..<10 { await Task.yield() }
        let readsWhenFreed = reads
        await run(until: { monitor.currentCall == nil })
        XCTAssertNil(monitor.unrecordedCall)
        XCTAssertEqual(reads, readsWhenFreed)

        // and once it is over, nothing ticks: simulated time stands still.
        let stoppedAt = clock.now
        for _ in 0..<200 { await Task.yield() }
        XCTAssertEqual(clock.now, stoppedAt)
        monitor.stop()
    }
}

private func XCTAssertEqual(
    _ actual: Duration,
    _ expected: Duration,
    accuracy: Duration,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let apart = actual > expected ? actual - expected : expected - actual
    XCTAssertTrue(
        apart <= accuracy,
        "\(actual) is not within \(accuracy) of \(expected)",
        file: file, line: line)
}

/// What the fake Core Audio holds and how often it was asked. Touched on
/// the main actor only.
private final class FakeCoreAudio: @unchecked Sendable {
    var processes: [AudioProcess] = []
    var reads = 0
}

private final class SimulatedTime: @unchecked Sendable {
    private(set) var now: Duration = .zero

    func advance(_ duration: Duration) {
        now += duration
    }
}

private final class FakeMicSignal: MicUseSignal, @unchecked Sendable {
    private var onChange: (@Sendable (Bool) -> Void)?

    func start(onChange: @escaping @Sendable (Bool) -> Void) {
        self.onChange = onChange
    }

    func stop() {
        onChange = nil
    }

    func say(_ inUse: Bool) {
        onChange?(inUse)
    }
}
