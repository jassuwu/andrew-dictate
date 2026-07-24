import Combine
import Foundation

enum CustomActionValidationError: LocalizedError, Equatable, Sendable {
    case emptyTrigger
    case invalidArgumentPlaceholder
    case duplicateTrigger
    case emptyPayload
    case missingArgumentPlaceholder
    case unexpectedArgumentPlaceholder
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .emptyTrigger:
            "enter a trigger"
        case .invalidArgumentPlaceholder:
            "{arg} must appear once at the end of the trigger"
        case .duplicateTrigger:
            "that trigger already exists"
        case .emptyPayload:
            "enter a payload"
        case .missingArgumentPlaceholder:
            "payload must contain {arg}"
        case .unexpectedArgumentPlaceholder:
            "payload has {arg}, but the trigger does not"
        case .invalidURL:
            "enter a valid url"
        }
    }
}

enum CustomActionValidator {
    static func validationError(
        for action: CustomAction,
        among actions: [CustomAction]
    ) -> CustomActionValidationError? {
        let pattern: CustomActionTriggerPattern
        do {
            pattern = try CustomActionMatcher.triggerPattern(
                for: action.trigger
            )
        } catch CustomActionTriggerError.empty {
            return .emptyTrigger
        } catch {
            return .invalidArgumentPlaceholder
        }

        if actions.contains(where: {
            guard $0.id != action.id,
                  let otherPattern = try? CustomActionMatcher.triggerPattern(
                      for: $0.trigger
                  ) else {
                return false
            }
            return otherPattern.normalizedKey == pattern.normalizedKey
        }) {
            return .duplicateTrigger
        }

        let payload = action.payload.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !payload.isEmpty else {
            return .emptyPayload
        }

        let containsArgument = action.payload.contains(
            CustomActionPayload.argumentPlaceholder
        )
        if pattern.capturesArgument, !containsArgument {
            return .missingArgumentPlaceholder
        }
        if !pattern.capturesArgument, containsArgument {
            return .unexpectedArgumentPlaceholder
        }

        if action.type == .url {
            let sampleArgument = pattern.capturesArgument
                ? "sample"
                : nil
            guard let urlString = CustomActionPayload.url(
                action.payload,
                argument: sampleArgument
            ),
            let url = URL(string: urlString),
            url.scheme?.isEmpty == false else {
                return .invalidURL
            }
        }

        return nil
    }

    static func validate(
        _ action: CustomAction,
        among actions: [CustomAction]
    ) throws {
        if let error = validationError(for: action, among: actions) {
            throw error
        }
    }

    static func validate(_ actions: [CustomAction]) throws {
        for action in actions {
            try validate(action, among: actions)
        }
    }
}

@MainActor
final class CustomActionStore: ObservableObject {
    @Published private(set) var actions: [CustomAction] = []

    let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        load()
    }

    @discardableResult
    func add(
        trigger: String,
        type: ActionType,
        payload: String,
        alwaysAllow: Bool = false
    ) throws -> CustomAction {
        let action = CustomAction(
            trigger: trigger,
            type: type,
            payload: payload,
            alwaysAllow: alwaysAllow
        )
        try add(action)
        return action
    }

    func add(_ action: CustomAction) throws {
        try CustomActionValidator.validate(action, among: actions)
        actions.append(action)
        save()
    }

    func update(_ action: CustomAction) throws {
        guard let index = actions.firstIndex(where: {
            $0.id == action.id
        }) else {
            return
        }

        try CustomActionValidator.validate(action, among: actions)
        actions[index] = action
        save()
    }

    func remove(id: UUID) {
        guard let index = actions.firstIndex(where: {
            $0.id == id
        }) else {
            return
        }
        actions.remove(at: index)
        save()
    }

    func remove(_ action: CustomAction) {
        remove(id: action.id)
    }

    func validationError(
        for action: CustomAction
    ) -> CustomActionValidationError? {
        CustomActionValidator.validationError(
            for: action,
            among: actions
        )
    }

    func importJSON(from sourceURL: URL) throws {
        let data = try Data(contentsOf: sourceURL)
        let importedActions = try JSONDecoder().decode(
            [CustomAction].self,
            from: data
        )
        try CustomActionValidator.validate(importedActions)
        actions = importedActions
        save()
    }

    func exportJSON(to destinationURL: URL) throws {
        let data = try encodedActions()
        try data.write(to: destinationURL, options: .atomic)
    }

    func ensureFileExists() throws {
        guard !FileManager.default.fileExists(
            atPath: fileURL.path
        ) else {
            return
        }
        try writeActions()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let loadedActions = try JSONDecoder().decode(
                [CustomAction].self,
                from: data
            )
            try CustomActionValidator.validate(loadedActions)
            actions = loadedActions
        } catch {
            print("actions failed to load: \(error.localizedDescription)")
        }
    }

    private func save() {
        do {
            try writeActions()
        } catch {
            print("actions failed to save: \(error.localizedDescription)")
        }
    }

    private func writeActions() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encodedActions()
        try data.write(to: fileURL, options: .atomic)
    }

    private func encodedActions() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(actions)
    }

    private static func defaultFileURL() -> URL {
        FileManager.default
            .urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            .appendingPathComponent(
                "Andrew Dictate",
                isDirectory: true
            )
            .appendingPathComponent("actions.json", isDirectory: false)
    }
}
