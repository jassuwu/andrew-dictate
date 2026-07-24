import Foundation

enum ActionType: String, Codable, CaseIterable, Identifiable, Sendable {
    case open
    case url
    case shortcut
    case shell
    case type
    case ask

    var id: Self {
        self
    }
}

struct CustomAction: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var trigger: String
    var type: ActionType
    var payload: String
    var alwaysAllow: Bool

    init(
        id: UUID = UUID(),
        trigger: String,
        type: ActionType,
        payload: String,
        alwaysAllow: Bool = false
    ) {
        self.id = id
        self.trigger = trigger
        self.type = type
        self.payload = payload
        self.alwaysAllow = alwaysAllow
    }
}

struct CustomActionInvocation: Equatable, Sendable {
    let action: CustomAction
    let capturedArgument: String?
}

enum CustomActionPayload {
    static let argumentPlaceholder = "{arg}"

    static func raw(
        _ payload: String,
        argument: String?
    ) -> String {
        guard let argument else {
            return payload
        }
        return payload.replacingOccurrences(
            of: argumentPlaceholder,
            with: argument
        )
    }

    static func url(
        _ payload: String,
        argument: String?
    ) -> String? {
        guard let argument else {
            return payload
        }

        let unreserved = CharacterSet(
            charactersIn:
                "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
                + "abcdefghijklmnopqrstuvwxyz"
                + "0123456789-._~"
        )
        guard let encodedArgument = argument.addingPercentEncoding(
            withAllowedCharacters: unreserved
        ) else {
            return nil
        }

        return payload.replacingOccurrences(
            of: argumentPlaceholder,
            with: encodedArgument
        )
    }

    static func shell(
        _ payload: String,
        argument: String?
    ) -> String {
        guard let argument else {
            return payload
        }
        return payload.replacingOccurrences(
            of: argumentPlaceholder,
            with: shellEscapeSingleQuoted(argument)
        )
    }
}
