import Combine
import OSLog
import Foundation
import AppKit
import AVFoundation

enum EnginePreparationState: Equatable, Sendable {
    case notStarted
    case downloading(progress: Double)
    case warmingUp
    case ready
    case failed

    var isReady: Bool {
        self == .ready
    }
}

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
    private let pipelineLogger = Logger(
        subsystem: AppIdentity.loggingSubsystem,
        category: "pipeline"
    )
    private let permissionLogger = Logger(
        subsystem: AppIdentity.loggingSubsystem,
        category: "permissions"
    )
    enum State: Equatable, Sendable {
        case idle
        case prewarming
        case recording
        case transcribing

        var displayName: String {
            switch self {
            // Said the way a person would say it. "prewarming" and "idle" are
            // words for whoever wrote the state machine — the menu is read by
            // someone who wants to know whether they can talk yet.
            case .idle:
                "ready"
            case .prewarming:
                "loading the speech model…"
            case .recording:
                "listening"
            case .transcribing:
                "writing it out…"
            }
        }

    }

    @Published private(set) var state: State = .prewarming
    @Published private(set) var enginePreparationState:
        EnginePreparationState = .notStarted
    @Published private(set) var activeEngineVersion: EngineVersion
    @Published private(set) var engineSwitchMessage: String?
    @Published private(set) var hotkeyDetection: HotkeyDetection?
    @Published private(set) var lastTranscript: String?
    /// re-read at launch, reopen, wake, unlock, and whenever the system says
    /// the trust table moved. a grant is a fact about now, not a fact we own.
    @Published private(set) var permissions = PermissionSnapshot(
        microphoneGranted: false,
        accessibilityGranted: false
    )

    var needsPermissionAttention: Bool {
        settings.onboardingDismissed && !permissions.isDictationReady
    }

    let dictionaryStore: DictionaryStore
    let settings: AppSettings

    private let hotkeyMonitor: HotkeyMonitor
    private let transcriptionEngine: ParakeetEngine
    private let paster: Paster
    /// var, not let: the input node can be missing at launch (headset off,
    /// dock unplugged) and arrive later. one failed build must not be final.
    private var audioRecorder: AudioRecorder?
    private let feedbackSounds: FeedbackSounds
    private let transcriptPolisher = FoundationModelPolisher()
    private let cleanupLabStore = LabStore()
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
    /// a double-tapped key leaves nothing to hold, so nothing to feel. the
    /// HUD has to carry the difference for as long as the capture runs.
    private var isRecordingLocked = false
    private var activeFocusAnchor: FocusAnchor?
    private var pipelineTask: Task<Void, Never>?
    private var pipelineGeneration = 0
    private var enginePrewarmTask: Task<Void, Never>?
    private var engineSwapTask: Task<Void, Never>?
    private var engineHealthTask: Task<Void, Never>?
    private var engineGeneration = 0
    private var engineSwitchState: EngineSwitchState
    private var enginePreparationRequested: Bool
    private var settingsCancellables: Set<AnyCancellable> = []
    private var isApplyingPreRollSetting = false
    private var isApplyingEngineVersionSetting = false
    private var onboardingWindowController: OnboardingWindowController?
    private var isOnboardingPresented: Bool
    private var hotkeyDetectionSequence = 0
    private var stateGeneration: UInt64 = 0
    private var transcribingBeganAt: Date?
    private var feedbackGeneration: UInt64 = 0
    private var activeFeedbackGeneration: UInt64?
    private let timelineClock = ContinuousClock()
    private let timelineStore = UtteranceTimelineStore()
    private var timelineSequence: UInt64 = 0
    private var activeTimeline: UtteranceTimelineBuilder?
    private var aboutWindowController: AboutWindowController?
    private var cleanupLabWindowController: CleanupLabWindowController?
    private var pipelineWindowController: PipelineWindowController?
    /// Rebuilt per transcript rather than reused: the window is *about* one
    /// dictation, so keeping a stale one around would show the wrong words.
    private let dictationArchive = DictationArchive()
    /// Held between delivery and the timeline completing, because that is the
    /// one place that knows whether anything actually reached the page.
    private var pendingArchiveText: (heard: String, inserted: String)?
    private var wordFixerWindowController: WordFixerWindowController?
    private var workspaceNotificationObservers: [NSObjectProtocol] = []
    private var distributedNotificationObservers: [NSObjectProtocol] = []

    init(settings: AppSettings = .shared) {
        self.settings = settings
        activeEngineVersion = settings.engineVersion
        engineSwitchState = EngineSwitchState(
            activeVersion: settings.engineVersion
        )
        isOnboardingPresented = !settings.onboardingDismissed
        enginePreparationRequested = settings.onboardingDismissed
        dictionaryStore = DictionaryStore()
        transcriptionEngine = ParakeetEngine(
            version: settings.engineVersion
        )
        let paster = Paster()
        self.paster = paster

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

        let viewModel = HUDViewModel(
            state: .prewarming,
            audioRecorder: recorder
        )
        hudViewModel = viewModel

        let monitor = HotkeyMonitor(settings: settings)
        hotkeyMonitor = monitor

        monitor.onBegin = { [weak self] in
            self?.beginRecording()
        }
        monitor.onEnd = { [weak self] in
            self?.endRecording()
        }
        monitor.onCancel = { [weak self] in
            self?.cancelRecording()
        }
        monitor.onLockBegin = { [weak self] in
            self?.beginLockedRecording()
        }
        monitor.onLockEnd = { [weak self] in
            self?.endRecording()
        }
        monitor.onLockCancel = { [weak self] in
            self?.cancelRecording()
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
            self?.handleEscape() ?? false
        }
        recorder?.onInterruption = { [weak self] in
            self?.handleCaptureInterruption()
        }
        recorder?.onCapReached = { [weak self] in
            self?.handleCaptureCapReached()
        }

        settings.$preRollEnabled
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] enabled in
                self?.applyPreRoll(enabled)
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

        installSystemLifecycleObservers()

        // a build that doesn't keep the lab must also not inherit the log an
        // earlier version wrote — the toggle-less transcript file goes.
        if !Capabilities.current.keepsCleanupLab {
            Task { [cleanupLabStore] in
                try? await cleanupLabStore.clear()
            }
        }

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
            startPrewarming()
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

    var isCleanupAvailable: Bool {
        transcriptPolisher.isAvailable
    }

    /// nil when cleanup can run; otherwise the reason and the user's next
    /// move, straight from the os rather than a guess about it.
    var cleanupUnavailableExplanation: String? {
        transcriptPolisher.availability.explanation
    }

    /// the pipe, popped out (ADR 0038 addendum): a visualizer is a tool,
    /// not a setting, so it gets the room a window gives it.
    func openPipeline() {
        let controller = pipelineWindowController
            ?? PipelineWindowController(coordinator: self)
        pipelineWindowController = controller
        controller.present()
    }

    func openCleanupLab() {
        let controller: CleanupLabWindowController
        if let cleanupLabWindowController {
            controller = cleanupLabWindowController
        } else {
            controller = CleanupLabWindowController(
                store: cleanupLabStore
            )
            cleanupLabWindowController = controller
        }
        controller.present()
    }

    func clearCleanupLabData() {
        Task { [weak self, cleanupLabStore] in
            do {
                try await cleanupLabStore.clear()
                self?.cleanupLabWindowController?.reload()
            } catch {
                self?.cleanupLogger.error(
                    "cleanup lab clear failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    /// The door ticket 011 chose. It hands over the *raw* transcript on
    /// purpose: a dictionary entry's `wrong` side has to be what the engine
    /// produced, and `lastTranscript` is already exactly that.
    func openWordFixer() {
        guard let lastTranscript else {
            return
        }
        openWordFixer(for: lastTranscript)
    }

    func openWordFixer(for transcript: String) {
        let controller = WordFixerWindowController(
            transcript: transcript,
            store: dictionaryStore
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

        let app = Bundle.main.bundleURL
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", app.path]
        // A relaunch has to outlive us, so it is handed to `open` and we go.
        try? task.run()
        NSApp.terminate(nil)
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
        presentOnboarding()
    }

    func runOnboardingAgain() {
        presentOnboarding()
    }

    func finishOnboarding() {
        dismissOnboarding()
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
            moment: moment
        )
    }

    func beginOnboardingEnginePreparation() {
        guard isOnboardingPresented else {
            return
        }
        prepareProductiveWaitWork()
        requestEnginePreparation()
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
        synchronizeHUD()
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
        requestEnginePreparation()
    }

    func prepareForActiveModelRemoval(
        _ version: EngineVersion
    ) async {
        guard version == activeEngineVersion else {
            return
        }

        invalidatePipeline()
        if state == .recording {
            audioRecorder?.cancel()
            setRecordingLocked(false)
            activeFocusAnchor = nil
            activeTimeline = nil
        }

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
        setState(.idle)

        await transcriptionEngine.unloadModels()
    }

    private func presentOnboarding() {
        isOnboardingPresented = true
        hotkeyMonitor.setDetectionOnly(true)
        withHUDPanel { $0.dismiss() }

        if let onboardingWindowController {
            onboardingWindowController.present()
            return
        }

        let controller = OnboardingWindowController(coordinator: self)
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

        if state == .recording {
            audioRecorder.cancel()
            setRecordingLocked(false)
            activeFocusAnchor = nil
            activeTimeline = nil
            setState(.idle)
        }

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

    private func requestEnginePreparation() {
        enginePreparationRequested = true
        guard !isPrewarmed,
              enginePrewarmTask == nil,
              engineSwapTask == nil else {
            return
        }

        startPrewarming()
    }

    private func startPrewarming() {
        engineSwapTask?.cancel()
        engineSwapTask = nil
        enginePrewarmTask?.cancel()
        engineGeneration += 1
        let generation = engineGeneration
        let version = activeEngineVersion
        isPrewarmed = false
        engineSwitchMessage = nil
        enginePreparationState = .downloading(progress: 0)
        setState(.prewarming)

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
                self.setState(.idle)
            } catch is CancellationError {
                return
            } catch {
                guard generation == self.engineGeneration else {
                    return
                }
                self.enginePrewarmTask = nil
                self.enginePreparationState = .failed
                self.engineLogger.error(
                    """
                    engine prewarm failed: \
                    \(error.localizedDescription, privacy: .public)
                    """
                )
                self.setState(.idle)
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
                        self?.handleCaptureInterruption()
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
                        self?.handleCaptureInterruption()
                    } else {
                        self?.handleSystemResume()
                    }
                }
            }
            distributedNotificationObservers.append(observer)
        }

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

        return SetupGate.presentation(
            onboardingDismissed: settings.onboardingDismissed,
            permissions: snapshot,
            moment: moment
        )
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
    private func announcePermissionGap(_ message: String) {
        guard state == .idle else {
            return
        }

        flashNotice(message, duration: 1.8)
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
            recorder.onInterruption = { [weak self] in
                self?.handleCaptureInterruption()
            }
            recorder.onCapReached = { [weak self] in
                self?.handleCaptureCapReached()
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

    /// the recorder stops itself at the ceiling and keeps what it heard.
    /// the only thing missing is the user knowing why the wave went quiet.
    private func handleCaptureCapReached() {
        guard state == .recording else {
            return
        }

        flashNotice("five minutes — that's the cap")
    }

    private func handleCaptureInterruption() {
        switch state {
        case .recording:
            audioRecorder?.cancel()
            setRecordingLocked(false)
            activeFocusAnchor = nil
            activeTimeline = nil
            setState(.idle)
        case .idle, .prewarming, .transcribing:
            break
        }

        hotkeyMonitor.reset()
    }

    private func handleSystemResume() {
        hotkeyMonitor.reset()
        verifyEngineHealth()
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
                    self.setState(.idle)
                }
            }
        }
    }

    private func beginRecording() {
        if state == .transcribing {
            invalidatePipeline()
            setState(.idle)
        }

        guard isPrewarmed else {
            switch enginePreparationState {
            case .notStarted:
                requestEnginePreparation()
            case .failed:
                // pressing the key is a statement of intent, and a failed
                // model download is usually a blip. try again, out loud —
                // the alternative is a lamp that breathes forever.
                retryEnginePrewarm()
                flashNotice("speech model failed — retrying")
                return
            case .downloading, .warmingUp, .ready:
                break
            }
            if state != .prewarming {
                setState(.prewarming)
            }
            return
        }
        guard state == .idle else {
            return
        }
        // the one grant we can verify at the point of use: if the hotkey
        // reached us at all, accessibility is alive. the mic may not be.
        guard SystemPermissions.snapshot().microphoneGranted else {
            refreshPermissions(moment: .midSession)
            announcePermissionGap("microphone access is off")
            return
        }
        guard let audioRecorder = ensureAudioRecorder() else {
            flashNotice("no microphone available")
            return
        }

        timelineSequence &+= 1
        let timelineID = timelineSequence
        activeTimeline = UtteranceTimelineBuilder(
            id: timelineID,
            keyDown: timelineClock.now
        )
        let focusAnchor = FocusAnchor.capture()

        do {
            try audioRecorder.start { [weak self] instant in
                self?.recordFirstBuffer(
                    at: instant,
                    timelineID: timelineID
                )
            }
            activeFocusAnchor = focusAnchor
            if !isOnboardingPresented {
                feedbackSounds.play(.start)
            }
            setState(.recording)
        } catch {
            audioLogger.error(
                """
                audio recording failed to start: \
                \(error.localizedDescription, privacy: .public)
                """
            )
            activeFocusAnchor = nil
            activeTimeline = nil
            // the device may have been yanked between the check and the tap.
            // drop it so the next press rebuilds instead of retrying a corpse.
            audioRecorder.cancel()
            self.audioRecorder = nil
            hudViewModel.useRecorder(nil)
            setState(.idle)
            flashNotice("couldn't start recording")
        }
    }

    private func beginLockedRecording() {
        if state == .recording {
            return
        }

        invalidatePipeline()
        setState(.idle)
        beginRecording()

        // only claim the lock if the capture took — a missing mic or a
        // failed engine leaves us idle, and a lamp that says "locked"
        // over nothing is a lie.
        guard state == .recording else {
            return
        }
        setRecordingLocked(true)
        flashNotice("locked — tap to end")
    }

    /// the HUD is the only place this fact can live: there is no held
    /// key to look at, and the lamp burns identically either way.
    private func setRecordingLocked(_ locked: Bool) {
        guard locked != isRecordingLocked else {
            return
        }
        isRecordingLocked = locked
        hudViewModel.setRecordingLocked(locked)
    }

    private func endRecording() {
        guard state == .recording,
              let audioRecorder else {
            return
        }

        setRecordingLocked(false)

        do {
            activeTimeline?.keyUp = timelineClock.now
            let samples = try audioRecorder.stop()
            let focusAnchor = activeFocusAnchor
            activeFocusAnchor = nil
            if !isOnboardingPresented {
                feedbackSounds.play(.end)
            }
            setState(.transcribing)
            startPipeline(
                samples,
                focusAnchor: focusAnchor
            )
        } catch {
            audioLogger.error(
                """
                audio recording failed to stop: \
                \(error.localizedDescription, privacy: .public)
                """
            )
            activeFocusAnchor = nil
            activeTimeline = nil
            setState(.idle, fastHUDDismiss: true)
            // they spoke and there is nothing to show for it. say so.
            flashNotice("recording was lost")
        }
    }

    private func cancelRecording() {
        guard state == .recording,
              let audioRecorder else {
            return
        }

        audioRecorder.cancel()
        setRecordingLocked(false)
        activeFocusAnchor = nil
        activeTimeline = nil
        setState(.idle)
    }

    private func recordFirstBuffer(
        at instant: ContinuousClock.Instant,
        timelineID: UInt64
    ) {
        guard activeTimeline?.id == timelineID,
              activeTimeline?.micFirstBuffer == nil else {
            return
        }
        activeTimeline?.micFirstBuffer = instant
    }

    private func startPipeline(
        _ samples: [Float],
        focusAnchor: FocusAnchor?
    ) {
        pipelineGeneration += 1
        let generation = pipelineGeneration

        pipelineTask = Task { [weak self] in
            await self?.transcribeAndInsert(
                samples,
                focusAnchor: focusAnchor,
                generation: generation
            )
        }
    }

    private func transcribeAndInsert(
        _ samples: [Float],
        focusAnchor: FocusAnchor?,
        generation: Int
    ) async {
        defer {
            finishPipeline(generation: generation)
        }

        do {
            let transcript = try await transcriptionEngine.transcribe(samples)
            try Task.checkCancellation()
            guard generation == pipelineGeneration else {
                return
            }
            let transcriptReady = timelineClock.now
            activeTimeline?.transcriptReady = transcriptReady

            let rawHadCorrections = MessyGateSignals
                .containsCorrectionMarker(in: transcript)
            let rawHadDuplicates = MessyGateSignals
                .containsImmediateDuplicate(in: transcript)
            let cleaner = DeterministicCleaner(
                entries: dictionaryStore.entries,
                fullCleanup: settings.cleanupEnabled
            )
            let rawTranscript = cleaner.clean(transcript)
            activeTimeline?.cleaned = timelineClock.now
            guard !rawTranscript.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty else {
                activeTimeline = nil
                // silence must not wear the success afterglow.
                await reportPipelineFailure(
                    "heard nothing",
                    generation: generation
                )
                return
            }
            let pasteTranscript: String
            var shortfall = PolishShortfall.none
            switch settings.cleanupMode {
            case .off:
                activeTimeline?.polished = timelineClock.now
                pasteTranscript = rawTranscript
            case .on, .always:
                let protectedTerms = cleanupProtectedTerms()
                let shouldPolish = MessyGate().shouldPolish(
                    rawTranscript,
                    rawHadCorrections: rawHadCorrections,
                    rawHadDuplicates: rawHadDuplicates,
                    dictionaryTerms: protectedTerms
                )
                activeTimeline?.polishGateDecision = shouldPolish
                if shouldPolish {
                    // on: tight budget, raw on timeout. always: waits,
                    // with a hard ceiling so a hung model cannot consume
                    // an entire dictation interaction.
                    let budget: Duration = settings.cleanupMode == .on
                        ? .milliseconds(600)
                        : .seconds(15)
                    let timedResult = await polishWithinDeadline(
                        rawTranscript,
                        protectedTerms: protectedTerms,
                        using: transcriptPolisher,
                        deadline: transcriptReady.advanced(by: budget)
                    )
                    try Task.checkCancellation()
                    guard generation == pipelineGeneration else {
                        return
                    }
                    activeTimeline?.polished = timelineClock.now
                    let pasteChoice = cleanupPasteChoice(
                        raw: rawTranscript,
                        polishResult: timedResult.result,
                        deadline: timedResult.deadline
                    )
                    pasteTranscript = pasteChoice.text
                    if pasteChoice.text != rawTranscript {
                        logCleanupPair(
                            raw: rawTranscript,
                            cleaned: pasteChoice.text,
                            started: transcriptReady
                        )
                    }
                    if timedResult.result == .failure {
                        cleanupLogger.notice(
                            "foreground polish fell back to raw"
                        )
                    }
                    shortfall = polishShortfall(
                        mode: settings.cleanupMode,
                        polishResult: timedResult.result,
                        deadline: timedResult.deadline
                    )
                } else {
                    activeTimeline?.polished = timelineClock.now
                    pasteTranscript = rawTranscript
                }
            }

            lastTranscript = rawTranscript
            pendingArchiveText = (
                heard: transcript,
                inserted: pasteTranscript
            )
            let pasteResult = await paster.paste(
                pasteTranscript,
                reasonForLeavingOnPasteboard: {
                    switch focusAnchor?.revalidationDecision()
                        ?? .copyFocusChanged {
                    case .paste:
                        nil
                    case .copySecure:
                        .secureField
                    case .copyFocusChanged:
                        .focusChanged
                    }
                }
            )
            if pasteResult != .leftOnPasteboard(
                .pasteboardUnavailable
            ) {
                settings.recordDictatedTranscript(rawTranscript)
            }
            guard generation == pipelineGeneration else {
                return
            }

            switch pasteResult {
            case .pasted:
                completeTimeline(
                    at: timelineClock.now,
                    stage: .pasteVerified
                )
                // "always" is the mode whose whole promise is that raw text
                // never reaches the page unannounced. keep it.
                if let notice = polishShortfallMessage(shortfall) {
                    setState(.idle, fastHUDDismiss: true)
                    await flashFeedback(notice, duration: 1.6)
                }
            case let .leftOnPasteboard(reason):
                completeTimeline(
                    at: timelineClock.now,
                    stage: .leftOnPasteboard
                )
                setState(.idle)
                await flashFeedback(
                    feedbackMessage(for: reason)
                )
            }
        } catch is CancellationError {
            return
        } catch {
            pipelineLogger.error(
                "transcription failed: \(error.localizedDescription, privacy: .public)"
            )
            activeTimeline = nil
            await reportPipelineFailure(
                "couldn't transcribe",
                generation: generation
            )
        }
    }

    /// a dictation that produced nothing must not end in the lamp's
    /// afterglow — that glow is the success signal. cut it short and say
    /// what went wrong in the same pill that carries "copied — …".
    private func reportPipelineFailure(
        _ message: String,
        generation: Int
    ) async {
        guard generation == pipelineGeneration,
              state == .transcribing else {
            return
        }

        setState(.idle, fastHUDDismiss: true)
        await flashFeedback(message)
    }

    private func cleanupProtectedTerms() -> [String] {
        var seen: Set<String> = []
        return dictionaryStore.entries.compactMap { entry in
            let term = entry.right
            guard !term.isEmpty, seen.insert(term).inserted else {
                return nil
            }
            return term
        }
    }

    private func logCleanupPair(
        raw: String,
        cleaned: String,
        started: ContinuousClock.Instant
    ) {
        guard Capabilities.current.keepsCleanupLab else {
            return
        }
        let latency = started.duration(to: ContinuousClock().now)
        Task {
            do {
                try await cleanupLabStore.append(
                    CleanupLabEntry(
                        ts: Date(),
                        backend: FoundationModelPolisher.backendName,
                        latencyMs: cleanupMilliseconds(latency),
                        raw: raw,
                        cleaned: cleaned
                    )
                )
            } catch {
                cleanupLogger.error(
                    "lab append failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func cleanupMilliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds)
                / 1_000_000_000_000_000
    }

    private func invalidatePipeline() {
        setRecordingLocked(false)
        pipelineGeneration += 1
        pipelineTask?.cancel()
        pipelineTask = nil
        activeTimeline = nil
    }

    private func polishShortfallMessage(
        _ shortfall: PolishShortfall
    ) -> String? {
        switch shortfall {
        case .none:
            nil
        case .timedOut:
            "polish timed out — pasted raw"
        case .failed:
            "couldn't polish — pasted raw"
        }
    }

    private func feedbackMessage(
        for reason: LeftOnPasteboardReason
    ) -> String {
        switch reason {
        case .secureField:
            "copied — secure field"
        case .focusChanged:
            "copied — focus changed"
        case .accessibilityUnavailable,
             .shortcutUnavailable,
             .cancelled:
            "copied — paste unavailable"
        case .pasteboardUnavailable:
            "couldn't copy transcript"
        }
    }

    private func completeTimeline(
        at instant: ContinuousClock.Instant,
        stage: UtteranceTimeline.CompletionStage
    ) {
        defer {
            activeTimeline = nil
            pendingArchiveText = nil
        }
        guard let timeline = activeTimeline?.complete(stage, at: instant) else {
            return
        }
        timelineStore.append(timeline)
        archive(timeline, stage: stage)
    }

    /// A dictation becomes a kept thing only once it has actually been
    /// delivered. A cancelled one produced no text, so there is nothing to
    /// keep; one left on the pasteboard reached you by another route and
    /// still counts.
    private func archive(
        _ timeline: UtteranceTimeline,
        stage: UtteranceTimeline.CompletionStage
    ) {
        guard settings.keepDictations,
              stage != .cancelled,
              let text = pendingArchiveText else {
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
                    heard: text.heard,
                    inserted: text.inserted,
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

    private func finishPipeline(generation: Int) {
        guard generation == pipelineGeneration else {
            return
        }

        pipelineTask = nil
        guard state == .transcribing else {
            return
        }

        // success is silent: the lamp's afterglow is the whole goodbye.
        // hold the panel just long enough for the cool-out to finish.
        let elapsed = Date().timeIntervalSince(
            transcribingBeganAt ?? .distantPast
        )
        let remaining = max(
            0,
            HUDWaveMotion.coolDuration + 0.05 - elapsed
        )
        let stateToken = stateGeneration
        Task { @MainActor [weak self] in
            if remaining > 0 {
                try? await Task.sleep(for: .seconds(remaining))
            }
            guard let self,
                  stateToken == self.stateGeneration,
                  self.state == .transcribing else {
                return
            }
            self.setState(.idle, fastHUDDismiss: true)
        }
    }

    private func handleEscape() -> Bool {
        guard state != .idle, state != .prewarming else {
            return false
        }

        cancelCurrentInteraction()
        return true
    }

    private func cancelCurrentInteraction() {
        let cancelRequested = timelineClock.now

        if state == .recording {
            audioRecorder?.cancel()
            setRecordingLocked(false)
            activeFocusAnchor = nil
        }

        pipelineGeneration += 1
        pipelineTask?.cancel()
        pipelineTask = nil
        setState(.idle, fastHUDDismiss: true)
        let idle = timelineClock.now

        if let timeline = activeTimeline?.cancelled(
            requestedAt: cancelRequested,
            idleAt: idle
        ) {
            timelineStore.append(timeline)
        }
        activeTimeline = nil
    }

    private func flashFeedback(
        _ message: String,
        duration: TimeInterval = 1.2
    ) async {
        feedbackGeneration += 1
        let feedbackToken = feedbackGeneration
        let stateToken = stateGeneration
        activeFeedbackGeneration = feedbackToken
        hudViewModel.showFeedback(message)
        synchronizeHUD()

        try? await Task.sleep(for: .seconds(duration))
        guard stateToken == stateGeneration,
              feedbackToken == feedbackGeneration,
              activeFeedbackGeneration == feedbackToken else {
            return
        }

        activeFeedbackGeneration = nil
        hudViewModel.clearFeedback()
        synchronizeHUD()
    }

    private func setState(
        _ newState: State,
        fastHUDDismiss: Bool = false
    ) {
        stateGeneration += 1
        feedbackGeneration += 1
        activeFeedbackGeneration = nil
        if newState == .transcribing {
            transcribingBeganAt = Date()
        }
        state = newState
        hudViewModel.update(state: newState)

        synchronizeHUD(fastDismiss: fastHUDDismiss)
    }

    private func synchronizeHUD(fastDismiss: Bool = false) {
        withHUDPanel { [weak self] panel in
            guard let self else {
                return
            }

            if self.isOnboardingPresented {
                panel.dismiss(fast: fastDismiss)
                return
            }

            guard self.activeFeedbackGeneration != nil
                    || self.state != .idle else {
                panel.dismiss(fast: fastDismiss)
                return
            }

            let screenWidth = panel.presentationScreenWidth()
            let layout = HUDLayoutEngine.layout(
                for: self.hudViewModel.content,
                screenWidth: screenWidth
            )
            panel.present()
            self.hudViewModel.updateLayout(layout)
            panel.morph(
                to: layout,
                animated: !NSWorkspace.shared
                    .accessibilityDisplayShouldReduceMotion
            )
        }
    }
}
