import Combine
import Foundation

func dictatedWordCount(in transcript: String) -> Int {
    transcript.split(whereSeparator: { $0.isWhitespace }).count
}

enum EngineVersion: String, CaseIterable, Identifiable, Sendable {
    case v2
    case v3

    var id: Self {
        self
    }

    var displayName: String {
        switch self {
        case .v2:
            "parakeet v2 (english)"
        case .v3:
            "parakeet v3 (multilingual)"
        }
    }
}

struct ModelRemovalDecision: Equatable, Sendable {
    let isAllowed: Bool
    let requiresRepreparation: Bool
}

enum ModelRemovalPolicy {
    static func decision(
        of version: EngineVersion,
        activeVersion: EngineVersion
    ) -> ModelRemovalDecision {
        ModelRemovalDecision(
            isAllowed: true,
            requiresRepreparation: version == activeVersion
        )
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var onboardingCompleted: Bool {
        didSet {
            guard onboardingCompleted != oldValue else {
                return
            }
            userDefaults.set(
                onboardingCompleted,
                forKey: Self.onboardingCompletedKey
            )
        }
    }

    @Published var preRollEnabled: Bool {
        didSet {
            guard preRollEnabled != oldValue else {
                return
            }
            userDefaults.set(preRollEnabled, forKey: Self.preRollKey)
        }
    }

    @Published private(set) var dictationHotkey: HotkeyBinding {
        didSet {
            guard dictationHotkey != oldValue else {
                return
            }
            userDefaults.setHotkeyBinding(dictationHotkey, for: .dictation)
        }
    }

    @Published private(set) var commandHotkey: HotkeyBinding {
        didSet {
            guard commandHotkey != oldValue else {
                return
            }
            userDefaults.setHotkeyBinding(commandHotkey, for: .command)
        }
    }

    @Published var engineVersion: EngineVersion {
        didSet {
            guard engineVersion != oldValue else {
                return
            }
            userDefaults.set(
                engineVersion.rawValue,
                forKey: Self.engineVersionKey
            )
        }
    }

    @Published var agentCommandTemplate: String {
        didSet {
            guard agentCommandTemplate != oldValue else {
                return
            }
            guard agentCommandTemplate.isEmpty
                    || AgentCommandTemplate.isValid(agentCommandTemplate) else {
                agentCommandTemplate = oldValue
                return
            }
            userDefaults.set(
                agentCommandTemplate,
                forKey: Self.agentCommandTemplateKey
            )
        }
    }

    @Published var terminalBundleID: String {
        didSet {
            guard terminalBundleID != oldValue else {
                return
            }
            userDefaults.set(
                terminalBundleID,
                forKey: Self.terminalBundleIDKey
            )
        }
    }

    @Published private(set) var totalWordsDictated: Int {
        didSet {
            guard totalWordsDictated != oldValue else {
                return
            }
            userDefaults.set(
                totalWordsDictated,
                forKey: Self.totalWordsDictatedKey
            )
        }
    }

    private static let onboardingCompletedKey =
        "AndrewDictate.onboardingCompleted"
    private static let preRollKey = "AndrewDictate.preRollEnabled"
    private static let engineVersionKey = "AndrewDictate.engineVersion"
    private static let agentCommandTemplateKey =
        "AndrewDictate.agentCommandTemplate"
    private static let terminalBundleIDKey = "AndrewDictate.terminalBundleID"
    private static let totalWordsDictatedKey =
        "AndrewDictate.totalWordsDictated"

    static let defaultTerminalBundleID = "com.apple.Terminal"

    private let userDefaults: UserDefaults

    init(
        userDefaults: UserDefaults = .standard,
        detectedAgents: [DetectedAgentCLI]? = nil
    ) {
        self.userDefaults = userDefaults
        onboardingCompleted = userDefaults.bool(
            forKey: Self.onboardingCompletedKey
        )
        preRollEnabled = userDefaults.bool(forKey: Self.preRollKey)

        let loadedDictationHotkey = userDefaults.hotkeyBinding(for: .dictation)
        let loadedCommandHotkey = userDefaults.hotkeyBinding(for: .command)
        let correctedCommandHotkey: HotkeyBinding?
        dictationHotkey = loadedDictationHotkey
        if loadedCommandHotkey == loadedDictationHotkey {
            let replacement = HotkeyBinding.supported.first {
                $0 != loadedDictationHotkey
            } ?? .command
            commandHotkey = replacement
            correctedCommandHotkey = replacement
        } else {
            commandHotkey = loadedCommandHotkey
            correctedCommandHotkey = nil
        }

        engineVersion = userDefaults
            .string(forKey: Self.engineVersionKey)
            .flatMap(EngineVersion.init(rawValue:)) ?? .v2

        let initialAgentCommandTemplate: String
        let shouldPersistInitialAgentCommandTemplate: Bool
        if userDefaults.object(forKey: Self.agentCommandTemplateKey) != nil {
            let storedAgentTemplate = userDefaults.string(
                forKey: Self.agentCommandTemplateKey
            )
            initialAgentCommandTemplate = storedAgentTemplate.flatMap {
                $0.isEmpty || AgentCommandTemplate.isValid($0) ? $0 : nil
            } ?? ""
            shouldPersistInitialAgentCommandTemplate =
                storedAgentTemplate != initialAgentCommandTemplate
        } else {
            initialAgentCommandTemplate = Self.initialAgentCommandTemplate(
                detectedAgents: detectedAgents ?? AgentCLIDetector.detect()
            )
            shouldPersistInitialAgentCommandTemplate = true
        }
        agentCommandTemplate = initialAgentCommandTemplate

        terminalBundleID = userDefaults.string(
            forKey: Self.terminalBundleIDKey
        ) ?? Self.defaultTerminalBundleID
        totalWordsDictated = max(
            0,
            userDefaults.integer(forKey: Self.totalWordsDictatedKey)
        )

        if shouldPersistInitialAgentCommandTemplate {
            userDefaults.set(
                initialAgentCommandTemplate,
                forKey: Self.agentCommandTemplateKey
            )
        }

        if let correctedCommandHotkey {
            userDefaults.setHotkeyBinding(
                correctedCommandHotkey,
                for: .command
            )
        }
    }

    private static func initialAgentCommandTemplate(
        detectedAgents: [DetectedAgentCLI]
    ) -> String {
        for cli in AgentCLI.allCases
        where detectedAgents.contains(where: { $0.cli == cli }) {
            return cli.commandTemplate
        }
        return ""
    }

    func hotkeyBinding(for mode: DictationMode) -> HotkeyBinding {
        switch mode {
        case .dictation:
            dictationHotkey
        case .command:
            commandHotkey
        }
    }

    @discardableResult
    func setHotkeyBinding(
        _ binding: HotkeyBinding,
        for mode: DictationMode
    ) -> Bool {
        guard HotkeyBinding.supported.contains(binding),
              binding != hotkeyBinding(for: mode.other) else {
            return false
        }

        switch mode {
        case .dictation:
            dictationHotkey = binding
        case .command:
            commandHotkey = binding
        }

        return true
    }

    func recordDictatedTranscript(_ transcript: String) {
        let wordCount = dictatedWordCount(in: transcript)
        guard wordCount > 0 else {
            return
        }
        totalWordsDictated += wordCount
    }
}
