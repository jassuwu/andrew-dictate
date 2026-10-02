import XCTest

/// the press log's one line per press: what the unified log keeps and what
/// "copy diagnostics" hands over, so it is pinned word for word.
final class PressLogTests: XCTestCase {
    private let kolkata = TimeZone(identifier: "Asia/Kolkata")!
    /// 2026-10-02 12:22:31 in kolkata.
    private let noonish = Date(timeIntervalSince1970: 1_790_923_951)

    func testADeliveredPressIsOneLineOfEveryStage() {
        let record = PressRecord(
            outcome: .delivered,
            startedAt: noonish,
            mic: MicDescription(name: "AirPods Pro", transport: .bluetooth),
            samples: 19_200,
            peak: 0.41234,
            words: 4,
            stages: PressRecord.Stages(
                firstBuffer: 42,
                keyUp: 1_203,
                samplesReady: 1_210,
                transcriptReady: 1_290,
                cleaned: 1_292,
                pastePosted: 1_301,
                pasteCompleted: 1_612,
                ended: 1_612
            ),
            engine: "v2",
            capped: false,
            retry: false,
            mainStallMs: nil
        )

        let expected: [String] = [
            "at=2026-10-02T12:22:31+05:30 outcome=delivered",
            "mic=\"AirPods Pro\" transport=bluetooth",
            "first_buffer_ms=42 key_up_ms=1203 samples_ready_ms=1210",
            "transcript_ms=1290 cleaned_ms=1292 paste_posted_ms=1301",
            "paste_done_ms=1612 end_ms=1612",
            "samples=19200 peak=0.4123 words=4 engine=v2",
        ]
        XCTAssertEqual(
            record.line(in: kolkata),
            expected.joined(separator: " ")
        )
    }

    /// a refusal never reached the mic, so the line is short — and the
    /// flags only appear when they are true.
    func testARefusedPressSaysWhyAndLittleElse() {
        let record = PressRecord(
            outcome: .refused(.meetingRunning),
            startedAt: noonish,
            mic: nil,
            samples: nil,
            peak: nil,
            words: nil,
            stages: PressRecord.Stages(ended: 0),
            engine: "v3",
            capped: false,
            retry: false,
            mainStallMs: nil
        )

        XCTAssertEqual(
            record.line(in: kolkata),
            "at=2026-10-02T12:22:31+05:30 outcome=refused why=meeting-running end_ms=0 engine=v3"
        )
    }

    // MARK: - copy diagnostics

    /// what a friend pastes to jass: who is running what, then the presses
    /// as the log wrote them, newest last.
    func testDiagnosticsAreTheSetupThenTheLastPresses() {
        let presses = [
            refused(.modelNotReady, endingAt: 0),
            refused(.noMicrophone, endingAt: 1),
        ]

        XCTAssertEqual(
            PressDiagnostics.text(
                setup: setup,
                presses: presses,
                timeZone: kolkata
            ),
            [
                "Andrew Dictate 0.9.4 (6)",
                "macOS 27.0.1",
                "speech model v2",
                "default mic: MacBook Pro Microphone (built-in)",
                "last 2 presses, newest last:",
                "at=2026-10-02T12:22:31+05:30 outcome=refused why=model-not-ready end_ms=0 engine=v2",
                "at=2026-10-02T12:22:31+05:30 outcome=refused why=no-microphone end_ms=1 engine=v2",
            ].joined(separator: "\n")
        )
    }

    /// fifty is enough to see a pattern and short enough to paste anywhere.
    func testDiagnosticsCarryOnlyTheNewestFifty() {
        let presses = (0..<60).map { refused(.modelNotReady, endingAt: $0) }

        let lines = PressDiagnostics.text(
            setup: setup,
            presses: presses,
            timeZone: kolkata
        ).split(separator: "\n")

        XCTAssertEqual(lines.count, 5 + 50)
        XCTAssertEqual(lines[4], "last 50 presses, newest last:")
        XCTAssertTrue(lines[5].hasSuffix("end_ms=10 engine=v2"))
        XCTAssertTrue(lines.last!.hasSuffix("end_ms=59 engine=v2"))
    }

    func testDiagnosticsWithNothingToShowSaySo() {
        var bare = setup
        bare.defaultMic = nil

        XCTAssertEqual(
            PressDiagnostics.text(setup: bare, presses: [], timeZone: kolkata),
            [
                "Andrew Dictate 0.9.4 (6)",
                "macOS 27.0.1",
                "speech model v2",
                "default mic: none",
                "no presses yet",
            ].joined(separator: "\n")
        )
    }

