import Foundation

struct Capitalization: TranscriptTransform {
    func apply(_ transcript: String) -> String {
        let characters = Array(transcript)
        var output = ""
        var shouldCapitalize = true

        for (index, character) in characters.enumerated() {
            // an address is not a sentence. capitalising the start of one
            // gives you Jass@jass.gg, which is nobody's email.
            if shouldCapitalize, isInsideAddress(at: index, in: characters) {
                output.append(character)
                shouldCapitalize = false
                continue
            }

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

    /// looks ahead over the token about to be capitalised: if it carries an
    /// @ or a scheme, it is an address and its own spelling is the correct one.
    private func isInsideAddress(
        at index: Int,
        in characters: [Character]
    ) -> Bool {
        var cursor = index
        var token = ""
        while cursor < characters.count,
              !characters[cursor].isWhitespace {
            token.append(characters[cursor])
            cursor += 1
        }
        return token.contains("@")
            || token.contains("://")
            || token.lowercased().hasPrefix("www.")
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
