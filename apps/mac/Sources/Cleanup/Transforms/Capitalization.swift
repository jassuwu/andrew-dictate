import Foundation

struct Capitalization: TranscriptTransform {
    func apply(_ transcript: String) -> String {
        let characters = Array(transcript)
        var output = ""
        var shouldCapitalize = true

        for (index, character) in characters.enumerated() {
            if shouldCapitalize, character.isLetter {
                output += String(character).uppercased()
                shouldCapitalize = false
            } else {
                output.append(character)
                if character.isLetter || character.isNumber {
                    shouldCapitalize = false
                }
            }

            if character == "\n" {
                shouldCapitalize = true
            } else if character == "?" || character == "!" {
                shouldCapitalize = true
            } else if character == ".",
                      isTerminalPeriod(at: index, in: characters) {
                shouldCapitalize = true
            }
        }
        return output
    }

    private func isTerminalPeriod(
        at index: Int,
        in characters: [Character]
    ) -> Bool {
        guard index + 1 < characters.count else {
            return true
        }
        var cursor = index + 1
        while cursor < characters.count,
              characters[cursor] == "\"" {
            cursor += 1
        }
        return cursor == characters.count
            || characters[cursor].isWhitespace
    }
}
