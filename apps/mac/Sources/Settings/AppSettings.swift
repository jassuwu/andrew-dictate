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

    @Published var onboardingDismissed: Bool {
        didSet {
            guard onboardingDismissed != oldValue else {
                return
            }
            userDefaults.set(
                onboardingDismissed,
                forKey: Self.onboardingDismissedKey
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

    @Published private(set) var dictationHotkey: HotkeyBinding {
        didSet {
            guard dictationHotkey != oldValue else {
                return
            }
            userDefaults.setHotkeyBinding(dictationHotkey)
        }
    }

    /// Whether finished dictations are written to the archive.
    ///
    /// On by default (ADR 0026), stated in onboarding. The pre-roll ruling went
    /// the other way, and the difference is that pre-roll opens a microphone
    /// while this keeps text the app has already produced and already pasted.
    /// Nothing new is listened to.
    @Published var keepDictations: Bool {
        didSet {
            guard keepDictations != oldValue else {
                return
            }
            userDefaults.set(
                keepDictations,
                forKey: Self.keepDictationsKey
            )
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

    /// the stored key keeps its original spelling on purpose — renaming it
    /// would hand every existing user a fresh onboarding window.
    private static let onboardingDismissedKey =
        "AndrewDictate.onboardingCompleted"
    private static let preRollKey = "AndrewDictate.preRollEnabled"
    private static let soundFeedbackKey =
        "AndrewDictate.soundFeedbackEnabled"
    private static let keepDictationsKey = "AndrewDictate.keepDictations"
    private static let engineVersionKey = "AndrewDictate.engineVersion"
    private static let cleanupModeKey = "AndrewDictate.cleanupMode"
    private static let totalWordsDictatedKey =
        "AndrewDictate.totalWordsDictated"

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        onboardingDismissed = userDefaults.bool(
            forKey: Self.onboardingDismissedKey
        )
        preRollEnabled = userDefaults.bool(forKey: Self.preRollKey)
        soundFeedbackEnabled = userDefaults.object(
            forKey: Self.soundFeedbackKey
        ) == nil
            ? true
            : userDefaults.bool(forKey: Self.soundFeedbackKey)
        // unset means on: this ships enabled, unlike pre-roll.
        keepDictations = userDefaults.object(
            forKey: Self.keepDictationsKey
        ) == nil
            ? true
            : userDefaults.bool(forKey: Self.keepDictationsKey)
        dictationHotkey = userDefaults.hotkeyBinding()

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

        totalWordsDictated = max(
            0,
            userDefaults.integer(forKey: Self.totalWordsDictatedKey)
        )
    }

    @discardableResult
    func setHotkeyBinding(_ binding: HotkeyBinding) -> Bool {
        guard HotkeyBinding.supported.contains(binding) else {
            return false
        }

        dictationHotkey = binding
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
