import Foundation

/// what "copy diagnostics" puts on the clipboard: who is running what, then
/// the last presses exactly as the log wrote them. plain text, so a friend
/// can paste it into any message — and safe to, because no record holds a
/// word of what was said.
enum PressDiagnostics {
    /// enough to see a pattern, short enough to paste anywhere.
    static let pressCount = 50

    struct Setup: Equatable, Sendable {
        var appVersion: String
        var build: String
        var macOS: String
        var engine: String
        /// what macOS would hand a new recording now, beside what each press
        /// actually got.
        var defaultMic: MicDescription?
    }

    static func text(
        setup: Setup,
        presses: [PressRecord],
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
        return lines.joined(separator: "\n")
    }
}
