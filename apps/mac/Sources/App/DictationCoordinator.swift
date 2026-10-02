import Combine
import OSLog
import Foundation
import AppKit
import AVFoundation

struct HotkeyDetection: Equatable, Sendable {
    let sequence: Int
}

/// file scope because the recorder is built during init, before there is a
/// `self` to log through.
private let audioLogger = Logger(
    subsystem: AppIdentity.loggingSubsystem,
    category: "audio"
)

@MainActor
final class DictationCoordinator: ObservableObject {
    private let engineLogger = Logger(
        subsystem: AppIdentity.loggingSubsystem,
        category: "engine"
    )
    private let cleanupLogger = Logger(
        subsystem: AppIdentity.loggingSubsystem,
        category: "cleanup"
    )
    private let permissionLogger = Logger(
        subsystem: AppIdentity.loggingSubsystem,
        category: "permissions"
    )
    /// the machine owns the state; the menu, the HUD and the menu-bar icon
    /// still say `DictationCoordinator.State`.
    typealias State = UtteranceMachine.State

    /// the machine's state, mirrored for the menu. only `apply` writes it.
    @Published private(set) var state: State = .prewarming
    @Published private(set) var enginePreparationState:
        EnginePreparationState = .notStarted
    /// sampled once, before the download starts: `.ready` is reached the same
    /// way whether 460 mb came down or the folder was already full, and setup
    /// has to say which of the two the user just lived through.
    @Published private(set) var engineModelWasOnDisk = false
    @Published private(set) var activeEngineVersion: EngineVersion
    @Published private(set) var engineSwitchMessage: String?
    @Published private(set) var hotkeyDetection: HotkeyDetection?
    /// what actually reached the page, cleaned.
    @Published private(set) var lastTranscript: String?
    /// drives the menu's one time-sensitive row after a failed transcription
    @Published private(set) var canRetryLastFailure = false
    /// the engine's own words, before any transform ran. this is what "fix a
    /// word" opens on: an entry's `wrong` side has to be what parakeet
    /// produced, or it never fires.
    @Published private(set) var lastHeard: String?
    /// re-read at launch, reopen, wake, unlock, and whenever the system says
    /// the trust table moved. a grant is a fact about now, not a fact we own.
    /// the hotkey monitors hang off this one funnel too — a path that wins
    /// accessibility without coming through here leaves fn dead.
    @Published private(set) var permissions = PermissionSnapshot(
        microphoneGranted: false,
        accessibilityGranted: false
    )

    /// a missing grant and a download that never finished leave the app
    /// equally unable to transcribe a word, so they wear the same dot.
    var needsAttention: Bool {
        SetupGate.needsAttention(
            onboardingDismissed: settings.onboardingDismissed,
            dictationWanted: settings.dictationWanted,
            permissions: permissions,
            speechModelFailed: enginePreparationState == .failed
        )
    }

    /// the narrower question the re-entry scope asks: set up, wants dictation,
    /// and a grant is what is missing. a failed download wears the same dot
    /// but goes back through the whole checklist, model row included.
    var needsPermissionAttention: Bool {
        settings.onboardingDismissed
            && settings.dictationWanted
            && !permissions.isDictationReady
    }

    /// system audio is not part of `needsPermissionAttention` — that badge is
    /// dictation's. this is meetings' own, set when a tap would not open and
    /// cleared by the next meeting that starts.
    @Published private(set) var meetingsNeedAttention = false

    /// the meeting that just ended, for as long as it is the thing you came
    /// back to the menu for.
    @Published private(set) var lastMeeting: MeetingSummary?
    @Published private(set) var lastMeetingSavedAt: Date?

    private static let lastMeetingRowLasts: TimeInterval = 600

    /// ten minutes, then the menu is the hand it was. not gated on the
    /// notification permission: a denied prompt is exactly when this row is
    /// the only route to the file.
    var showsLastMeetingRow: Bool {
        guard lastMeeting != nil, let lastMeetingSavedAt else { return false }
        return Date().timeIntervalSince(lastMeetingSavedAt) < Self.lastMeetingRowLasts
    }

