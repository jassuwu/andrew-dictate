import AppKit
import Foundation

/// The meeting half of setup, behind two closures.
///
/// Both meeting rows are things the app *does*, not things it asks: system
/// audio is proved by tapping our own process while the start sound plays —
/// 0021's probe, run one screen earlier, which is what fires the real TCC
/// prompt (ADR 0040) — and the meeting model is a download like any other.
/// Neither exists yet, so both arrive as injectable closures with stubs that
/// behave the way the real ones will. The view is written against the seam,
/// so the day the capture stack lands, nothing in the view changes.
@MainActor
final class OnboardingMeetingSetup: ObservableObject {
    /// Plays the start sound into the tap and reports whether the tap heard
    /// it. False means macOS is not letting us record this mac's audio.
    typealias SystemAudioProof = @Sendable () async -> Bool

    /// Fetches the meeting model, reporting 0…1 as it goes. False means the
    /// download did not finish.
    typealias MeetingModelPreparation = @Sendable (
        _ progress: @escaping @Sendable (Double) -> Void
    ) async -> Bool

    @Published private(set) var systemAudioStatus: OnboardingRowStatus =
        .pending
    @Published private(set) var modelStatus: OnboardingRowStatus = .pending
    @Published private(set) var modelProgress: Double = 0

    private let proveSystemAudio: SystemAudioProof
    private let prepareMeetingModel: MeetingModelPreparation
    private var systemAudioTask: Task<Void, Never>?
    private var modelTask: Task<Void, Never>?

    init(
        proveSystemAudio: @escaping SystemAudioProof =
            OnboardingMeetingSetup.stubbedSystemAudioProof,
        prepareMeetingModel: @escaping MeetingModelPreparation =
            OnboardingMeetingSetup.stubbedMeetingModelPreparation
    ) {
        self.proveSystemAudio = proveSystemAudio
        self.prepareMeetingModel = prepareMeetingModel
    }

    /// Called once, by consent, and only when meetings are ticked — nothing
    /// downloads and no sound plays before the click (SPEC §5).
    func begin() {
        proveSystemAudioNow()
        prepareModelNow()
    }

    /// The probe is worth re-running when the user comes back from privacy
    /// settings, and only then: it plays a sound, so running it on a timer
    /// would make the machine chirp at nobody.
    func proveSystemAudioAgain() {
        guard systemAudioStatus == .actionRequired else {
            return
        }
        proveSystemAudioNow()
    }

    func retryModel() {
        guard modelStatus == .actionRequired else {
            return
        }
        prepareModelNow()
    }

    /// Opens privacy › system audio recording, the one switch that makes the
    /// probe pass.
    func openSystemAudioSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:"
                + "com.apple.preference.security?Privacy_AudioCapture"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func proveSystemAudioNow() {
        guard systemAudioTask == nil else {
            return
        }
        systemAudioStatus = .inProgress
        let prove = proveSystemAudio
        systemAudioTask = Task { [weak self] in
            let heard = await prove()
            guard let self else {
                return
            }
            systemAudioStatus = heard ? .ready : .actionRequired
            systemAudioTask = nil
        }
    }

    private func prepareModelNow() {
        guard modelTask == nil else {
            return
        }
        modelStatus = .inProgress
        modelProgress = 0
        let prepare = prepareMeetingModel
        // The download reports from wherever it likes; this is the one hop
        // back to the main actor, made once rather than at every call site.
        let report: @Sendable (Double) -> Void = { [weak self] progress in
            self?.publish(progress: progress)
        }
        modelTask = Task { [weak self] in
            let downloaded = await prepare(report)
            guard let self else {
                return
            }
            modelStatus = downloaded ? .ready : .actionRequired
            modelTask = nil
        }
    }

    private nonisolated func publish(progress: Double) {
        Task { @MainActor in
            self.modelProgress = min(max(progress, 0), 1)
        }
    }

    // MARK: - stubs

    /// Long enough to be seen, short enough not to be waited on.
    static let stubbedSystemAudioProof: SystemAudioProof = {
        try? await Task.sleep(for: .milliseconds(600))
        return true
    }

    static let stubbedMeetingModelPreparation: MeetingModelPreparation = {
        report in
        for step in [0.35, 0.7, 1.0] {
            try? await Task.sleep(for: .milliseconds(400))
            report(step)
        }
        return true
    }
}
