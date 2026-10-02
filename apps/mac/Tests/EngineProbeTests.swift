import XCTest

/// the health check after a timeout: does the engine answer anything at
/// all, in time? one that hangs is a no, without waiting on it for good.
@MainActor
final class EngineProbeTests: XCTestCase {
    private var clock: FakeUtteranceClock!
    private var engine: FakeEngine!
    private var answer: Bool?

    override func setUp() async throws {
        clock = FakeUtteranceClock()
        engine = FakeEngine()
        answer = nil
    }

    override func tearDown() async throws {
        engine.release()
    }

    func testAnEngineThatAnswersIsAlive() async {
        engine.reply = .success("")

        let answered = await EngineProbe.answers(engine, clock: clock)

        XCTAssertTrue(answered)
        XCTAssertEqual(engine.heard.first?.count, 16_000)
    }

    /// an error is an answer, but not a healthy one.
    func testAnEngineThatThrowsIsNot() async {
        engine.reply = .failure(ProbeFailure())

        let answered = await EngineProbe.answers(engine, clock: clock)

        XCTAssertFalse(answered)
    }

    /// a hang is a no once the deadline passes, and not a moment before.
    func testAnEngineThatHangsIsNotOnceTheDeadlinePasses() async {
        engine.holds = true
        let engine = engine!
        let clock = clock!
        let probe = Task { @MainActor in
            self.answer = await EngineProbe.answers(
                engine,
                within: .seconds(4),
                clock: clock
            )
        }
        await settle { engine.isWaiting }
        // the deadline's sleep, queued before the clock moves.
        try? await Task.sleep(for: .milliseconds(20))

        clock.advance(by: .milliseconds(3_900))
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(answer)

        clock.advance(by: .milliseconds(100))
        await probe.value

        XCTAssertEqual(answer, false)
        // still out there: nothing can take a wedged call back.
        XCTAssertTrue(engine.isWaiting)
    }

    private func settle(
        until isDone: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 {
            if isDone() {
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("never settled", file: file, line: line)
    }
}

private struct ProbeFailure: Error {}