    func revealLastMeeting() {
        guard let lastMeeting else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastMeeting.fileURL])
    }

    let dictionaryStore: DictionaryStore
    let settings: AppSettings

    private let hotkeyMonitor: HotkeyMonitor
    private let transcriptionEngine: ParakeetEngine
    /// key-down to outcome. this object wires it and wears what it says.
    private let machine: UtteranceMachine
    /// var, not let: the input node can be missing at launch (headset off,
    /// dock unplugged) and arrive later. one failed build must not be final.
    private var audioRecorder: AudioRecorder?
    private let feedbackSounds: FeedbackSounds
    private let hudViewModel: HUDViewModel
    private var hudPanelStorage: HUDPanel?

    /// The HUD panel must never be created or touched synchronously from a
    /// SwiftUI transaction: the coordinator is built inside @StateObject init
    /// (itself inside a MenuBarExtra graph update), and constructing/ordering
    /// an NSHostingView there nests AttributeGraph updates and aborts.
    /// All panel work therefore hops to the next main-run-loop turn.
    private func withHUDPanel(_ action: @escaping (HUDPanel) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let panel: HUDPanel
            if let existing = self.hudPanelStorage {
                panel = existing
            } else {
                panel = HUDPanel(viewModel: self.hudViewModel)
                self.hudPanelStorage = panel
            }
            action(panel)
        }
    }
    private var isPrewarmed = false
    /// whether the ember is an answer to something the user did. a
    /// launch-time warm-up is not, and shows nothing (HUDPresentation).
    private var prewarmPresentsHUD = true
    private var enginePrewarmTask: Task<Void, Never>?
    private var engineSwapTask: Task<Void, Never>?
    private var engineHealthTask: Task<Void, Never>?
    private var engineGeneration = 0
    /// set only by `retryEnginePrewarm`, read once by the prewarm's catch
    private var retryWasUserInitiated = false
    private var engineSwitchState: EngineSwitchState
    private var enginePreparationRequested: Bool
    private var settingsCancellables: Set<AnyCancellable> = []
    private var isApplyingPreRollSetting = false
    private var isApplyingEngineVersionSetting = false
    private var onboardingWindowController: OnboardingWindowController?
    private var isOnboardingPresented: Bool
    private var hotkeyDetectionSequence = 0
    private var stateGeneration: UInt64 = 0
    private var feedbackGeneration: UInt64 = 0
    private var activeFeedbackGeneration: UInt64?
    /// an exceptional message the setup window took the screen from. it is
    /// owed, not spent: held until that window closes (HUDFeedbackGate).
    private var heldFeedback: (
        message: String,
        duration: TimeInterval,
        at: Date
    )?
    private let timelineStore = UtteranceTimelineStore()
    private var aboutWindowController: AboutWindowController?
    private var lampLabWindowController: LampLabWindowController?
    /// Rebuilt per transcript rather than reused: the window is *about* one
    /// dictation, so keeping a stale one around would show the wrong words.
    private let dictationArchive = DictationArchive()
    private var wordFixerWindowController: WordFixerWindowController?

    // MARK: meetings (ADR 0023, 0040)
    let meetings: MeetingCoordinator
    let liveTranscript = LiveTranscriptModel(app: "", elapsed: .zero)
    @Published private(set) var meetingModelDownloads: [MeetingModel: Double] = [:]
    @Published private(set) var isLiveTranscriptShown = false
    private let meetingNotifier = MeetingNudgeNotifier()
    /// the app `record a meeting ▸ zoom` named, held while setup runs. the
    /// click already happened; setup is the detour, not a new question.
    private var pendingMeetingApp: RunningApp?
    private var liveTranscriptPanel: LiveTranscriptPanel?
    private var meetingCancellables: Set<AnyCancellable> = []
    /// A quit is waiting on a meeting's transcript to be written.
    private var quitWaitingOnMeeting = false
    private var workspaceNotificationObservers: [NSObjectProtocol] = []
    private var distributedNotificationObservers: [NSObjectProtocol] = []

    init(settings: AppSettings = .shared) {
        self.settings = settings
        activeEngineVersion = settings.engineVersion
        engineSwitchState = EngineSwitchState(
            activeVersion: settings.engineVersion
        )
        isOnboardingPresented = !settings.onboardingDismissed
        enginePreparationRequested = EnginePrewarmGate.shouldPrewarmAtLaunch(
            onboardingDismissed: settings.onboardingDismissed,
            dictationWanted: settings.dictationWanted
        )
        let dictionaryStore = DictionaryStore()
        self.dictionaryStore = dictionaryStore
        let transcriptionEngine = ParakeetEngine(
            version: settings.engineVersion
        )
        self.transcriptionEngine = transcriptionEngine
        machine = UtteranceMachine(
            engine: transcriptionEngine,
            inserter: PasteInserter(),
            dictionary: { dictionaryStore.entries },
            coolDuration: HUDWaveMotion.coolDuration
        )

        let recorder: AudioRecorder?
        do {
            recorder = try AudioRecorder(
                preRollEnabled: settings.preRollEnabled
            )
        } catch {
            recorder = nil
            audioLogger.error(
                """
                audio recorder init failed: \
                \(error.localizedDescription, privacy: .public)
                """
            )
        }
        audioRecorder = recorder
        feedbackSounds = FeedbackSounds(settings: settings)
        meetings = MeetingCoordinator(
            source: CoreAudioMeetingSource(),
            makeTranscriber: { try await MeetingEngines.makeTranscriber(for: $0) },
            diarizer: MeetingEngines.makeDiarizer(),
            preferences: {
                MeetingPreferences(
                    folder: settings.meetingsFolder,
                    hook: settings.meetingHook,
                    model: settings.meetingModel
                )
            }
        )

        let viewModel = HUDViewModel(
            state: .prewarming,
            audioRecorder: recorder
        )
        hudViewModel = viewModel

        let monitor = HotkeyMonitor(settings: settings)
        hotkeyMonitor = monitor

        monitor.onBegin = { [weak self] in
            self?.beginRecording(locked: false)
        }
        monitor.onEnd = { [weak self] in
            self?.machine.keyUp()
        }
        monitor.onCancel = { [weak self] in
            self?.machine.keyCancelled()
        }
        monitor.onLockBegin = { [weak self] in
            self?.beginRecording(locked: true)
        }
        monitor.onLockEnd = { [weak self] in
            self?.machine.keyUp()
        }
        monitor.onLockCancel = { [weak self] in
            self?.machine.keyCancelled()
        }
        monitor.onKeyDetected = { [weak self] in
            guard let self else {
                return
            }
            self.hotkeyDetectionSequence += 1
            self.hotkeyDetection = HotkeyDetection(
                sequence: self.hotkeyDetectionSequence
            )
        }
        monitor.onEscape = { [weak self] in
            self?.machine.escape() ?? false
        }
        recorder?.onInterruption = { [weak self] reason in
            self?.handleCaptureInterruption(reason: reason)
        }
        recorder?.onCapReached = { [weak self] in
            self?.handleCaptureCapReached()
        }
        recorder?.onCapApproaching = { [weak self] in
            self?.machine.capApproaching()
        }

        settings.$preRollEnabled
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] enabled in
                self?.applyPreRoll(enabled)
            }
            .store(in: &settingsCancellables)

        // saying yes to dictation later should not cost a relaunch: the
        // model arrives when the tick does.
        settings.$dictationWanted
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] wanted in
                guard wanted else {
                    return
                }
                self?.requestEnginePreparation(asking: true)
            }
            .store(in: &settingsCancellables)

        settings.$engineVersion
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] version in
                guard let self,
                      !self.isApplyingEngineVersionSetting else {
                    return
                }
                self.replaceEngine(with: version)
            }
            .store(in: &settingsCancellables)

        // one cleaner per dictionary-and-toggle, not one per dictation.
        // CombineLatest seeds itself from both current values here, and the
        // closure must use what it is handed: a @Published sink fires on
        // willSet, so reading the store would hand back the old array.
        Publishers.CombineLatest(
            dictionaryStore.$entries,
            settings.$cleanupEnabled
        )
        .sink { [weak self] entries, fullCleanup in
            self?.machine.cleaner = DeterministicCleaner(
                entries: entries,
                fullCleanup: fullCleanup
            )
        }
        .store(in: &settingsCancellables)

        wireMachine()
        installSystemLifecycleObservers()
        wireMeetings()

        permissions = SystemPermissions.snapshot()
        // the stored flag only knows the window was closed once. whether this
        // app can actually dictate is a question for the permissions.
        if setupPresentation(moment: .launchOrReopen) == .present {
            isOnboardingPresented = true
        }

        if isOnboardingPresented {
            hotkeyMonitor.setDetectionOnly(true)
        }

        if enginePreparationRequested {
            // at launch the model loads because the app is running, not
            // because anybody reached for the key. the menu says so; the
            // screen stays empty.
            startPrewarming(presentsHUD: false)
        } else {
            // `state` is born .prewarming and only a prewarm ever settles it,
            // so a launch that loads nothing has to settle it here: a lamp
            // breathing with no download behind it is the same lie as the
            // download nobody asked for, wearing the opposite face.
            state = .idle
            hudViewModel.update(state: .idle)
        }

        // meetings need the microphone too, so this is not dictation's to
        // gate — and after setup it is a status check, not an ask. before
        // setup, onboarding is still the only surface that asks macOS.
        if settings.onboardingDismissed {
            Task { @MainActor [weak self] in
                _ = await self?.requestMicrophoneAccess()
            }
        }

        if isOnboardingPresented {
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.presentOnboardingIfNeeded()
            }
        }

        if Capabilities.current.hasLampLab,
           UserDefaults.standard.bool(
               forKey: LampLabWindowController.atLaunchKey
           ) {
            Task { @MainActor [weak self] in
                self?.openLampLab()
            }
        }
        if Capabilities.current.hasLampLab {
            // `defaults write <bundle> hudRehearseNow -bool true` fires the
            // rehearsal on demand, so a screenshot run needs no clicking
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self,
                          UserDefaults.standard.bool(forKey: "hudRehearseNow") else {
                        return
                    }
                    UserDefaults.standard.removeObject(forKey: "hudRehearseNow")
                    self.rehearseHUDForDevelopment()
                }
            }
        }
        // "fix a word…" is the menu's only time-sensitive action, and it used
        // to be grey until this session's first dictation — while the words
        // it wants sat in the archive the whole time. detached, because the
        // read is disk and launch is not. the file on disk is the source of
        // truth, so `keepDictations` does not gate the read: an empty or
        // missing archive is the only case that stays disabled.
        let archive = dictationArchive
        Task.detached { [weak self] in
            let newest = try? archive.latest()
            await MainActor.run {
                // a dictation that landed during the read wins: pointing the
                // fixer back at yesterday's words would be silent and wrong.
                guard let self, self.lastHeard == nil, let newest else {
                    return
                }
                self.lastHeard = newest.heard
            }
        }
    }

    @discardableResult
    func rebindHotkey(to binding: HotkeyBinding) -> Bool {
        hotkeyMonitor.rebind(to: binding)
    }


    func openAbout() {
        let controller: AboutWindowController
        if let aboutWindowController {
            controller = aboutWindowController
        } else {
            controller = AboutWindowController(settings: settings)
            aboutWindowController = controller
        }
        controller.present()
    }

    /// Development only (`Capabilities.hasLampLab`): walk the real HUD
    /// through a dictation without a mic or a key — warm, record, cool,
    /// one line of feedback — so the lamp can be seen over a real desktop.
    /// the state machine is not touched; only the view model and the panel.
    /// `defaults write <bundle> hudRehearseNow -bool true` fires it.
    func rehearseHUDForDevelopment() {
        guard Capabilities.current.hasLampLab,
              state == .idle,
              !isOnboardingPresented else {
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let steps: [(DictationCoordinator.State?, String?, Double)] = [
                (.prewarming, nil, 1.2),
                (.recording, nil, 4.0),
                (.transcribing, nil, 0.5),
                (nil, "nothing was heard, nothing kept", 1.8),
            ]
            // a voice: bursts with gaps, roughly a sentence's rhythm
            let voice = Task { @MainActor [weak self] in
                let started = Date()
                while !Task.isCancelled {
                    let t = Date().timeIntervalSince(started)
                    let burst = max(0, sin(t * 2.6)) * (0.55 + 0.45 * sin(t * 12.7))
                    self?.hudViewModel.rehearsalLevel = Float(min(1, burst * 1.15))
                    try? await Task.sleep(for: .milliseconds(33))
                }
                self?.hudViewModel.rehearsalLevel = nil
            }
            defer { voice.cancel() }
            for (next, feedback, hold) in steps {
                if let next {
                    self.hudViewModel.update(state: next)
                }
                if let feedback {
                    self.hudViewModel.showFeedback(feedback)
                }
                self.withHUDPanel { panel in
                    let screenWidth = panel.presentationScreenWidth()
                    self.hudViewModel.updateStage(screenWidth: screenWidth)
                    self.hudViewModel.updateLayout(
                        HUDLayoutEngine.layout(
                            for: self.hudViewModel.content,
                            screenWidth: screenWidth
                        )
                    )
                    panel.present()
                }
                try? await Task.sleep(for: .seconds(hold))
            }
            self.hudViewModel.clearFeedback()
            self.hudViewModel.update(state: .idle)
            self.withHUDPanel { $0.dismiss(fast: true) }
        }
    }

    /// Development only (`Capabilities.hasLampLab`): the lamp audition.
    func openLampLab() {
        guard Capabilities.current.hasLampLab else {
            return
        }
        let controller: LampLabWindowController
        if let lampLabWindowController {
            controller = lampLabWindowController
        } else {
            controller = LampLabWindowController()
            lampLabWindowController = controller
        }
        controller.present()
    }

    /// The door ticket 011 chose. It opens on `lastHeard` — the engine's
    /// untouched words — because a dictionary entry's `wrong` side has to be
    /// what the engine produced.
    func openWordFixer() {
        guard let lastHeard else {
            return
        }
        openWordFixer(for: lastHeard)
    }

    /// `heard` from either door, run forward to the point the dictionary
    /// reads it. Both doors then show the same words, and the word you point
    /// at is the word an entry will match.
    func openWordFixer(for heard: String) {
        let controller = WordFixerWindowController(
            transcript: DeterministicCleaner(
                entries: dictionaryStore.entries,
                fullCleanup: settings.cleanupEnabled
            ).asHeard(heard),
            store: dictionaryStore,
            fullCleanup: settings.cleanupEnabled
        )
        wordFixerWindowController = controller
        controller.present()
    }

    /// The dashboard's numbers, straight from the same store the copied
    /// report reads — two surfaces disagreeing about one measurement would
    /// be worse than either alone.
    func timingsSummary() -> TimelineSummary {
        timelineStore.summary()
    }

    /// Development only (`Capabilities.canResetInPlace`). Wipes this build's
    /// data and settings with no confirmation and restarts, so onboarding can
    /// be tested on the twentieth run without a trip through Finder. Against a
    /// real archive this would be a foot-gun; against `Andrew Dictate Dev`'s
    /// own folder it is just a fresh start.
    func resetInPlaceForDevelopment() {
        guard Capabilities.current.canResetInPlace else {
            return
        }
        Remover().remove(Set(RemovalPlan.Item.allCases.filter {
            $0 != .speechModels
        }))

        AppRelaunch.now()
    }

    /// Ships in release (ADR 0025). A latency claim measured on a debug build
    /// is not a claim about the app anyone runs — and a number a reader can
    /// reproduce on their own mac is worth more than one in a README.
    func copyTimings() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(
            timelineStore.formattedReport(
                conditions: .current(
                    engine: activeEngineVersion.displayName
                )
            ),
            forType: .string
        )
    }

    func presentOnboardingIfNeeded() {
        guard setupPresentation(moment: .launchOrReopen) == .present else {
            isOnboardingPresented = false
            return
        }
        presentOnboarding(scope: reentryScope)
    }

    /// Someone who has been through setup and lost a grant is not a new user.
    /// `needsPermissionAttention` is already exactly "set up, wants
    /// dictation, cannot dictate", so all three doors back in — launch,
    /// the menu's "finish setup", settings' — get the one-screen version.
    private var reentryScope: OnboardingScope {
        needsPermissionAttention ? .permissionsOnly : .everything
    }

    func runOnboardingAgain(
        scope: OnboardingScope? = nil,
        openAt: OnboardingStep = .hello
    ) {
        presentOnboarding(scope: scope ?? reentryScope, openAt: openAt)
    }

    /// `dictationWanted` is nil when this run of setup had no say in it —
    /// the meetings-only window must not un-set a dictation setup that was
    /// made on an earlier day.
    ///
    /// Last press of a meetings-only run: finish the errand that opened this
    /// window. ADR 0023 says nothing starts a recording but the user naming
    /// an app — they did that before the download, and honouring it is not
    /// the app deciding on its own.
    func finishOnboarding(dictationWanted: Bool? = nil) {
        if let dictationWanted {
            settings.dictationWanted = dictationWanted
        }
        // captured and cleared before the close, because closing the window
        // is also how the errand is cancelled.
        let errand = pendingMeetingApp
        pendingMeetingApp = nil
        dismissOnboarding()

        guard let errand else {
            return
        }
        guard installedMeetingModels.contains(settings.meetingModel) else {
            flashNotice("still downloading the meeting model", duration: 2)
            return
        }
        guard MeetingApps.running().contains(where: { $0.pid == errand.pid })
        else {
            flashNotice(
                "\(MeetingApps.displayName(errand)) isn't running any more",
                duration: 2
            )
            return
        }
        startMeeting(errand)
    }

    /// "skip for now" and "we're done" both close the window. what neither
    /// does any more is claim the setup succeeded — that claim belongs to the
    /// permissions, and they are asked again every time it matters.
    private func dismissOnboarding() {
        hotkeyMonitor.setDetectionOnly(false)
        settings.onboardingDismissed = true
        onboardingWindowController?.close()
    }

    private func setupPresentation(
        moment: SetupCheckMoment
    ) -> SetupPresentation {
        SetupGate.presentation(
            onboardingDismissed: settings.onboardingDismissed,
            permissions: permissions,
            moment: moment,
            dictationWanted: settings.dictationWanted
        )
    }

    func beginOnboardingEnginePreparation() {
        guard isOnboardingPresented else {
            return
        }
        prepareProductiveWaitWork()
        // the view only calls this with dictation ticked, so the click is the
        // ask — even for someone whose last setup was meetings only and whose
        // stored flag still says no.
        requestEnginePreparation(asking: true)
    }

    func onboardingWindowDidClose(
        _ controller: OnboardingWindowController
    ) {
        guard onboardingWindowController === controller else {
            return
        }
        onboardingWindowController = nil
        isOnboardingPresented = false
        hotkeyMonitor.setDetectionOnly(false)
        // anything granted in there was granted to onboarding's own
        // checklist, not to us, so this is the moment to ask the system
        // again — and it is what rebuilds the key monitors under a grant
        // that arrived after launch. midSession, never launchOrReopen: a
        // window must not reopen itself from inside its own close.
        refreshPermissions(moment: .midSession)

        // walking away cancels the errand: nothing starts later out of
        // nowhere.
        pendingMeetingApp = nil
        flushHeldFeedback()
    }

    /// the pill the setup window swallowed, flashed at last — unless it has
    /// aged out, in which case saying it now would be a non-sequitur.
    private func flushHeldFeedback() {
        guard let held = heldFeedback else {
            synchronizeHUD()
            return
        }

        switch HUDFeedbackGate.decide(
            isOnboardingPresented: isOnboardingPresented,
            heldFor: Date().timeIntervalSince(held.at)
        ) {
        case .flashNow:
            heldFeedback = nil
            flashNotice(held.message, duration: held.duration)
        case .hold:
            synchronizeHUD()
        case .drop:
            heldFeedback = nil
            synchronizeHUD()
        }
    }

    func requestMicrophoneAccess() async -> Bool {
        if let audioRecorder {
            return await audioRecorder.requestMicrophoneAccess()
        }

        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    func retryEnginePrewarm() {
        guard enginePreparationState == .failed else {
            return
        }
        // somebody asked for this one, so its outcome is owed an answer —
        // an offline mac prewarming at launch is not.
        retryWasUserInitiated = true
        requestEnginePreparation()
    }

    func prepareForActiveModelRemoval(
        _ version: EngineVersion
    ) async {
        guard version == activeEngineVersion else {
            return
        }

        // whatever was in flight goes with the model, and so does a pill
        // the setup window was holding back about it.
        heldFeedback = nil
        machine.abandon()

        enginePrewarmTask?.cancel()
        enginePrewarmTask = nil
        engineSwapTask?.cancel()
        engineSwapTask = nil
        engineHealthTask?.cancel()
        engineHealthTask = nil
        engineGeneration += 1
        isPrewarmed = false
        enginePreparationState = .notStarted
        engineSwitchMessage = nil
        _ = engineSwitchState.cancelPreparation()
        applyEngineVersionSetting(activeEngineVersion)

        await transcriptionEngine.unloadModels()
    }

    private func presentOnboarding(
        scope: OnboardingScope = .everything,
        openAt: OnboardingStep = .hello
    ) {
        // whatever the pill is saying right now is about to be taken off
        // the screen mid-sentence. keep it rather than truncate it — it
        // gets a whole default reading when it comes back, since how much
        // of the first one had run is not worth tracking.
        if activeFeedbackGeneration != nil,
           let message = hudViewModel.feedbackMessage {
            heldFeedback = (
                message: message,
                duration: 1.2,
                at: Date()
            )
        }
        isOnboardingPresented = true
        hotkeyMonitor.setDetectionOnly(true)
        withHUDPanel { $0.dismiss() }

        // a cached window keeps the scope it was built with, and the screen
        // it was left on — the flow is state inside the view. a different
        // errand means a different window.
        if let onboardingWindowController {
            if onboardingWindowController.scope == scope,
               onboardingWindowController.openAt == openAt {
                onboardingWindowController.present()
                return
            }
            onboardingWindowController.close()
            self.onboardingWindowController = nil
        }

        let controller = OnboardingWindowController(
            coordinator: self,
            scope: scope,
            openAt: openAt,
            proveSystemAudio: { await CoreAudioMeetingSource.proveSystemAudio() },
            prepareMeetingModel: { [weak self] progress in
                await self?.prepareMeetingModel(progress: progress) ?? false
            }
        )
        onboardingWindowController = controller
        controller.present()
    }

    private func applyPreRoll(_ enabled: Bool) {
        guard !isApplyingPreRollSetting,
              let audioRecorder else {
            return
        }

        isApplyingPreRollSetting = true
        defer { isApplyingPreRollSetting = false }

        machine.abandonRecording()

        do {
            try audioRecorder.applyPreRoll(enabled)
        } catch {
            audioLogger.error(
                """
                pre-roll setting failed to apply: \
                \(error.localizedDescription, privacy: .public)
                """
            )
            let appliedMode = audioRecorder.isPreRollEnabled
            Task { [weak self] in
                guard let self,
                      self.settings.preRollEnabled != appliedMode else {
                    return
                }
                self.settings.preRollEnabled = appliedMode
            }
        }
    }

    private func prepareProductiveWaitWork() {
        audioRecorder?.prepareGraph()
    }

    private func replaceEngine(with version: EngineVersion) {
        engineHealthTask?.cancel()
        engineHealthTask = nil
        engineSwitchMessage = nil

        guard isPrewarmed else {
            enginePrewarmTask?.cancel()
            enginePrewarmTask = nil
            engineSwapTask?.cancel()
            engineSwapTask = nil
            activeEngineVersion = version
            engineSwitchState = EngineSwitchState(
                activeVersion: version
            )
            enginePreparationState = enginePreparationRequested
                ? .downloading(progress: 0)
                : .notStarted

            if enginePreparationRequested {
                startPrewarming()
            }
            return
        }

        startEngineSwap(to: version)
    }

    /// `asking` is the caller saying the user just asked for dictation: a
    /// keypress, a consent click, a tick. The stored flag lags those by a
    /// beat (`@Published` publishes in willSet), and consent is consent
    /// whether or not the write has landed yet.
    private func requestEnginePreparation(asking: Bool = false) {
        // a job nobody ticked has no download, at launch or anywhere else.
        guard asking || settings.dictationWanted else {
            return
        }
        enginePreparationRequested = true
        guard !isPrewarmed,
              enginePrewarmTask == nil,
              engineSwapTask == nil else {
            return
        }

        startPrewarming()
    }

    private func startPrewarming(presentsHUD: Bool = true) {
        prewarmPresentsHUD = presentsHUD
        engineSwapTask?.cancel()
        engineSwapTask = nil
        enginePrewarmTask?.cancel()
        engineGeneration += 1
        let generation = engineGeneration
        let version = activeEngineVersion
        isPrewarmed = false
        engineSwitchMessage = nil
        // asked before a byte moves, so the answer cannot be fooled by how
        // the progress callbacks happen to land.
        engineModelWasOnDisk = ModelStore.isOnDisk(version)
        enginePreparationState = .downloading(progress: 0)
        machine.enginePreparing()

        enginePrewarmTask = Task { [weak self] in
            guard let self else {
                return
            }
            await self.transcriptionEngine.cancelPreparation()
            await self.transcriptionEngine
                .selectVersionForBlockingPreparation(version)
            guard !Task.isCancelled,
                  generation == self.engineGeneration else {
                return
            }

            do {
                try await self.transcriptionEngine.prewarm {
                    [weak self] update in
                    Task { @MainActor [weak self] in
                        self?.applyPreparationUpdate(
                            update,
                            generation: generation
                        )
                    }
                }
                try Task.checkCancellation()
                guard generation == self.engineGeneration else {
                    return
                }
                self.isPrewarmed = true
                self.enginePreparationState = .ready
                self.enginePrewarmTask = nil
                self.retryWasUserInitiated = false
                self.machine.engineSettled()
            } catch is CancellationError {
                return
            } catch {
                guard generation == self.engineGeneration else {
                    return
                }
                let wasAsked = self.retryWasUserInitiated
                self.retryWasUserInitiated = false
                self.enginePrewarmTask = nil
                self.enginePreparationState = .failed
                self.engineLogger.error(
                    """
                    engine prewarm failed: \
                    \(error.localizedDescription, privacy: .public)
                    """
                )
                self.machine.engineSettled()
                // the retry announced itself ("speech model failed —
                // retrying"); its failure must not be quieter than its
                // beginning, or the key just stops answering.
                if wasAsked {
                    self.flashNotice(
                        "speech model didn't download — finish setup",
                        duration: 4
                    )
                }
            }
        }
    }

    private func startEngineSwap(to version: EngineVersion) {
        engineSwapTask?.cancel()
        enginePrewarmTask?.cancel()
        enginePrewarmTask = nil
        engineGeneration += 1
        let generation = engineGeneration

        guard engineSwitchState.beginPreparing(version) else {
            enginePreparationState = .ready
            engineSwitchMessage = nil
            engineSwapTask = Task { [weak self] in
                guard let self else {
                    return
                }
                await self.transcriptionEngine.cancelPreparation()
                guard generation == self.engineGeneration else {
                    return
                }
                self.engineSwapTask = nil
            }
            return
        }

        let currentVersion = engineSwitchState.activeVersion
        engineModelWasOnDisk = ModelStore.isOnDisk(version)
        enginePreparationState = .downloading(progress: 0)
        engineSwitchMessage = nil
        engineLogger.notice(
            "engine swap start from=\(currentVersion.rawValue) to=\(version.rawValue)"
        )

        engineSwapTask = Task { [weak self] in
            guard let self else {
                return
            }
            await self.transcriptionEngine.cancelPreparation()
            guard !Task.isCancelled,
                  generation == self.engineGeneration else {
                return
            }

            do {
                try await self.transcriptionEngine.prepareAndSwap(
                    to: version
                ) { [weak self] update in
                    Task { @MainActor [weak self] in
                        self?.applyPreparationUpdate(
                            update,
                            generation: generation
                        )
                    }
                }
                try Task.checkCancellation()
                guard generation == self.engineGeneration else {
                    return
                }

                let resolution = self.engineSwitchState
                    .resolvePreparation(
                        for: version,
                        outcome: .ready
                    )
                guard case let .swapped(_, activeVersion) = resolution
                else {
                    return
                }

                self.activeEngineVersion = activeVersion
                self.enginePreparationState = .ready
                self.engineSwitchMessage = nil
                self.engineSwapTask = nil
                self.engineLogger.notice(
                    "engine swap ready active=\(activeVersion.rawValue)"
                )
            } catch is CancellationError {
                return
            } catch {
                guard generation == self.engineGeneration else {
                    return
                }

                let resolution = self.engineSwitchState
                    .resolvePreparation(
                        for: version,
                        outcome: .failed
                    )
                guard case let .reverted(
                    settingVersion,
                    message
                ) = resolution else {
                    return
                }

                self.enginePreparationState = .ready
                self.engineSwitchMessage = message
                self.engineSwapTask = nil
                self.applyEngineVersionSetting(settingVersion)
                self.engineLogger.error(
                    "engine swap failed target=\(version.rawValue): \(error.localizedDescription)"
                )
                await self.flashFeedback(message, duration: 2)
            }
        }
    }

    private func applyEngineVersionSetting(_ version: EngineVersion) {
        guard settings.engineVersion != version else {
            return
        }

        isApplyingEngineVersionSetting = true
        settings.engineVersion = version
        isApplyingEngineVersionSetting = false
    }

    private func applyPreparationUpdate(
        _ update: TranscriptionPreparationUpdate,
        generation: Int
    ) {
        guard generation == engineGeneration,
              enginePrewarmTask != nil || engineSwapTask != nil else {
            return
        }

        switch update {
        case let .downloading(progress):
            let boundedProgress = min(max(progress, 0), 1)
            if case let .downloading(currentProgress) =
                enginePreparationState {
                enginePreparationState = .downloading(
                    progress: max(currentProgress, boundedProgress)
                )
            } else {
                enginePreparationState = .downloading(
                    progress: boundedProgress
                )
            }
        case .warmingUp:
            enginePreparationState = .warmingUp
        }
    }

    private func installSystemLifecycleObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.willSleepNotification,
            NSWorkspace.didWakeNotification
        ] {
            let observer = workspaceCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let isSleep =
                    notification.name == NSWorkspace.willSleepNotification
                Task { @MainActor [weak self] in
                    if isSleep {
                        self?.handleCaptureInterruption(
                            reason: .systemPaused
                        )
                    } else {
                        self?.handleSystemResume()
                    }
                }
            }
            workspaceNotificationObservers.append(observer)
        }

        let distributedCenter = DistributedNotificationCenter.default()
        let lockedName = Notification.Name("com.apple.screenIsLocked")
        let unlockedName = Notification.Name("com.apple.screenIsUnlocked")
        for name in [lockedName, unlockedName] {
            let observer = distributedCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let isLock = notification.name == lockedName
                Task { @MainActor [weak self] in
                    if isLock {
                        self?.handleCaptureInterruption(
                            reason: .systemPaused
                        )
                    } else {
                        self?.handleSystemResume()
                    }
                }
            }
            distributedNotificationObservers.append(observer)
        }

        // a second copy just refused to run and quit (AndrewDictateApp): it
        // cannot draw anything itself, so the copy that is running says where
        // it is. 2 s, like the other pill that points somewhere — the 1.2 s
        // default is not long enough to read a sentence.
        let alreadyRunningObserver = distributedCenter.addObserver(
            forName: .andrewDictateAlreadyRunning,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.flashNotice(
                    "already running — it's in the menu bar",
                    duration: 2
                )
            }
        }
        distributedNotificationObservers.append(alreadyRunningObserver)

        let trustObserver = distributedCenter.addObserver(
            forName: SystemPermissions.accessibilityChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshPermissions(moment: .midSession)
            }
        }
        distributedNotificationObservers.append(trustObserver)
    }

    /// the only way to know. asks the system, publishes the answer, and lets
    /// the gate decide whether that answer is worth interrupting anyone over.
    @discardableResult
    func refreshPermissions(
        moment: SetupCheckMoment
    ) -> SetupPresentation {
        let hadAccessibility = permissions.accessibilityGranted
        let snapshot = SystemPermissions.snapshot()
        if snapshot != permissions {
            permissions = snapshot
            if !snapshot.isDictationReady {
                permissionLogger.notice(
                    """
                    permission missing — mic: \
                    \(snapshot.microphoneGranted, privacy: .public), \
                    accessibility: \
                    \(snapshot.accessibilityGranted, privacy: .public)
                    """
                )
            }
        }

        if SetupGate.shouldReinstallHotkey(
            was: hadAccessibility,
            now: snapshot.accessibilityGranted
        ) {
            hotkeyMonitor.reinstall()
            permissionLogger.notice(
                "hotkey monitors reinstalled after trust change"
            )
        }

        let presentation = SetupGate.presentation(
            onboardingDismissed: settings.onboardingDismissed,
            permissions: snapshot,
            moment: moment,
            dictationWanted: settings.dictationWanted
        )

        // losing accessibility kills the global event monitor itself, so no
        // key press is left to answer for it — unlike the mic, which gets
        // caught at the point of use. the transition guard makes this fire
        // once: the next notification already sees it gone.
        if hadAccessibility,
           !snapshot.accessibilityGranted,
           presentation == .badgeOnly {
            announcePermissionGap(
                "accessibility is off — the dictation key is dead",
                duration: 2.6
            )
        }

        return presentation
    }

    /// the user double-clicked the app while it was already living in the
    /// menu bar — for a window-less app, that is what "reopening" means.
    func handleReopen() {
        guard refreshPermissions(moment: .launchOrReopen) == .present else {
            return
        }
        presentOnboarding()
    }

    /// says it where the user is already looking, without taking the screen.
    private func announcePermissionGap(
        _ message: String,
        duration: TimeInterval = 1.8
    ) {
        guard state == .idle else {
            return
        }

        flashNotice(message, duration: duration)
    }

    private func flashNotice(
        _ message: String,
        duration: TimeInterval = 1.6
    ) {
        Task { @MainActor [weak self] in
            await self?.flashFeedback(message, duration: duration)
        }
    }

    /// the recorder can fail to build at launch — no input device yet — and
    /// that answer was kept forever. ask again when the user asks to record:
    /// by then the headset may well be back on.
    private func ensureAudioRecorder() -> AudioRecorder? {
        if let audioRecorder {
            return audioRecorder
        }

        do {
            let recorder = try AudioRecorder(
                preRollEnabled: settings.preRollEnabled
            )
            recorder.onInterruption = { [weak self] reason in
                self?.handleCaptureInterruption(reason: reason)
            }
            recorder.onCapReached = { [weak self] in
                self?.handleCaptureCapReached()
            }
            recorder.onCapApproaching = { [weak self] in
                self?.machine.capApproaching()
            }
            audioRecorder = recorder
            hudViewModel.useRecorder(recorder)
            audioLogger.notice("audio recorder rebuilt on demand")
            return recorder
        } catch {
            audioLogger.error(
                """
                audio recorder still unavailable: \
                \(error.localizedDescription, privacy: .public)
                """
            )
            return nil
        }
    }

    private func handleCaptureCapReached() {
        guard machine.capReached() else {
            return
        }
        // the key was never released. without this a hands-free lock reads
        // the next press as the end of a take that is already finished.
        hotkeyMonitor.reset()
    }

    private func handleCaptureInterruption(
        reason: CaptureInterruption
    ) {
        machine.captureInterrupted(reason)
        hotkeyMonitor.reset()
    }

    private func handleSystemResume() {
        hotkeyMonitor.reset()
        verifyEngineHealth()
        // a meeting is meant to survive the sleep, not be cancelled by it —
        // but the tap rarely does, and a frozen clock reads as a meeting
        // that was heard all the way through (SPEC §11).
        if meetings.isRecording {
            meetings.probeTapIsAlive()
        }
        // waking or unlocking is not the user coming to *us* — check, but
        // never take the screen back from whatever they returned to.
        refreshPermissions(moment: .midSession)
    }

    private func verifyEngineHealth() {
        guard isPrewarmed else {
            return
        }

        engineHealthTask?.cancel()
        let engine = transcriptionEngine
        let generation = engineGeneration
        engineHealthTask = Task { @MainActor [weak self] in
            do {
                try await engine.prewarm(progressHandler: nil)
                try Task.checkCancellation()
                guard let self,
                      generation == self.engineGeneration else {
                    return
                }
                self.engineHealthTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      generation == self.engineGeneration else {
                    return
                }
                self.engineHealthTask = nil
                self.isPrewarmed = false
                self.enginePreparationState = .failed
                self.engineLogger.error(
                    """
                    engine health check failed: \
                    \(error.localizedDescription, privacy: .public)
                    """
                )
                if self.state == .prewarming {
                    self.machine.engineSettled()
                }
            }
        }
    }

    private func beginRecording(locked: Bool) {
        // ADR 0023: refused during a meeting, and it says why. you started
        // the recording, so a dead hotkey is not a mystery — but a silent
        // one would still be spec §4's forbidden shape.
        if meetings.dictationResponse == .refuseAndSayWhy {
            flashNotice("recording a meeting — stop it to dictate", duration: 2)
            return
        }
        if locked {
            machine.doubleTapped()
        } else {
            machine.keyDown()
        }
    }

    /// the app's half of a press, asked by the machine once its own answers
    /// (a retry on offer, a sentence still being written out) are spent: a
    /// speech model, a mic grant, an input device. nil means the press has
    /// been answered here.
    private func microphoneForPress() -> AudioRecorder? {
        guard isPrewarmed else {
            // the key is a statement of intent: from here the ember is an
            // answer, so it may show even if the warm-up began at login.
            prewarmPresentsHUD = true
            // read before the switch: `.notStarted` starts the download,
            // which sets `.downloading(progress: 0)` synchronously and would
            // turn the press that priced it into "0%".
            let size = activeEngineVersion.approximateSize.dropFirst()
            let notice = enginePreparationState.pressedEarlyNotice(
                downloadSize: "about \(size)"
            )
            switch enginePreparationState {
            case .notStarted:
                // a mac set up for meetings only has no model and no menu
                // row offering one, so this keypress is both the consent the
                // launch stopped assuming and the only way back in. say what
                // it costs, once — silence here would be a download behind
                // your back by another route.
                if !settings.dictationWanted {
                    settings.dictationWanted = true
                    flashNotice(
                        """
                        getting the speech model — \
                        \(settings.engineVersion.approximateSize), once
                        """,
                        duration: 2
                    )
                }
                requestEnginePreparation(asking: true)
            case .failed:
                // pressing the key is a statement of intent, and a failed
                // model download is usually a blip. try again, out loud —
                // the alternative is a lamp that breathes forever.
                retryEnginePrewarm()
                flashNotice("speech model failed — retrying")
                return nil
            case .downloading, .warmingUp, .ready:
                break
            }
            if state != .prewarming {
                machine.enginePreparing()
            } else {
                // already warming from launch, with nothing on screen —
                // light it now rather than at the next state change.
                synchronizeHUD()
            }
            // the ember breathing at bottom-centre is the only thing a
            // download has ever said, and only the menu knew why. the press
            // could not be honoured, so answer it.
            if let notice {
                flashNotice(notice)
            }
            return nil
        }
        // the one grant we can verify at the point of use: if the hotkey
        // reached us at all, accessibility is alive. the mic may not be.
        guard SystemPermissions.snapshot().microphoneGranted else {
            refreshPermissions(moment: .midSession)
            announcePermissionGap("microphone access is off")
            return nil
        }
        guard let audioRecorder = ensureAudioRecorder() else {
            flashNotice("no microphone available")
            return nil
        }
        return audioRecorder
    }

    /// the menu's door to the samples the engine threw on; a press while the
    /// pill still says so is the other.
    func retryLastFailure() {
        machine.retryLastFailure()
    }

    /// the machine decides what is worth keeping; whether dictations are
    /// kept at all is a setting, and the file is the archive's.
    private func archive(
        _ timeline: UtteranceTimeline,
        heard: String,
        inserted: String
    ) {
        guard settings.keepDictations else {
            return
        }

        do {
            try dictationArchive.append(
                Dictation(
                    // wall-clock start, worked back from the timeline. `Date()`
                    // here would be the moment it *finished*, which is a
                    // different thing and would make the field a lie.
                    startedAt: Date(
                        timeIntervalSinceNow:
                            -timeline.durations.total.inMilliseconds / 1_000
                    ),
                    heard: heard,
                    inserted: inserted,
                    engine: activeEngineVersion.rawValue,
                    keyUpToInsertedMilliseconds:
                        timeline.durations.keyUpToCompletion.inMilliseconds
                )
            )
        } catch {
            // Never interrupt a dictation over bookkeeping. The settings pane
            // reports the archive's real state; this is not the place.
            cleanupLogger.error("could not keep this dictation")
        }
    }

    /// what a shown pill carries to its own expiry: a newer pill, or any
    /// state change in between, means the clear is no longer this pill's.
    private struct ShownFeedback {
        let feedbackToken: UInt64
        let stateToken: UInt64
        let lasts: TimeInterval
    }

    private func flashFeedback(
        _ message: String,
        duration: TimeInterval
    ) async {
        guard let shown = showFeedback(message, duration: duration) else {
            return
        }
        await expireFeedback(shown)
    }

    /// the half of a pill that happens now. apart from its expiry so a pill
    /// the machine owes lands in the same turn as the state change it
    /// follows. nil when the setup window is holding it instead.
    private func showFeedback(
        _ message: String,
        duration: TimeInterval
    ) -> ShownFeedback? {
        // the setup window force-dismissed the panel, so the sleep-then-
        // clear would run against something nobody can see and the
        // sentence would be lost for good. hold it; closing setup says it.
        if HUDFeedbackGate.decide(
            isOnboardingPresented: isOnboardingPresented,
            heldFor: nil
        ) == .hold {
            heldFeedback = (
                message: message,
                duration: duration,
                at: Date()
            )
            return nil
        }

        feedbackGeneration += 1
        let feedbackToken = feedbackGeneration
        let stateToken = stateGeneration
        activeFeedbackGeneration = feedbackToken
        hudViewModel.showFeedback(message)
        // the pill is a non-key, click-through panel, so voiceover never
        // visits it. without this, a failed dictation and a successful one
        // are the same silence to someone who cannot look.
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
        synchronizeHUD()

        // a pill that wraps to two lines is two reads. measured here rather
        // than read off hudViewModel.layout, which synchronizeHUD only sets
        // a run-loop turn later.
        let screenWidth = hudPanelStorage?.presentationScreenWidth()
            ?? NSScreen.main?.frame.width
            ?? 1_440
        let lineCount = HUDLayoutEngine.layout(
            for: .text(message),
            screenWidth: screenWidth
        ).lineCount
        return ShownFeedback(
            feedbackToken: feedbackToken,
            stateToken: stateToken,
            lasts: duration + (lineCount == 2 ? 0.6 : 0)
        )
    }

    private func expireFeedback(_ shown: ShownFeedback) async {
        try? await Task.sleep(for: .seconds(shown.lasts))
        guard shown.stateToken == stateGeneration,
              shown.feedbackToken == feedbackGeneration,
              activeFeedbackGeneration == shown.feedbackToken else {
            return
        }

        activeFeedbackGeneration = nil
        hudViewModel.clearFeedback()
        synchronizeHUD()
    }

    /// the machine's state, worn by the panel and mirrored for the menu.
    private func apply(
        _ newState: State,
        fastHUDDismiss: Bool
    ) {
        if newState == .recording {
            // they have moved on and are talking again; a held sentence
            // about the last take would land on this one.
            heldFeedback = nil
        }
        stateGeneration += 1
        feedbackGeneration += 1
        activeFeedbackGeneration = nil
        state = newState
        hudViewModel.update(state: newState)

        synchronizeHUD(fastDismiss: fastHUDDismiss)
    }

    private func synchronizeHUD(fastDismiss: Bool = false) {
        withHUDPanel { [weak self] panel in
            guard let self else {
                return
            }

            guard HUDPresentation.shouldPresent(
                state: self.state.lamp,
                hasFeedback: self.activeFeedbackGeneration != nil,
                isOnboarding: self.isOnboardingPresented,
                prewarmPresentsHUD: self.prewarmPresentsHUD
            ) else {
                panel.dismiss(fast: fastDismiss)
                return
            }

            let screenWidth = panel.presentationScreenWidth()
            self.hudViewModel.updateStage(screenWidth: screenWidth)
            self.hudViewModel.updateLayout(
                HUDLayoutEngine.layout(
                    for: self.hudViewModel.content,
                    screenWidth: screenWidth
                )
            )
            panel.present()
        }
    }
}

