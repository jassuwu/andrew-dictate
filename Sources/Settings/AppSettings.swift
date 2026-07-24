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

enum CleanupMode: String, CaseIterable, Identifiable, Sendable {
    case off
    case on
    case always

    var id: Self {
        self
    }

    var explanation: String {
        switch self {
        case .off:
            "uses deterministic cleanup only."
        case .on:
            "cleans when it's fast enough, raw otherwise."
        case .always:
            "waits for the clean version."
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

    @Published var soundFeedbackEnabled: Bool {
        didSet {
            guard soundFeedbackEnabled != oldValue else {
                return
            }
            userDefaults.set(
                soundFeedbackEnabled,
                forKey: Self.soundFeedbackKey
            )
        }
    }

    @Published var voiceAnswersEnabled: Bool {
        didSet {
            guard voiceAnswersEnabled != oldValue else {
                return
            }
            userDefaults.set(
                voiceAnswersEnabled,
                forKey: Self.voiceAnswersKey
            )
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

    @Published var cleanupMode: CleanupMode {
        didSet {
            guard cleanupMode != oldValue else {
                return
            }
            userDefaults.set(
                cleanupMode.rawValue,
                forKey: Self.cleanupModeKey
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
    private static let soundFeedbackKey =
        "AndrewDictate.soundFeedbackEnabled"
    private static let voiceAnswersKey =
        "AndrewDictate.voiceAnswersEnabled"
    private static let engineVersionKey = "AndrewDictate.engineVersion"
    private static let cleanupModeKey = "AndrewDictate.cleanupMode"
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
        soundFeedbackEnabled = userDefaults.object(
            forKey: Self.soundFeedbackKey
        ) == nil
            ? true
            : userDefaults.bool(forKey: Self.soundFeedbackKey)
        voiceAnswersEnabled = userDefaults.bool(
            forKey: Self.voiceAnswersKey
        )

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
        // "shadow" existed briefly pre-release; migrate it to "on"
        let storedCleanupMode = userDefaults
            .string(forKey: Self.cleanupModeKey)
        cleanupMode = storedCleanupMode == "shadow"
            ? .on
            : storedCleanupMode
                .flatMap(CleanupMode.init(rawValue:)) ?? .off

        var initialAgentCommandTemplate: String
        var shouldPersistInitialAgentCommandTemplate: Bool
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
        // migrate the pre-0.1.3 codex default: without --skip-git-repo-check,
        // codex refuses to run from the (non-repo) delegation script directory
        if initialAgentCommandTemplate == "codex exec {prompt}" {
            initialAgentCommandTemplate = "codex exec --skip-git-repo-check {prompt}"
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
