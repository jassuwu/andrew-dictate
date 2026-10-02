import Foundation

extension MeetingRecord {
    /// the meeting as one `key=value` line: what the unified log keeps and
    /// what "copy diagnostics" hands over. what a meeting never had is left
    /// out rather than written as a blank, and the flags only appear when
    /// true, so a meeting that kept nothing reads short and a saved one
    /// reads whole.
    func line(in timeZone: TimeZone = .current) -> String {
        var fields = [
            "at=\(LogLine.timestamp(startedAt, in: timeZone))",
            "outcome=\(outcome.name)",
        ]
        if let why = outcome.why {
            fields.append("why=\(why)")
        }
        fields.append("app=\(LogLine.quoted(app))")
        fields.append("model=\(model)")
        fields.append("duration_s=\(Self.plain(durationS))")
        fields.append("gaps=\(gaps)")
        fields.append("lost_s=\(Self.plain(gapsLostS))")
        fields.append("you_turns=\(you.turns)")
        fields.append("you_words=\(you.words)")
        fields.append("them_turns=\(them.turns)")
        fields.append("them_words=\(them.words)")
        if let toDiskS {
            fields.append("to_disk_s=\(Self.plain(toDiskS))")
        }
        if recovered {
            fields.append("recovered=1")
        }
        if !events.isEmpty {
            let named = events.map { "\($0.label.rawValue)@\(Self.plain($0.atS))" }
            fields.append("events=\(named.joined(separator: ","))")
        }
        if let decoding {
            fields.append("decoded_you=\(decoding.decodedYou)")
            fields.append("decoded_them=\(decoding.decodedThem)")
            fields.append("failed=\(decoding.failed)")
            fields.append("most_behind_s=\(Self.plain(decoding.mostBehindS))")
            fields.append("last_behind_s=\(Self.plain(decoding.lastBehindS))")
        }
        return fields.joined(separator: " ")
    }

    /// a tenth when there is one, nothing when there is not: `3728`, `4.2`.
    private static func plain(_ seconds: Double) -> String {
        seconds == seconds.rounded() ? String(Int(seconds)) : String(format: "%.1f", seconds)
    }
}
