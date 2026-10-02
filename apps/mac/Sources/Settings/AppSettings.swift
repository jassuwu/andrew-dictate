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
    /// links, numbers, capitalisation. off means raw parakeet words; only the
    /// dictionary still applies, because a word you taught it is yours.
    @Published var cleanupEnabled: Bool {
        didSet {
            guard cleanupEnabled != oldValue else {
                return
            }
            userDefaults.set(cleanupEnabled, forKey: Self.cleanupEnabledKey)
        }
    }

    /// words the suggestion list has been told are not mistakes. half of any
    /// first list is spelled how it is spelled — "swiggy", "paneer" — so
    /// "not a mistake" is one click and has to stick.
    @Published private(set) var dismissedSuggestions: Set<String> {
        didSet {
            guard dismissedSuggestions != oldValue else {
                return
            }
            userDefaults.set(
                dismissedSuggestions.sorted(),
                forKey: Self.dismissedSuggestionsKey
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

    /// the daily update check (ADR 0043): once a day the app sends its
    /// version to dictate.jass.gg and hears back the newest. on unless
    /// switched off; off means no request at all.
    @Published var checksForUpdates: Bool {
        didSet {
            guard checksForUpdates != oldValue else {
                return
            }
            userDefaults.set(checksForUpdates, forKey: Self.checksForUpdatesKey)
        }
    }

    /// when the site last answered, and what it said. state rather than a
    /// choice, kept here so "once a day" survives a relaunch.
    var updateCheckedAt: Date? {
        get {
            userDefaults.object(forKey: Self.updateCheckedAtKey) as? Date
        }
        set {
            userDefaults.set(newValue, forKey: Self.updateCheckedAtKey)
        }
    }

    var newestVersionSeen: String? {
        get {
            userDefaults.string(forKey: Self.newestVersionSeenKey)
        }
        set {
            userDefaults.set(newValue, forKey: Self.newestVersionSeenKey)
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
    private static let cleanupEnabledKey = "AndrewDictate.cleanupEnabled"
    private static let dismissedSuggestionsKey =
        "AndrewDictate.dismissedSuggestions"
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
    private static let checksForUpdatesKey = "AndrewDictate.checksForUpdates"
    private static let updateCheckedAtKey = "AndrewDictate.updateCheckedAt"
    private static let newestVersionSeenKey =
        "AndrewDictate.newestVersionSeen"

    /// `~/andrew-dictate` — no spaces anywhere the app creates a path, so a
    /// hook can be a one-line shell script (SPEC §11). deliberately not
    /// inside ~/Documents or ~/Desktop: those are the two folders macOS
    /// syncs to icloud on its own, and a meeting holds other people's words.
    static let defaultMeetingsFolder: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("andrew-dictate", isDirectory: true)

    /// where the default used to point. an install that already wrote
    /// transcripts there keeps it — a new default must not orphan them.
    static let legacyMeetingsFolder: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Documents", isDirectory: true)
        .appendingPathComponent("andrew-dictate", isDirectory: true)

    /// the parent to write under when nobody has picked one: the old one if
    /// it already holds a `meetings/` folder, the new default otherwise.
    static func unpickedMeetingsFolder(
        legacy: URL = AppSettings.legacyMeetingsFolder,
        fallback: URL = AppSettings.defaultMeetingsFolder,
        fileManager: FileManager = .default
    ) -> URL {
        var isDirectory: ObjCBool = false
        let written = legacy
            .appendingPathComponent("meetings", isDirectory: true)
            .path(percentEncoded: false)
        guard fileManager.fileExists(atPath: written, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return fallback
        }
        return legacy
    }

    /// whether a folder is one icloud carries off the mac. ~/Documents
    /// becomes a symlink into ~/Library/Mobile Documents once Desktop &
    /// Documents sync is on, so the resolved path tells us even before
    /// icloud has finished indexing a folder made a second ago. a courtesy,
    /// not a guarantee: dropbox and google drive are invisible to it.
    static func syncsToICloud(_ url: URL) -> Bool {
        if url.resolvingSymlinksInPath()
            .pathComponents
            .contains("Mobile Documents") {
            return true
        }
        return (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?
            .isUbiquitousItem == true
    }

    private let userDefaults: UserDefaults

    init(
        userDefaults: UserDefaults = .standard,
        unpickedMeetingsFolder: URL = AppSettings.unpickedMeetingsFolder()
    ) {
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

        totalWordsDictated = max(
            0,
            userDefaults.integer(forKey: Self.totalWordsDictatedKey)
        )
        dismissedSuggestions = Set(
            userDefaults.stringArray(forKey: Self.dismissedSuggestionsKey) ?? []
        )

        dictationWanted = userDefaults.object(forKey: Self.dictationWantedKey) == nil
            ? true
            : userDefaults.bool(forKey: Self.dictationWantedKey)
        meetingModel = userDefaults
            .string(forKey: Self.meetingModelKey)
            .flatMap(MeetingModel.init(rawValue:)) ?? .default
        let pickedMeetingsFolder = userDefaults
            .string(forKey: Self.meetingsFolderKey)
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        meetingsFolder = pickedMeetingsFolder ?? unpickedMeetingsFolder
        meetingHook = userDefaults
            .string(forKey: Self.meetingHookKey)
            .map { URL(fileURLWithPath: $0) }
        meetingHookLastRunAt = userDefaults
            .object(forKey: Self.meetingHookLastRunAtKey) as? Date
        meetingHookLastRunLabel = userDefaults
            .string(forKey: Self.meetingHookLastRunLabelKey)
        // unset means on (ADR 0043).
        checksForUpdates = userDefaults.object(
            forKey: Self.checksForUpdatesKey
        ) == nil
            ? true
            : userDefaults.bool(forKey: Self.checksForUpdatesKey)

        // an install from before the default left ~/Documents keeps the
        // folder its transcripts are in — written down, so the choice
        // outlives whatever the default becomes next.
        if pickedMeetingsFolder == nil,
           meetingsFolder != Self.defaultMeetingsFolder {
            userDefaults.set(
                meetingsFolder.path(percentEncoded: false),
                forKey: Self.meetingsFolderKey
            )
        }
    }

    @discardableResult
    func setHotkeyBinding(_ binding: HotkeyBinding) -> Bool {
        guard HotkeyBinding.supported.contains(binding) else {
            return false
        }

        dictationHotkey = binding
        return true
    }

    /// "not a mistake", and it never comes back.
    func dismissSuggestion(_ word: String) {
        dismissedSuggestions.insert(word.lowercased())
    }

    func recordDictatedTranscript(_ transcript: String) {
        let wordCount = dictatedWordCount(in: transcript)
        guard wordCount > 0 else {
            return
        }
        totalWordsDictated += wordCount
    }
}
