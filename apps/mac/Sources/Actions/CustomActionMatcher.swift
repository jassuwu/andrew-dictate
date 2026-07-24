import Foundation

enum CustomActionTriggerError: Error, Equatable, Sendable {
    case empty
    case invalidArgumentPlaceholder
}

struct CustomActionTriggerPattern: Equatable, Sendable {
    let normalizedPrefix: String
    let capturesArgument: Bool

    var normalizedKey: String {
        capturesArgument
            ? normalizedPrefix + " {arg}"
            : normalizedPrefix
    }
}

enum CustomActionMatcher {
    struct Match: Equatable, Sendable {
        let action: CustomAction
        let capturedArgument: String?
    }

    static func match(
        _ transcript: String,
        actions: [CustomAction]
    ) -> Match? {
        let normalizedTranscript = normalize(transcript)
        guard !normalizedTranscript.isEmpty else {
            return nil
        }

        for action in actions {
            guard let pattern = try? triggerPattern(for: action.trigger),
                  !pattern.capturesArgument,
                  normalizedTranscript == pattern.normalizedPrefix else {
                continue
            }
            return Match(action: action, capturedArgument: nil)
        }

        for action in actions {
            guard let pattern = try? triggerPattern(for: action.trigger),
                  pattern.capturesArgument else {
                continue
            }

            let requiredPrefix = pattern.normalizedPrefix + " "
            guard normalizedTranscript.hasPrefix(requiredPrefix) else {
                continue
            }

            let argument = String(
                normalizedTranscript.dropFirst(requiredPrefix.count)
            )
            guard !argument.isEmpty else {
                continue
            }
            return Match(action: action, capturedArgument: argument)
        }

        return nil
    }

    static func normalize(_ value: String) -> String {
        var words: [String] = []
        var word = ""

        for character in value.lowercased() {
            if character.isLetter || character.isNumber {
                word.append(character)
            } else if !word.isEmpty {
                words.append(word)
                word = ""
            }
        }

        if !word.isEmpty {
            words.append(word)
        }
        return words.joined(separator: " ")
    }

    static func triggerPattern(
        for trigger: String
    ) throws -> CustomActionTriggerPattern {
        let trimmed = trigger.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty else {
            throw CustomActionTriggerError.empty
        }

        let lowered = trimmed.lowercased()
        let placeholder = CustomActionPayload.argumentPlaceholder
        let placeholderCount = lowered.components(
            separatedBy: placeholder
        ).count - 1

        if placeholderCount == 0 {
            guard !lowered.contains("{"), !lowered.contains("}") else {
                throw CustomActionTriggerError.invalidArgumentPlaceholder
            }
            let normalized = normalize(trimmed)
            guard !normalized.isEmpty else {
                throw CustomActionTriggerError.empty
            }
            return CustomActionTriggerPattern(
                normalizedPrefix: normalized,
                capturesArgument: false
            )
        }

        guard placeholderCount == 1,
              lowered.hasSuffix(placeholder) else {
            throw CustomActionTriggerError.invalidArgumentPlaceholder
        }

        let placeholderStart = lowered.index(
            lowered.endIndex,
            offsetBy: -placeholder.count
        )
        let rawPrefix = String(trimmed[..<placeholderStart])
        guard rawPrefix.last?.isWhitespace == true else {
            throw CustomActionTriggerError.invalidArgumentPlaceholder
        }

        let normalizedPrefix = normalize(rawPrefix)
        guard !normalizedPrefix.isEmpty else {
            throw CustomActionTriggerError.invalidArgumentPlaceholder
        }
        return CustomActionTriggerPattern(
            normalizedPrefix: normalizedPrefix,
            capturesArgument: true
        )
    }
}
