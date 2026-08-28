import Foundation

/// which words a stage added or removed, so the pipe can show its work.
/// word-level LCS: small inputs (a dictation), no need for anything cleverer.
enum WordDiff {
    enum Change: Equatable, Sendable {
        case same
        case added
        case removed
    }

    struct Token: Equatable, Sendable {
        let text: String
        let change: Change
    }

    static func diff(_ old: String, _ new: String) -> [Token] {
        let a = words(old)
        let b = words(new)
        guard !a.isEmpty else {
            return b.map { Token(text: $0, change: .added) }
        }
        guard !b.isEmpty else {
            return a.map { Token(text: $0, change: .removed) }
        }

        // lcs table, then walk it forward so the output keeps reading order.
        var table = Array(
            repeating: Array(repeating: 0, count: b.count + 1),
            count: a.count + 1
        )
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j]
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }

        var tokens: [Token] = []
        var i = 0
        var j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                tokens.append(Token(text: a[i], change: .same))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                tokens.append(Token(text: a[i], change: .removed))
                i += 1
            } else {
                tokens.append(Token(text: b[j], change: .added))
                j += 1
            }
        }
        while i < a.count {
            tokens.append(Token(text: a[i], change: .removed))
            i += 1
        }
        while j < b.count {
            tokens.append(Token(text: b[j], change: .added))
            j += 1
        }
        return tokens
    }

    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
