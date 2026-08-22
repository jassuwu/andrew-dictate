import Foundation

/// One thing you said, transcribed, kept.
///
/// ADR 0022 names this as the first of the app's two durable nouns. It holds
/// *your own* speech, which is why it may be kept indefinitely; a meeting
/// recording holds other people's and is a different type with different rules
/// (ticket 009).
///
/// Both the heard and the inserted text are kept. Holding only the inserted
/// text would be smaller and would throw away the one thing that can fix the
/// app's most frequent failure — ticket 004 found the top wince is the engine
/// mishearing names and identifiers, and a dictionary entry's `wrong` side has
/// to be *what the engine produced*.
///
/// What is deliberately absent: the app you dictated into. It would be useful
/// and it is a log of which applications you use and when, which is a
/// surveillance-shaped record this product has no business keeping.
struct Dictation: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let startedAt: Date
    /// Raw engine output, before any cleanup.
    let heard: String
    /// What actually reached the cursor.
    let inserted: String
    let engine: String
    /// Key-up to inserted. Nil when the timeline did not complete.
    /// This is also what gives ticket 008 a latency sample that survives a
    /// quit, which the in-memory ring never could.
    let keyUpToInsertedMilliseconds: Double?

    init(
        id: UUID = UUID(),
        startedAt: Date,
        heard: String,
        inserted: String,
        engine: String,
        keyUpToInsertedMilliseconds: Double? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.heard = heard
        self.inserted = inserted
        self.engine = engine
        self.keyUpToInsertedMilliseconds = keyUpToInsertedMilliseconds
    }
}