// MARK: - the utterance machine

extension DictationCoordinator {
    /// the machine asks two questions only this side can answer, and says
    /// everything else through one callback.
    private func wireMachine() {
        machine.onEvent = { [weak self] event in
            self?.handle(event)
        }
        machine.microphoneForPress = { [weak self] in
            self?.microphoneForPress()
        }
        machine.isPillShowing = { [weak self] in
            self?.activeFeedbackGeneration != nil
        }
    }

    private func handle(_ event: UtteranceEvent) {
        switch event {
        case let .state(state, fastDismiss):
            apply(state, fastHUDDismiss: fastDismiss)
        case let .chime(chime):
            guard !isOnboardingPresented else {
                return
            }
            feedbackSounds.play(chime == .start ? .start : .end)
        case let .pill(message, duration):
            guard let shown = showFeedback(message, duration: duration) else {
                return
            }
            Task { @MainActor [weak self] in
                await self?.expireFeedback(shown)
            }
        case let .locked(locked):
            hudViewModel.setRecordingLocked(locked)
        case let .timelineCompleted(timeline):
            timelineStore.append(timeline)
        case let .archiveRecord(timeline, heard, inserted):
            archive(timeline, heard: heard, inserted: inserted)
        case let .dictated(text):
            settings.recordDictatedTranscript(text)
        case let .transcribed(heard, inserted):
            lastTranscript = inserted
            lastHeard = heard
        case let .retryOffered(offered):
            canRetryLastFailure = offered
        case .microphoneDropped:
            audioRecorder = nil
            hudViewModel.useRecorder(nil)
        }
    }
}

