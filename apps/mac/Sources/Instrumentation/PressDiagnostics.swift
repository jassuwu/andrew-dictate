import Foundation

/// what "copy diagnostics" puts on the clipboard: who is running what, then
/// the last presses and the last meetings exactly as their logs wrote them.
/// plain text, so a friend can paste it into any message — and safe to,
/// because no record holds a word of what was said.
enum PressDiagnostics {
    /// enough to see a pattern, short enough to paste anywhere.
    static let pressCount = 50
    /// a meeting is a line as long as a press's and rarer by a hundred.
    static let meetingCount = 20

    struct Setup: Equatable, Sendable {
        var appVersion: String
        var build: String
        var macOS: String
        var engine: String
        /// what macOS would hand a new recording now, beside what each press
        /// actually got.
        var defaultMic: MicDescription?
    }

    /// `presses` is nil when the log would not read — which has to say
    /// so, not pass for a mac that never pressed the key. `meetings` is the
    /// same, and one log that will not read leaves the other in.
    static func text(
        setup: Setup,
        presses: [PressRecord]?,
        meetings: [MeetingRecord]? = [],
        timeZone: TimeZone = .current
    ) -> String {
        var lines = [
            "Andrew Dictate \(setup.appVersion) (\(setup.build))",
            "macOS \(setup.macOS)",
            "speech model \(setup.engine)",
            "default mic: "
                + (setup.defaultMic.map {
                    "\($0.name) (\($0.transport.rawValue))"
                } ?? "none"),
        ]

        if let presses {
            let newest = presses.suffix(pressCount)
            if newest.isEmpty {
                lines.append("no presses yet")
            } else {
                lines.append(
                    newest.count == 1
                        ? "last press:"
                        : "last \(newest.count) presses, newest last:"
                )
                lines += newest.map { $0.line(in: timeZone) }
            }
        } else {
            lines.append("couldn't read the press log")
        }

        // a mac that never recorded a meeting is not told so: most of the
        // people who paste this only dictate.
        if let meetings {
            let newest = meetings.suffix(meetingCount)
            if !newest.isEmpty {
                lines.append(
                    newest.count == 1
                        ? "last meeting:"
                        : "last \(newest.count) meetings, newest last:"
                )
                lines += newest.map { $0.line(in: timeZone) }
            }
        } else {
            lines.append("couldn't read the meeting records")
        }
        return lines.joined(separator: "\n")
    }
}
