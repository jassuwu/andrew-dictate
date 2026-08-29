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

    /// the deterministic cleanup stage — spoken punctuation, emails,
    /// numbers, capitalisation. off means raw parakeet words; only the
    /// dictionary still applies, because a word you taught it is yours.
    @Published var cleanupEnabled: Bool {
        didSet {
            guard cleanupEnabled != oldValue else {
                return
            }
            userDefaults.set(cleanupEnabled, forKey: Self.cleanupEnabledKey)
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

    /// which model listens to meetings — its own pick, not dictation's
    /// (ADR 0040). the two jobs want opposite things and the cards say so.
    @Published var meetingModel: MeetingModel {
        didSet {
            guard meetingModel != oldValue else {
                return
            }
            userDefaults.set(
                meetingModel.rawValue,
                forKey: Self.meetingModelKey
            )
        }
    }

    /// the parent folder meetings are written under; the app makes
    /// `meetings/<year-month>/` inside it. a real folder you can open in
    /// finder, because the file *is* the artifact (SPEC §11).
    @Published var meetingsFolder: URL {
        didSet {
            guard meetingsFolder != oldValue else {
                return
            }
            userDefaults.set(
                meetingsFolder.path(percentEncoded: false),
                forKey: Self.meetingsFolderKey
            )
        }
    }

    /// one executable run detached after a transcript is closed, or nil.
    @Published var meetingHook: URL? {
        didSet {
            guard meetingHook != oldValue else {
                return
            }
            if let meetingHook {
                userDefaults.set(
                    meetingHook.path(percentEncoded: false),
                    forKey: Self.meetingHookKey
                )
            } else {
                userDefaults.removeObject(forKey: Self.meetingHookKey)
            }
        }
    }

    /// when the hook last ran, and how it went — "ok", "exit 3". kept
    /// because a hook that failed silently is a hook nobody can fix.
    @Published var meetingHookLastRunAt: Date? {
        didSet {
            guard meetingHookLastRunAt != oldValue else {
                return
            }
            if let meetingHookLastRunAt {
                userDefaults.set(
                    meetingHookLastRunAt,
                    forKey: Self.meetingHookLastRunAtKey
                )
            } else {
                userDefaults.removeObject(
                    forKey: Self.meetingHookLastRunAtKey
                )
            }
        }
    }

    @Published var meetingHookLastRunLabel: String? {
        didSet {
            guard meetingHookLastRunLabel != oldValue else {
                return
            }
            if let meetingHookLastRunLabel {
                userDefaults.set(
                    meetingHookLastRunLabel,
                    forKey: Self.meetingHookLastRunLabelKey
                )
            } else {
                userDefaults.removeObject(
                    forKey: Self.meetingHookLastRunLabelKey
                )
            }
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
    private static let cleanupEnabledKey = "AndrewDictate.cleanupEnabled"
    private static let totalWordsDictatedKey =
        "AndrewDictate.totalWordsDictated"
    /// whether this mac set the app up for dictation at all. someone who
    /// ticked only meetings must not be asked for accessibility at every
    /// launch — the gate reads this before it reads the permissions.
    @Published var dictationWanted: Bool {
        didSet {
            guard dictationWanted != oldValue else {
                return
            }
            userDefaults.set(dictationWanted, forKey: Self.dictationWantedKey)
        }
    }

    private static let dictationWantedKey = "AndrewDictate.dictationWanted"
    private static let meetingModelKey = "AndrewDictate.meetingModel"
    private static let meetingsFolderKey = "AndrewDictate.meetingsFolder"
    private static let meetingHookKey = "AndrewDictate.meetingHook"
    private static let meetingHookLastRunAtKey =
        "AndrewDictate.meetingHookLastRunAt"
    private static let meetingHookLastRunLabelKey =
        "AndrewDictate.meetingHookLastRunLabel"

    /// `~/Documents/andrew-dictate` — no spaces anywhere the app creates
    /// a path, so a hook can be a one-line shell script (SPEC §11).
    static let defaultMeetingsFolder: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Documents", isDirectory: true)
        .appendingPathComponent("andrew-dictate", isDirectory: true)

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
        // unset means on: cleanup has always shipped enabled.
        cleanupEnabled = userDefaults.object(
            forKey: Self.cleanupEnabledKey
        ) == nil
            ? true
            : userDefaults.bool(forKey: Self.cleanupEnabledKey)
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

        dictationWanted = userDefaults.object(forKey: Self.dictationWantedKey) == nil
            ? true
            : userDefaults.bool(forKey: Self.dictationWantedKey)
        meetingModel = userDefaults
            .string(forKey: Self.meetingModelKey)
            .flatMap(MeetingModel.init(rawValue:)) ?? .default
        meetingsFolder = userDefaults
            .string(forKey: Self.meetingsFolderKey)
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? Self.defaultMeetingsFolder
        meetingHook = userDefaults
            .string(forKey: Self.meetingHookKey)
            .map { URL(fileURLWithPath: $0) }
        meetingHookLastRunAt = userDefaults
            .object(forKey: Self.meetingHookLastRunAtKey) as? Date
        meetingHookLastRunLabel = userDefaults
            .string(forKey: Self.meetingHookLastRunLabelKey)
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