// MARK: - meetings

extension DictationCoordinator {
    var installedMeetingModels: Set<MeetingModel> {
        MeetingEngines.installed()
    }

    var meetingAppName: String {
        meetings.app.map(MeetingApps.displayName) ?? ""
    }

    /// What setup's last button should promise, when an errand is waiting.
    var pendingMeetingAppName: String? {
        pendingMeetingApp.map(MeetingApps.displayName)
    }

    /// `record a meeting ▸ zoom`. the model is a download you may not have
    /// asked for yet: then this is the route back to the one surface that
    /// knows how to ask (SPEC §5).
    func startMeeting(_ app: RunningApp) {
        guard !meetings.isRecording else { return }
        guard installedMeetingModels.contains(settings.meetingModel) else {
            pendingMeetingApp = app
            runOnboardingAgain(scope: .meetingsOnly)
            return
        }
        if state == .recording {
            flashNotice("finish dictating first")
            return
        }
        liveTranscript.clear()
        liveTranscript.app = MeetingApps.displayName(app)
        liveTranscript.elapsed = .zero
        Task { [meetingNotifier] in
            await meetingNotifier.requestPermissionIfNeeded()
        }
        meetings.start(tapping: app)
    }

    func stopMeeting() {
        meetingNotifier.withdraw()
        meetings.stop()
    }

