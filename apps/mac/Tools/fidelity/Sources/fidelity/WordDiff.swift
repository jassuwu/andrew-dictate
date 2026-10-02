import Foundation

/// the one question compare asks of two transcripts: same words or not, and
/// if not, which. nothing is normalised but whitespace, so a comma, a capital
/// or a hyphen that differs is a difference, which is the point: the app
/// would have typed it.
enum WordDiff {
    enum Edit: Equatable {
        case same(String)
        /// in the batch text only.
        case removed(String)
        /// in the streaming text only.
        case added(String)
    }

    /// words split on runs of whitespace. line breaks and double spaces are
    /// the only things that vanish.
    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// longest common subsequence over words. the transcripts are a few
    /// hundred words, so the full table is cheap.
    static func edits(from batch: [String], to streaming: [String]) -> [Edit] {
        let n = batch.count
        let m = streaming.count
        let width = m + 1

        // lcs[i * width + j] is the common length of batch[i...] and streaming[j...]
        var lcs = [Int32](repeating: 0, count: (n + 1) * width)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i * width + j] =
                    batch[i] == streaming[j]
                    ? lcs[(i + 1) * width + j + 1] + 1
                    : max(lcs[(i + 1) * width + j], lcs[i * width + j + 1])
            }
        }

        var edits: [Edit] = []
        var i = 0
        var j = 0
        while i < n, j < m {
            if batch[i] == streaming[j] {
                edits.append(.same(batch[i]))
                i += 1
                j += 1
            } else if lcs[(i + 1) * width + j] >= lcs[i * width + j + 1] {
                edits.append(.removed(batch[i]))
                i += 1
            } else {
                edits.append(.added(streaming[j]))
                j += 1
            }
        }
        while i < n {
            edits.append(.removed(batch[i]))
            i += 1
        }
        while j < m {
            edits.append(.added(streaming[j]))
            j += 1
        }
        return edits
    }

    struct Summary: Equatable {
        let removed: Int
        let added: Int
        var isEqual: Bool { removed == 0 && added == 0 }
    }

    static func summary(of edits: [Edit]) -> Summary {
        var removed = 0
        var added = 0
        for edit in edits {
            switch edit {
            case .same: break
            case .removed: removed += 1
            case .added: added += 1
            }
        }
        return Summary(removed: removed, added: added)
    }

    /// the differences with a few words of context each side, one hunk per
    /// line. `[-word-]` is in batch only, `{+word+}` in streaming only; `...`
    /// marks where the line is cut out of agreeing text.
    static func render(_ edits: [Edit], context: Int = 5) -> [String] {
        var show = [Bool](repeating: false, count: edits.count)
        for (index, edit) in edits.enumerated() {
            if case .same = edit { continue }
            for near in max(0, index - context)...min(edits.count - 1, index + context) {
                show[near] = true
            }
        }

        var lines: [String] = []
        var index = 0
        while index < edits.count {
            guard show[index] else {
                index += 1
                continue
            }
            let start = index
            var parts: [String] = []
            while index < edits.count, show[index] {
                switch edits[index] {
                case .same(let word): parts.append(word)
                case .removed(let word): parts.append("[-\(word)-]")
                case .added(let word): parts.append("{+\(word)+}")
                }
                index += 1
            }
            let head = start > 0 ? "... " : ""
            let tail = index < edits.count ? " ..." : ""
            lines.append(head + parts.joined(separator: " ") + tail)
        }
        return lines
    }
}
