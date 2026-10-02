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