    /// A quit can arrive from the menu, from ⌘Q, or from brew asking the app
    /// to go so it can replace the bundle under it (the cask's
    /// `uninstall quit:`). A meeting recording is one of the two durable
    /// nouns, so a quit that lands mid-meeting stops it first and waits for
    /// the markdown — `finishQuitting()` answers when the transcript is
    /// written, and the ceiling answers if whisper is still flushing.
    func prepareToQuit() -> NSApplication.TerminateReply {
        guard meetings.isRecording else {
            return .terminateNow
        }
        quitWaitingOnMeeting = true
        stopMeeting()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(20))
            self?.finishQuitting()
        }
        return .terminateLater
    }

    /// The transcript is on disk (or it never will be). Either way the quit
    /// gets its answer once, and a second call is a no-op.
    private func finishQuitting() {
        guard quitWaitingOnMeeting else {
            return
        }
        quitWaitingOnMeeting = false
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    func toggleLiveTranscript() {
        let panel = liveTranscriptPanel ?? makeLiveTranscriptPanel()
        panel.toggle()
    }

    private func makeLiveTranscriptPanel() -> LiveTranscriptPanel {
        let panel = LiveTranscriptPanel(model: liveTranscript)
        panel.onVisibilityChange = { [weak self] shown in
            self?.isLiveTranscriptShown = shown
        }
        liveTranscriptPanel = panel
        return panel
    }

    private func wireMeetings() {
        meetings.onEvent = { [weak self] event in
            self?.handle(event)
        }
        meetings.onLine = { [weak self] line in
            self?.liveTranscript.upsert(line)
        }
        meetings.recordHookRun = { [weak self] run in
            self?.settings.meetingHookLastRunAt = run.finishedAt
            self?.settings.meetingHookLastRunLabel = run.outcome.label
        }
        meetings.$elapsed
            .sink { [weak self] elapsed in
                self?.liveTranscript.elapsed = elapsed
            }
            .store(in: &meetingCancellables)
        // The menu observes *this* object, not the one nested inside it: a
        // meeting that starts without this line leaves the menu drawing the
        // idle version, with no way to stop what it cannot see.
        meetings.$state
            .removeDuplicates()
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &meetingCancellables)
        meetings.$elapsed
            .map { $0.components.seconds }
            .removeDuplicates()
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &meetingCancellables)
        // same reason as the two above: the menu watches this object, and
        // the recovery line lives on the one nested inside it.
        meetings.$recovering
            .removeDuplicates()
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &meetingCancellables)
        meetingNotifier.onKeepGoing = { [weak self] in
            self?.meetings.keepGoing()
        }
        meetingNotifier.onStop = { [weak self] in
            self?.stopMeeting()
        }
        meetingNotifier.onShowFile = { url in
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        // transcripts written before the app started locking them down are
        // still 0644 — other people's words, readable by every account on
        // the machine. repaired once, off the main thread.
        let folder = settings.meetingsFolder
        Task.detached(priority: .utility) {
            MeetingTranscriptFile.lockDown(in: folder)
        }
        // recovery loads the meeting model and can run for a quarter of an
        // hour. five seconds of head start keeps it off the dictation
        // model's prewarm, so the first fn press is not slower for it. the
        // number is a guess, like the rest of MeetingThresholds.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.meetings.recoverOrphans()
        }
    }

    private func handle(_ event: MeetingEvent) {
        switch event {
        case .started:
            meetingsNeedAttention = false
            if LiveTranscriptPanel.wasOpenLastTime(), !isLiveTranscriptShown {
                toggleLiveTranscript()
            }
        case .nudge:
            meetingNotifier.ask(app: meetingAppName, quietFor: meetings.thresholds.quietNudgeAfter)
        case .saved(let summary):
            liveTranscriptPanel?.dismissKeepingPreference()
            // the file *is* the feature, and the pill that names it is gone
            // in two seconds — often before you are back at the mac.
            lastMeeting = summary
            lastMeetingSavedAt = Date()
            meetingNotifier.saved(summary)
            // the transcript has landed, so a quit that was waiting on it
            // can go through. the hook runs after this and may not finish;
            // the file it was told about is already written.
            finishQuitting()
        case .saveFailed:
            liveTranscriptPanel?.dismissKeepingPreference()
            meetingNotifier.saveFailed()
            // nothing more will be written, so a quit waiting on the file
            // goes through here too.
            finishQuitting()
        case .nothingToKeep, .engineFailed:
            liveTranscriptPanel?.dismissKeepingPreference()
            finishQuitting()
        case .cannotHear:
            // the pill cannot be clicked, so naming the switch was a dead
            // end. this reopens the one surface allowed to ask for it, and
            // leaves a way back in the menu for anyone who closes it.
            meetingsNeedAttention = true
            liveTranscriptPanel?.dismissKeepingPreference()
            runOnboardingAgain(scope: .meetingsOnly, openAt: .permissions)
        case .recovering, .gapBegan, .gapEnded, .writingItOut, .hookFailed:
            break
        }

        if let text = event.hudText {
            let duration: TimeInterval
            switch event {
            case .hookFailed, .engineFailed, .saveFailed: duration = 4
            // a recovered meeting arrives unprompted and is about yesterday:
            // two seconds is not long enough to read it.
            case .saved(let summary): duration = summary.recovered ? 4 : 2
            case .writingItOut, .recovering: duration = 6
            default: duration = 2
            }
            flashNotice(text, duration: duration)
        }
    }

    private func prepareMeetingModel(progress: @escaping @Sendable (Double) -> Void) async -> Bool {
        let model = settings.meetingModel
        meetingModelDownloads[model] = 0
        let ok = await MeetingEngines.prepare(model) { [weak self] value in
            progress(value)
            Task { @MainActor in self?.meetingModelDownloads[model] = value }
        }
        meetingModelDownloads[model] = nil
        return ok
    }
}


