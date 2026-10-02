import Foundation

/// the two things every `key=value` evidence line says the same way: when,
/// and anything a person or a device named. the press line and the meeting
/// line both read like one log.
enum LogLine {
    /// local time with its offset: a friend says "it broke at three", and
    /// the line has to be findable from that.
    static func timestamp(_ date: Date, in timeZone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    /// a device or an app names itself, so its name can hold anything a line
    /// can.
    static func quoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(escaped)\""
    }
}
