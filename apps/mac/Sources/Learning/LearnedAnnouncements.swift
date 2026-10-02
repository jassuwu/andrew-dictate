/// `learned: <word>`, said once and never lost.
///
/// the pill can't always speak: a take, a meeting or another pill may have
/// it. an entry learned then waits for a moment it can — past the menu's
/// two-minute undo if it comes to that — so a word never goes into your
/// dictionary unannounced. one you took out while it waited goes unsaid.
struct LearnedAnnouncements {
    /// in the order learned.
    private var waiting: [DictionaryEntry] = []

    mutating func learned(_ entry: DictionaryEntry) {
        waiting.append(entry)
    }

    /// the pill to show now, or nil. `canSay` false keeps everything
    /// waiting. everything still in the dictionary is said in one pill: a
    /// second would replace the first before it could be read.
    mutating func due(
        canSay: Bool,
        stillThere: (DictionaryEntry) -> Bool
    ) -> String? {
        guard canSay, !waiting.isEmpty else {
            return nil
        }
        let words = waiting.filter(stillThere).map(\.right)
        waiting = []
        guard !words.isEmpty else {
            return nil
        }
        return "learned: " + words.joined(separator: ", ")
    }
}
