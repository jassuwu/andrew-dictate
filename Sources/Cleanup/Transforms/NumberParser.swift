import Foundation

struct NumberParser: TranscriptTransform {
    private static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4,
        "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
    ]
    private static let teens: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
        "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    private static let numberWordPattern = (
        Array(units.keys)
            + Array(teens.keys)
            + Array(tens.keys)
            + ["hundred", "thousand", "million"]
    )
        .sorted { $0.count > $1.count }
        .joined(separator: "|")

    private let expression: NSRegularExpression

    init() {
        expression = try! NSRegularExpression(
            pattern: #"""
            (?<![\p{L}\p{N}_])
            (
              (?:(?:\#(Self.numberWordPattern))(?:[\s-]+(?:and[\s-]+)?)?)*
              (?:\#(Self.numberWordPattern))
            )
            (?:\s+(dollars?|rupees?|percent|percentage))?
            (?![\p{L}\p{N}_])
            """#,
            options: [.caseInsensitive, .allowCommentsAndWhitespace]
        )
    }

    func apply(_ transcript: String) -> String {
        expression.replacingMatches(in: transcript) { match in
            guard let spokenNumber = transcript.substring(
                with: match.range(at: 1)
            ),
            let value = parse(spokenNumber) else {
                return nil
            }
            let suffix = transcript.substring(with: match.range(at: 2))?
                .lowercased()

            switch suffix {
            case "dollar", "dollars":
                return "$\(value)"
            case "rupee", "rupees":
                return "₹\(value)"
            case "percent", "percentage":
                return "\(value)%"
            default:
                return String(value)
            }
        }
    }

    private func parse(_ spokenNumber: String) -> Int? {
        let rawWords = spokenNumber
            .lowercased()
            .split { $0.isWhitespace || $0 == "-" }
            .map(String.init)
        guard !rawWords.isEmpty,
              rawWords.first != "and",
              rawWords.last != "and" else {
            return nil
        }

        for (index, word) in rawWords.enumerated() where word == "and" {
            guard index > 0,
                  index + 1 < rawWords.count,
                  rawWords[index - 1] != "and",
                  rawWords[index + 1] != "and" else {
                return nil
            }
        }

        let words = rawWords.filter { $0 != "and" }
        var total = 0
        var group: [String] = []
        var previousScale = Int.max

        for word in words {
            let scale: Int?
            switch word {
            case "million":
                scale = 1_000_000
            case "thousand":
                scale = 1_000
            default:
                scale = nil
            }

            guard let scale else {
                group.append(word)
                continue
            }
            guard scale < previousScale,
                  let groupValue = parseGroup(group),
                  groupValue > 0 else {
                return nil
            }
            total += groupValue * scale
            previousScale = scale
            group.removeAll(keepingCapacity: true)
        }

        guard let remainder = parseGroup(group) else {
            return nil
        }
        total += remainder
        return total <= 999_999_999 ? total : nil
    }

    private func parseGroup(_ words: [String]) -> Int? {
        guard !words.isEmpty else {
            return 0
        }
        if words == ["zero"] {
            return 0
        }
        guard !words.contains("zero") else {
            return nil
        }

        var cursor = 0
        var value = 0
        if words.count >= 2,
           let hundreds = Self.units[words[0]],
           hundreds > 0,
           words[1] == "hundred" {
            value = hundreds * 100
            cursor = 2
        } else if words.first == "hundred" {
            return nil
        }

        let remainder = Array(words.dropFirst(cursor))
        switch remainder.count {
        case 0:
            return value
        case 1:
            if let unit = Self.units[remainder[0]], unit > 0 {
                return value + unit
            }
            if let teen = Self.teens[remainder[0]] {
                return value + teen
            }
            if let ten = Self.tens[remainder[0]] {
                return value + ten
            }
            return nil
        case 2:
            guard let ten = Self.tens[remainder[0]],
                  let unit = Self.units[remainder[1]],
                  unit > 0 else {
                return nil
            }
            return value + ten + unit
        default:
            return nil
        }
    }
}
