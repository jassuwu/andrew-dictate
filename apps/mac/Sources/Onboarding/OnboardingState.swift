import Foundation

enum OnboardingRowStatus: Equatable, Sendable {
    case pending
    /// Something is happening right now that nobody has to click: the sound
    /// is playing, the model is coming down. Distinct from `pending`, which
    /// is a row that has not started.
    case inProgress
    case actionRequired
    case ready
}

enum OnboardingCompletion: Equatable, Sendable {
    case pending
    case finished
    case skipped
}

/// Why setup is open. `everything` is the first launch — both jobs offered,
/// either one declinable. `meetingsOnly` is the same window reopened from
/// `record a meeting` by someone who unticked meetings the first time: the
/// job rows are gone, because the choice was already made by pressing record
/// (ADR 0040, SPEC §5).
enum OnboardingScope: Equatable, Sendable {
    case everything
    case meetingsOnly
}

/// Which jobs this run of setup is for. Two jobs share one mic and one
/// window, but not their checklists: dictation wants accessibility and the
/// dictation model, meetings want system audio and the meeting model.
struct OnboardingJobs: Equatable, Sendable {
    /// SPEC §5 prices the two jobs on the button. The numbers are the
    /// downloads the click actually starts — parakeet for dictation, whisper
    /// large-v3 for meetings — rounded the way a person would say them.
    static let dictationDownload = "~460 mb"
    static let meetingsDownload = "~2.9 gb"
    static let bothDownloads = "~3.3 gb"

    var scope: OnboardingScope = .everything
    var dictation = true
    var meetings = true

    var anySelected: Bool {
        dictation || meetings
    }

    /// What the button costs. Empty when nothing is ticked — there is no
    /// download to price, and the button is refused anyway.
    var downloadSize: String {
        switch (dictation, meetings) {
        case (true, true): Self.bothDownloads
        case (true, false): Self.dictationDownload
        case (false, true): Self.meetingsDownload
        case (false, false): ""
        }
    }

    /// The mic is both jobs' first requirement, so it is never conditional.
    /// Accessibility belongs to dictation alone and system audio to meetings
    /// alone, which is what makes the permissions screen two or three.
    var permissions: [String] {
        var permissions = ["microphone"]
        if dictation {
            permissions.append("accessibility")
        }
        if meetings {
            permissions.append("system audio")
        }
        return permissions
    }
}

struct OnboardingState: Equatable, Sendable {
    let scope: OnboardingScope
    private(set) var dictationSelected: Bool
    private(set) var meetingsSelected: Bool
    private(set) var consented = false
    private(set) var microphoneStatus: OnboardingRowStatus = .pending
    private(set) var accessibilityStatus: OnboardingRowStatus = .pending
    private(set) var modelStatus: OnboardingRowStatus = .pending
    private(set) var systemAudioStatus: OnboardingRowStatus = .pending
    private(set) var meetingModelStatus: OnboardingRowStatus = .pending
    private(set) var whileYouWaitVisible = false
    private(set) var completion: OnboardingCompletion = .pending

    init(scope: OnboardingScope = .everything) {
        self.scope = scope
        dictationSelected = scope != .meetingsOnly
        meetingsSelected = true
    }

    var jobs: OnboardingJobs {
        OnboardingJobs(
            scope: scope,
            dictation: dictationSelected,
            meetings: meetingsSelected
        )
    }

    /// Every row of every selected job, and at least one job. A checklist
    /// with nothing on it is not a finished setup — it is an unanswered
    /// question, and finishing on it would claim the app was ready to do
    /// something nobody asked it to do.
    var autoFinishArmed: Bool {
        guard completion == .pending, dictationSelected || meetingsSelected
        else {
            return false
        }
        if dictationSelected {
            guard microphoneStatus == .ready,
                  accessibilityStatus == .ready,
                  modelStatus == .ready
            else {
                return false
            }
        }
        if meetingsSelected {
            guard microphoneStatus == .ready,
                  systemAudioStatus == .ready,
                  meetingModelStatus == .ready
            else {
                return false
            }
        }
        return true
    }

    /// The ticks are a question asked once. After consent the downloads have
    /// started and the permissions have been asked for, so unticking a job
    /// would be undoing something that already happened; setup answers no
    /// rather than pretending. `meetingsOnly` refuses from the start — the
    /// choice was made by pressing `record a meeting`.
    @discardableResult
    mutating func setDictationSelected(_ selected: Bool) -> Bool {
        guard jobSelectionIsOpen else {
            return false
        }
        dictationSelected = selected
        return true
    }

    @discardableResult
    mutating func setMeetingsSelected(_ selected: Bool) -> Bool {
        guard jobSelectionIsOpen else {
            return false
        }
        meetingsSelected = selected
        return true
    }

    private var jobSelectionIsOpen: Bool {
        scope == .everything && !consented && completion == .pending
    }

    @discardableResult
    mutating func consentToSetup() -> Bool {
        guard completion == .pending, !consented else {
            return false
        }

        consented = true
        whileYouWaitVisible = downloadPending
        if dictationSelected, accessibilityStatus == .pending {
            accessibilityStatus = .actionRequired
        }
        return true
    }

    /// Only a download you are actually waiting for earns the panel.
    private var downloadPending: Bool {
        (dictationSelected && modelStatus != .ready)
            || (meetingsSelected && meetingModelStatus != .ready)
    }

    mutating func updateMicrophoneStatus(
        _ status: OnboardingRowStatus
    ) {
        microphoneStatus = status
    }

    mutating func updateAccessibility(granted: Bool) {
        accessibilityStatus = granted
            ? .ready
            : consented ? .actionRequired : .pending
    }

    mutating func updateModelStatus(
        _ status: OnboardingRowStatus
    ) {
        modelStatus = status
    }

    mutating func updateSystemAudioStatus(
        _ status: OnboardingRowStatus
    ) {
        systemAudioStatus = status
    }

    mutating func updateMeetingModelStatus(
        _ status: OnboardingRowStatus
    ) {
        meetingModelStatus = status
    }

    @discardableResult
    mutating func finishAutomatically() -> Bool {
        guard autoFinishArmed else {
            return false
        }
        completion = .finished
        return true
    }

    @discardableResult
    mutating func skipForNow() -> Bool {
        guard completion == .pending else {
            return false
        }
        completion = .skipped
        return true
    }
}
