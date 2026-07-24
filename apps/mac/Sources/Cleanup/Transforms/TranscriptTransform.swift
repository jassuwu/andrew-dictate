import Foundation

protocol TranscriptTransform {
    func apply(_ transcript: String) -> String
}

extension String {
    var fullNSRange: NSRange {
        NSRange(startIndex..<endIndex, in: self)
    }

    func substring(with range: NSRange) -> String? {
        guard let range = Range(range, in: self) else {
            return nil
        }
        return String(self[range])
    }
}

extension NSRegularExpression {
    func replacingMatches(
        in input: String,
        using replacement: (NSTextCheckingResult) -> String?
    ) -> String {
        var output = input
        let matches = matches(
            in: input,
            range: input.fullNSRange
        )

        for match in matches.reversed() {
            guard let range = Range(match.range, in: output),
                  let replacement = replacement(match) else {
                continue
            }
            output.replaceSubrange(range, with: replacement)
        }
        return output
    }
}