    /// a log that will not read is not an empty one.
    func testAnUnreadableLogDoesNotPassForAnEmptyOne() {
        let text = PressDiagnostics.text(setup: setup, presses: nil, timeZone: kolkata)

        XCTAssertTrue(text.hasSuffix("\ncouldn't read the press log"), text)
    }

    func testOnePressIsNotCalledPresses() {
        let text = PressDiagnostics.text(
            setup: setup,
            presses: [refused(.noMicrophone, endingAt: 0)],
            timeZone: kolkata
        )

        XCTAssertTrue(text.contains("\nlast press:\n"), text)
    }

    private var setup: PressDiagnostics.Setup {
        PressDiagnostics.Setup(
            appVersion: "0.9.4",
            build: "6",
            macOS: "27.0.1",
            engine: "v2",
            defaultMic: MicDescription(name: "MacBook Pro Microphone", transport: .builtIn)
        )
    }

    private func refused(
        _ why: PressRecord.Refusal,
        endingAt end: Int
    ) -> PressRecord {
        PressRecord(
            outcome: .refused(why),
            startedAt: noonish,
            mic: nil,
            samples: nil,
            peak: nil,
            words: nil,
            stages: PressRecord.Stages(ended: end),
            engine: "v2",
            capped: false,
            retry: false,
            mainStallMs: nil
        )
    }

    // MARK: - the line

    /// a take the mic change ended, not the finger, says so like the cap.
    func testATakeTheMicChangeEndedSaysSo() {
        let record = PressRecord(
            outcome: .delivered,
            startedAt: noonish,
            mic: nil,
            samples: nil,
            peak: nil,
            words: nil,
            stages: PressRecord.Stages(ended: 900),
            engine: "v2",
            capped: false,
            micChanged: true,
            retry: false,
            mainStallMs: nil
        )

        XCTAssertEqual(
            record.line(in: kolkata),
            "at=2026-10-02T12:22:31+05:30 outcome=delivered end_ms=900 engine=v2 mic_changed=1"
        )
    }

    /// a mic that sent no sound is its own ending, not "heard nothing":
    /// the line names it, and the file reads it back.
    func testAMicThatSentNoSoundIsItsOwnOutcome() throws {
        let record = PressRecord(
            outcome: .noAudio,
            startedAt: noonish,
            mic: MicDescription(name: "AirPods Pro", transport: .bluetooth),
            samples: 9_600,
            peak: 0,
            words: nil,
            stages: PressRecord.Stages(keyUp: 600, samplesReady: 610, ended: 610),
            engine: "v2",
            capped: false,
            retry: false,
            mainStallMs: nil
        )

        XCTAssertEqual(
            record.line(in: kolkata),
            [
                "at=2026-10-02T12:22:31+05:30 outcome=no-audio",
                #"mic="AirPods Pro" transport=bluetooth"#,
                "key_up_ms=600 samples_ready_ms=610 end_ms=610 samples=9600 peak=0 engine=v2",
            ].joined(separator: " ")
        )
        let file = try JSONEncoder().encode(record)
        XCTAssertEqual(
            try JSONDecoder().decode(PressRecord.self, from: file).outcome,
            .noAudio
        )
    }

    /// a mic that sent almost nothing must not read as one that sent
    /// exactly nothing, and a quote in a device's name stays inside it.
    func testTheLineKeepsAFaintPeakAndAnAwkwardMicName() {
        let record = PressRecord(
            outcome: .heardNothing,
            startedAt: noonish,
            mic: MicDescription(name: "jass's \"desk\" mic", transport: .usb),
            samples: 8_000,
            peak: 0.000_123_4,
            words: 0,
            stages: PressRecord.Stages(ended: 600),
            engine: "v2",
            capped: true,
            retry: true,
            mainStallMs: 812
        )

        let expected: [String] = [
            "at=2026-10-02T12:22:31+05:30 outcome=heard-nothing",
            #"mic="jass's \"desk\" mic" transport=usb"#,
            "end_ms=600 samples=8000 peak=0.0001234 words=0 engine=v2",
            "capped=1 retry=1 main_stall_ms=812",
        ]
        XCTAssertEqual(
            record.line(in: kolkata),
            expected.joined(separator: " ")
        )
    }
}
