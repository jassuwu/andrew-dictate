import Foundation

/// one thing to read aloud. `text` is a real dictation of the developer's, so
/// the file holding these is as private as the history it came from.
struct Prompt: Codable {
    let number: Int
    let words: Int
    let startedAt: String?
    let text: String
}

enum Passages {
    /// the range worth reading. 60 words is about 25 seconds of speech, long
    /// enough to cross a window boundary or two; 250 is tiring to read aloud.
    static let wordRange = 60...250
    static let defaultCount = 20

    static func run(_ arguments: [String]) throws {
        var count = defaultCount
        var force = false

        var remaining = arguments[...]
        while let argument = remaining.popFirst() {
            switch argument {
            case "--count":
                guard let value = remaining.popFirst(), let parsed = Int(value), parsed > 0 else {
                    throw FidelityError("--count takes a positive number")
                }
                count = parsed
            case "--force":
                force = true
            default:
                throw FidelityError("passages: unknown argument '\(argument)'")
            }
        }

        if FileManager.default.fileExists(atPath: Folders.prompts.path), !force {
            throw FidelityError(
                "prompts already exist at \(Folders.prompts.path). "
                    + "new prompts would not match the recordings made from them; pass --force to replace."
            )
        }

        let history = try readHistory()
        let candidates = distinct(history.filter { wordRange.contains($0.words) })
        let chosen = spread(candidates, count: count)
        guard !chosen.isEmpty else {
            throw FidelityError(
                "no dictation in \(Folders.history.path) has \(wordRange.lowerBound) to "
                    + "\(wordRange.upperBound) words. dictate a few longer things first."
            )
        }

        let prompts = chosen.enumerated().map { index, entry in
            Prompt(number: index + 1, words: entry.words, startedAt: entry.startedAt, text: entry.text)
        }

        try Folders.makeRecordings()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(prompts).write(to: Folders.prompts, options: .atomic)
        // a permanent record of what its owner said, same as the archive it
        // was drawn from.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Folders.prompts.path)

        let lengths = prompts.map(\.words)
        print(
            "wrote \(prompts.count) prompts (\(lengths.min() ?? 0) to \(lengths.max() ?? 0) words) "
                + "from \(candidates.count) distinct candidates to \(Folders.prompts.path)"
        )
        if prompts.count < count {
            print("asked for \(count); the history only has \(prompts.count) distinct dictations in range.")
        }
        print("next: fidelity record 1")
    }

    // MARK: - history

    struct Entry {
        let text: String
        let words: Int
        let startedAt: String?
    }

    private struct HistoryLine: Decodable {
        let inserted: String?
        let startedAt: String?
    }

    /// oldest first, as the file is. a line that will not decode is skipped,
    /// the same as the app's own reader does.
    static func readHistory() throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: Folders.history.path) else {
            throw FidelityError("no dictation history at \(Folders.history.path)")
        }
        let decoder = JSONDecoder()
        return try Data(contentsOf: Folders.history)
            .split(separator: 0x0A, omittingEmptySubsequences: true)
            .compactMap { try? decoder.decode(HistoryLine.self, from: Data($0)) }
            .compactMap { line -> Entry? in
                guard let text = line.inserted else { return nil }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                // an address or a link is a miserable thing to read aloud.
                guard !trimmed.contains("://") else { return nil }
                return Entry(text: trimmed, words: words(in: trimmed).count, startedAt: line.startedAt)
            }
    }

    static func words(in text: String) -> [Substring] {
        text.split(whereSeparator: \.isWhitespace)
    }

    // MARK: - choosing

    /// drops repeats: the same words said twice, which dictation history is
    /// full of (a retry after a false start), and near-copies that share most
    /// of their vocabulary. the first one stays.
    static func distinct(_ entries: [Entry]) -> [Entry] {
        var kept: [(entry: Entry, vocabulary: Set<String>)] = []
        for entry in entries {
            let vocabulary = Set(words(in: entry.text.lowercased()).map(String.init))
            let isCopy = kept.contains { other in
                let overlap = vocabulary.intersection(other.vocabulary).count
                let union = vocabulary.union(other.vocabulary).count
                return union > 0 && Double(overlap) / Double(union) >= 0.7
            }
            if !isCopy {
                kept.append((entry, vocabulary))
            }
        }
        return kept.map(\.entry)
    }

    /// `count` entries whose lengths are as evenly spread across the range as
    /// the history allows: aim at evenly spaced word counts and take the
    /// nearest dictation not yet taken. the long targets go first, being the
    /// scarce ones. the result is ordered shortest to longest, so prompt 1 is
    /// the easy one to start on.
    static func spread(_ entries: [Entry], count: Int) -> [Entry] {
        guard entries.count > count else {
            return entries.sorted { $0.words < $1.words }
        }
        guard count > 1 else {
            return Array(entries.prefix(1))
        }

        let low = Double(wordRange.lowerBound)
        let high = Double(wordRange.upperBound)
        let targets = (0..<count).map { low + (high - low) * Double($0) / Double(count - 1) }

        var available = entries
        var chosen: [Entry] = []
        for target in targets.reversed() {
            guard let index = available.indices.min(by: {
                abs(Double(available[$0].words) - target) < abs(Double(available[$1].words) - target)
            }) else { break }
            chosen.append(available.remove(at: index))
        }
        return chosen.sorted { $0.words < $1.words }
    }
}
