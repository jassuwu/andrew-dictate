import Foundation

extension PressRecord {
    /// the press as one `key=value` line: what the unified log keeps and
    /// what "copy diagnostics" hands over. stages a press never reached are
    /// left out rather than written as blanks, and the flags only appear
    /// when true, so a refusal reads short and a delivery reads whole.
    func line(in timeZone: TimeZone = .current) -> String {
        var fields = [
            "at=\(Self.timestamp(startedAt, in: timeZone))",
            "outcome=\(outcome.name)",
        ]
        if let why = outcome.why {
            fields.append("why=\(why)")
        }
        if let mic {
            fields.append("mic=\(Self.quoted(mic.name))")
            fields.append("transport=\(mic.transport.rawValue)")
        }

        let numbers: [(String, Int?)] = [
            ("first_buffer_ms", stages.firstBuffer),
            ("key_up_ms", stages.keyUp),
            ("samples_ready_ms", stages.samplesReady),
            ("transcript_ms", stages.transcriptReady),
            ("cleaned_ms", stages.cleaned),
            ("paste_posted_ms", stages.pastePosted),
            ("paste_done_ms", stages.pasteCompleted),
            ("end_ms", stages.ended),
            ("samples", samples),
        ]
        for (key, value) in numbers {
            if let value {
                fields.append("\(key)=\(value)")
            }
        }
        // four significant figures, never rounded to zero: a mic that sent
        // almost nothing is a different failure from one that sent nothing.
        if let peak {
            fields.append("peak=\(String(format: "%.4g", Double(peak)))")
        }
        if let words {
            fields.append("words=\(words)")
        }
        fields.append("model=\(engine)")
        if capped {
            fields.append("capped=1")
        }
        if micChanged {
            fields.append("mic_changed=1")
        }
        if timedOut {
            fields.append("timed_out=1")
        }
        if retry {
            fields.append("retry=1")
        }
        if let mainStallMs {
            fields.append("main_stall_ms=\(mainStallMs)")
        }
        return fields.joined(separator: " ")
    }

    /// local time with its offset: a friend says "it broke at three", and
    /// the line has to be findable from that.
    private static func timestamp(_ date: Date, in timeZone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    /// a device names itself, so its name can hold anything a line can.
    private static func quoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(escaped)\""
    }
}