/// development only: dump a window's layer tree with the properties that
/// could carry an active/inactive look, to diff the panel against the lab.
enum HUDHierarchyDump {
    static let keys = [
        "effect", "filters", "compositingFilter", "backgroundFilters",
        "opacity", "hidden", "mode", "operation", "enabled",
        "windowServerAware", "smoothness", "gaussianRadius", "effectOffset",
        "mergeElements", "contentsZeroValueDistance",
        "contentsOneValueDistance", "gradientOvalization", "backgroundColor",
        "cornerRadius", "allowsGroupOpacity", "scale",
        "substituteColor", "allowsSubstituteColor", "bleedAmount",
    ]

    private static func valueSize(_ value: NSValue) -> Int {
        var size = 0
        var align = 0
        NSGetSizeAndAlignment(value.objCType, &size, &align)
        return size
    }

    static func write(window: NSWindow, to path: String) {
        var out: [String] = [
            "window \(NSStringFromClass(type(of: window))) isKey=\(window.isKeyWindow) isMain=\(window.isMainWindow) appActive=\(NSApp.isActive)"
        ]
        func walkLayer(_ l: CALayer, _ depth: Int) {
            let pad = String(repeating: "  ", count: depth)
            var props: [String] = []
            for key in keys where l.responds(to: Selector(key)) {
                let v = l.value(forKey: key)
                props.append("\(key)=\(v.map { "\($0)" } ?? "nil")")
            }
            for f in (l.filters ?? []) as? [NSObject] ?? [] {
                props.append("filter \(f)")
                if let keys = f.value(forKey: "inputKeys") as? [String] {
                    for k in keys {
                        let v = f.value(forKey: k)
                        if let value = v as? NSValue,
                           valueSize(value) == 80 {
                            // a CAColorMatrix: 20 floats, rows R G B A, columns r g b a bias
                            var floats = [Float](repeating: 0, count: 20)
                            floats.withUnsafeMutableBytes { value.getValue($0.baseAddress!, size: 80) }
                            props.append("   \(k)=floats\(floats.map { String(format: "%.4f", $0) })")
                        } else if let v {
                            props.append("   \(k)=\(type(of: v)) \(v)")
                        } else {
                            props.append("   \(k)=\(v.map { "\($0)" } ?? "nil")")
                        }
                    }
                }
            }
            if l.responds(to: Selector("effect")),
               let e = l.value(forKey: "effect") as? NSObject {
                var pc: UInt32 = 0
                if let plist = class_copyPropertyList(type(of: e), &pc) {
                    for i in 0..<Int(pc) {
                        let k = String(cString: property_getName(plist[i]))
                        props.append("effect.\(k)=\(e.value(forKey: k).map { "\($0)" } ?? "nil")")
                    }
                    free(plist)
                }
            }
            out.append("\(pad)L \(NSStringFromClass(type(of: l))) frame=\(l.frame)")
            for p in props { out.append("\(pad)    \(p)") }
            for sub in l.sublayers ?? [] { walkLayer(sub, depth + 1) }
        }
        if let layer = window.contentView?.layer {
            walkLayer(layer, 0)
        }
        try? out.joined(separator: "\n").write(
            toFile: path,
            atomically: true,
            encoding: .utf8
        )
    }
}
