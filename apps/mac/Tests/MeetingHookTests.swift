import XCTest

final class MeetingHookTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testThePayloadCarriesExactlyTheDocumentedKeys() throws {
        let data = try event().payloadJSON()
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(
            Set(object.keys),
            ["event", "transcript", "folder", "app", "started_at",
             "duration_s", "complete", "gaps", "recovered"]
        )
        XCTAssertEqual(object["event"] as? String, "meeting-saved")
        XCTAssertEqual(object["app"] as? String, "zoom")
        XCTAssertEqual(object["duration_s"] as? Int, 6120)
        XCTAssertEqual(object["complete"] as? Bool, false)
        XCTAssertEqual(object["recovered"] as? Bool, false)
        XCTAssertEqual(object["gaps"] as? [[Double]], [[41.2, 63.0]])
        XCTAssertEqual(object["folder"] as? String, dir.path)
    }

    func testTheEnvironmentMirrorsThePayload() {
        let env = event().environment()
        XCTAssertEqual(env["ANDREW_EVENT"], "meeting-saved")
        XCTAssertEqual(env["ANDREW_TRANSCRIPT"], dir.appendingPathComponent("t.md").path)
        XCTAssertEqual(env["ANDREW_FOLDER"], dir.path)
        XCTAssertEqual(env["ANDREW_APP"], "zoom")
        XCTAssertEqual(env["ANDREW_DURATION_S"], "6120")
        XCTAssertEqual(env["ANDREW_COMPLETE"], "false")
        XCTAssertEqual(env["ANDREW_GAPS"], "[[41.2,63.0]]")
        XCTAssertEqual(env["ANDREW_RECOVERED"], "false")
        XCTAssertNotNil(env["ANDREW_STARTED_AT"])
    }

    func testAScriptThatExitsZeroSucceedsAndItsOutputIsLogged() async throws {
        let script = try write(script: """
            #!/bin/sh
            cat
            echo "app=$ANDREW_APP arg=$1"
            exit 0
            """)
        let log = dir.appendingPathComponent("logs/hooks.log")
        let run = await HookRunner(logURL: log).run(executable: script, event: event())

        XCTAssertEqual(run.outcome, .succeeded)
        let logged = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(logged.contains("\"event\" : \"meeting-saved\""))
        XCTAssertTrue(logged.contains("app=zoom arg=\(dir.appendingPathComponent("t.md").path)"))
        XCTAssertTrue(logged.contains("=== exit 0 ==="))
    }

    func testANonZeroExitIsAFailureWithTheCode() async throws {
        let script = try write(script: "#!/bin/sh\necho oops >&2\nexit 3\n")
        let run = await HookRunner(logURL: dir.appendingPathComponent("hooks.log"))
            .run(executable: script, event: event())
        XCTAssertEqual(run.outcome, .failed(exitCode: 3))
        XCTAssertEqual(run.outcome.label, "exit 3")
    }

    func testAMissingExecutableCannotLaunch() async {
        let run = await HookRunner(logURL: dir.appendingPathComponent("hooks.log"))
            .run(executable: dir.appendingPathComponent("nope.sh"), event: event())
        guard case .couldNotLaunch = run.outcome else {
            return XCTFail("expected couldNotLaunch, got \(run.outcome)")
        }
    }

    // MARK: -

    private func event() -> MeetingSavedEvent {
        MeetingSavedEvent(
            transcript: dir.appendingPathComponent("t.md"),
            app: "zoom",
            startedAt: Date(timeIntervalSince1970: 1_787_000_000),
            durationS: 6120,
            complete: false,
            gaps: [[41.2, 63.0]],
            recovered: false
        )
    }

    private func write(script: String) throws -> URL {
        let url = dir.appendingPathComponent("hook.sh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
