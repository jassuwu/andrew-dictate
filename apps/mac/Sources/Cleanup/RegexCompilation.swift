import Foundation
import os

/// cleanup patterns are source literals, so a bad one is a typo in this
/// repo, not bad input. it should cost the one rule that owns it plus a log
/// line — never a crash mid-dictation, which is all `try!` could offer.
enum CleanupRegex {
    private static let logger = Logger(
        subsystem: "gg.jass.dictate",
        category: "cleanup"
    )

    static func compile(
        _ pattern: String,
        options: NSRegularExpression.Options = []
    ) -> NSRegularExpression? {
        do {
            return try NSRegularExpression(
                pattern: pattern,
                options: options
            )
        } catch {
            // public because the pattern is source, never transcript text.
            logger.error(
                "cleanup regex failed to compile, rule disabled: \(pattern, privacy: .public)"
            )
            return nil
        }
    }
}
