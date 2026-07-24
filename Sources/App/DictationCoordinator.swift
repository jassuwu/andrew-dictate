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
    let mode: DictationMode
    let sequence: Int
}

@MainActor
final class DictationCoordinator: ObservableObject {
    private let askLogger = Logger(
        subsystem: "gg.jass.dictate",
        category: "ask"
    )
    private let engineLogger = Logger(
        subsystem: "gg.jass.dictate",
        category: "engine"
    )
    private let cleanupLogger = Logger(
        subsystem: "gg.jass.dictate",
        category: "cleanup"
    )
    enum State: Equatable, Sendable {
        case idle
        case prewarming
        case recording
        case transcribing
        case asking(threadOpen: Bool)
        case screenAsking(threadOpen: Bool)
        case askStreaming(String, threadOpen: Bool)
        case askAnswer(String, threadOpen: Bool)
        case askThreadOpen
        case gatePending(
            commandPreview: String,
            confirmationKeyName: String
        )
        case transcriptFlash(String)

        var displayName: String {
            switch self {
            case .idle:
                "idle"
            case .prewarming:
                "prewarming"
            case .recording:
                "recording"
            case .transcribing:
                "transcribing"
            case .asking:
                "asking"
            case .screenAsking:
                "screen asking"
            case .askStreaming:
                "streaming answer"
            case .askAnswer:
                "answer"
            case .askThreadOpen:
                "follow-up open"
            case .gatePending:
                "gate pending"
            case .transcriptFlash:
                "transcript flash"
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
    @Published private(set) var lastAnswer: String?

    let dictionaryStore: DictionaryStore
    let customActionStore: CustomActionStore
    let settings: AppSettings

    private let hotkeyMonitor: HotkeyMonitor
    private let transcriptionEngine: ParakeetEngine
    private let paster: Paster
    private let commandRouter = CommandRouter()
    private let commandExecutor: CommandExecutor
    private let agentDelegator: AgentDelegator
    private let askEngine: AskEngine
    private let screenCapture: ScreenCapture
    private let audioRecorder: AudioRecorder?
    private let feedbackSounds: FeedbackSounds
    private let transcriptPolisher = FoundationModelPolisher()
    private let cleanupLabStore = LabStore()
    private let answerSpeaker = AVSpeechSynthesizer()
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
    private var activeMode: DictationMode?
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
    private var settingsWindowController: SettingsWindowController?
    private var onboardingWindowController: OnboardingWindowController?
    private var isOnboardingPresented: Bool
    private var hotkeyDetectionSequence = 0
    private var stateGeneration: UInt64 = 0
    private var delegationGate = DelegationGate()
    private enum PendingGatedExecution {
        case delegation(prompt: String)
        case customAction(CustomActionInvocation)
    }
    private var pendingGatedExecution: PendingGatedExecution?
    private var gateTimeoutTask: Task<Void, Never>?
    private var answerVisibilityTask: Task<Void, Never>?
    private var streamingHUDMorphTask: Task<Void, Never>?
    private var lastStreamingHUDMorphTime: TimeInterval?
    private var streamingSentences: StreamingSentenceAccumulator?
    private var feedbackGeneration: UInt64 = 0
    private var activeFeedbackGeneration: UInt64?
    private let timelineClock = ContinuousClock()
    private let timelineStore = UtteranceTimelineStore()
    private var timelineSequence: UInt64 = 0
    private var activeTimeline: UtteranceTimelineBuilder?
    private var aboutWindowController: AboutWindowController?
    private var cleanupLabWindowController: CleanupLabWindowController?
    private var workspaceNotificationObservers: [NSObjectProtocol] = []
    private var distributedNotificationObservers: [NSObjectProtocol] = []

    init(settings: AppSettings = .shared) {
        self.settings = settings
        activeEngineVersion = settings.engineVersion
        engineSwitchState = EngineSwitchState(
            activeVersion: settings.engineVersion
        )
        isOnboardingPresented = !settings.onboardingCompleted
        enginePreparationRequested = settings.onboardingCompleted
        dictionaryStore = DictionaryStore()
        customActionStore = CustomActionStore()
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
            print("audio recorder initialization failed: \(error.localizedDescription)")
        }
        audioRecorder = recorder
        feedbackSounds = FeedbackSounds(settings: settings)

        let viewModel = HUDViewModel(
            state: .prewarming,
            audioRecorder: recorder
        )
        hudViewModel = viewModel
        let executor = CommandExecutor(
            paster: paster
        )
        commandExecutor = executor
        agentDelegator = AgentDelegator(settings: settings)
        askEngine = AskEngine(settings: settings)
        screenCapture = ScreenCapture()

        let monitor = HotkeyMonitor(settings: settings)
        hotkeyMonitor = monitor

        executor.onDelegate = { [weak self] prompt in
            await self?.requestDelegation(prompt)
        }
        executor.onAsk = { [weak self] prompt in
            await self?.requestAsk(prompt)
        }
        executor.onScreenAsk = { [weak self] prompt, scope in
            await self?.requestScreenAsk(prompt, scope: scope)
        }
        executor.onCustomActionGate = {
            [weak self] invocation, preview in
            await self?.requestCustomActionConfirmation(
                invocation,
                preview: preview
            )
        }
        executor.onShell = { [weak self] command, trigger in
            await self?.launchCustomShell(
                command,
                trigger: trigger
            )
        }
        executor.onFeedback = { [weak self] message in
            await self?.flashFeedback(message)
        }
        askEngine.onThreadExpired = { [weak self] in
            self?.threadDidExpire()
        }
        monitor.onBegin = { [weak self] mode in
            self?.beginRecording(mode)
        }
        monitor.onEnd = { [weak self] mode in
            self?.endRecording(mode)
        }
        monitor.onCancel = { [weak self] mode in
            self?.cancelRecording(mode)
        }
        monitor.onLockBegin = { [weak self] mode in
            self?.beginLockedRecording(mode)
        }
        monitor.onLockEnd = { [weak self] mode in
            self?.endRecording(mode)
        }
        monitor.onLockCancel = { [weak self] mode in
            self?.cancelRecording(mode)
        }
        monitor.onKeyDetected = { [weak self] mode in
            guard let self else {
                return
            }
            self.hotkeyDetectionSequence += 1
            self.hotkeyDetection = HotkeyDetection(
                mode: mode,
                sequence: self.hotkeyDetectionSequence
            )
        }
        monitor.onModeKeyPressed = { [weak self] mode, _ in
            self?.handleModeKeyPressed(mode) ?? false
        }
        monitor.onModeKeyReleased = { [weak self] mode, _ in
            self?.consumeGateKeyRelease(mode)
        }
        monitor.onEscape = { [weak self] in
            self?.handleEscape() ?? false
        }
        recorder?.onInterruption = { [weak self] in
            self?.handleCaptureInterruption()
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
    func rebindHotkey(
        _ mode: DictationMode,
        to binding: HotkeyBinding
    ) -> Bool {
        hotkeyMonitor.rebind(mode, to: binding)
    }

    func openSettings() {
        let controller: SettingsWindowController
        if let settingsWindowController {
            controller = settingsWindowController
        } else {
            controller = SettingsWindowController(coordinator: self)
            settingsWindowController = controller
        }
        controller.present()
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

    func copyLastTranscript() {
        guard let lastTranscript else {
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        _ = pasteboard.setString(lastTranscript, forType: .string)
    }

    func copyLastAnswer() {
        guard let lastAnswer else {
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        _ = pasteboard.setString(lastAnswer, forType: .string)
    }

    #if DEBUG
    func copyTimings() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(
            timelineStore.formattedTable(),
            forType: .string
        )
    }
    #endif

    func presentOnboardingIfNeeded() {
        guard !settings.onboardingCompleted else {
            isOnboardingPresented = false
            return
        }
        presentOnboarding()
    }

    func runOnboardingAgain() {
        settings.onboardingCompleted = false
        presentOnboarding()
    }

    func finishOnboarding() {
        completeOnboarding()
    }

    func skipOnboarding() {
        completeOnboarding()
    }

    private func completeOnboarding() {
        hotkeyMonitor.setDetectionOnly(false)
        settings.onboardingCompleted = true
        onboardingWindowController?.close()
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
            askEngine.discardSpeculativeAsk(reason: "model-removal")
            activeMode = nil
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
            askEngine.discardSpeculativeAsk(reason: "pre-roll-change")
            activeMode = nil
            activeFocusAnchor = nil
            activeTimeline = nil
            setState(.idle)
        }

        do {
            try audioRecorder.applyPreRoll(enabled)
        } catch {
            print(
                "pre-roll setting failed to apply: "
                    + error.localizedDescription
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
        agentDelegator.prepareSupportDirectory()

        do {
            try customActionStore.ensureFileExists()
        } catch {
            print(
                "application support preparation failed: "
                    + error.localizedDescription
            )
        }
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
                print(
                    "transcription engine prewarm failed: "
                        + error.localizedDescription
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
    }

    private func handleCaptureInterruption() {
        switch state {
        case .recording:
            audioRecorder?.cancel()
            askEngine.discardSpeculativeAsk(reason: "interruption")
            activeMode = nil
            activeFocusAnchor = nil
            activeTimeline = nil
            setState(.idle)
        case .asking,
             .screenAsking,
             .askStreaming,
             .askAnswer,
             .askThreadOpen,
             .gatePending,
             .transcriptFlash:
            stopAnswerSpeech()
            cancelStreamingHUDMorph()
            screenCapture.cancelPendingCapture()
            askEngine.cancel()
            answerVisibilityTask?.cancel()
            answerVisibilityTask = nil
            setState(.idle)
        case .idle, .prewarming, .transcribing:
            break
        }

        hotkeyMonitor.reset()
    }

    private func handleSystemResume() {
        hotkeyMonitor.reset()
        verifyEngineHealth()
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
                print(
                    "transcription engine health check failed: "
                        + error.localizedDescription
                )
                if self.state == .prewarming {
                    self.setState(.idle)
                }
            }
        }
    }

    private func beginRecording(_ mode: DictationMode) {
        if state == .transcribing || state.isTranscriptFlash {
            invalidatePipeline()
            setState(.idle)
        }

        guard isPrewarmed else {
            if enginePreparationState == .notStarted {
                requestEnginePreparation()
            }
            if state != .prewarming {
                setState(.prewarming)
            }
            return
        }
        guard state == .idle else {
            return
        }
        guard let audioRecorder else {
            print("audio recorder unavailable")
            return
        }

        timelineSequence &+= 1
        let timelineID = timelineSequence
        activeTimeline = UtteranceTimelineBuilder(
            id: timelineID,
            mode: mode,
            keyDown: timelineClock.now
        )
        let focusAnchor = mode == .dictation
            ? FocusAnchor.capture()
            : nil

        do {
            try audioRecorder.start { [weak self] instant in
                self?.recordFirstBuffer(
                    at: instant,
                    timelineID: timelineID
                )
            }
            if mode == .command {
                askEngine.prepareSpeculativeAsk()
            } else {
                askEngine.discardSpeculativeAsk(
                    reason: "dictation-keydown"
                )
            }
            activeMode = mode
            activeFocusAnchor = focusAnchor
            if !isOnboardingPresented {
                feedbackSounds.play(.start, for: mode)
            }
            setState(.recording, mode: mode)
        } catch {
            print("audio recording failed to start: \(error.localizedDescription)")
            activeMode = nil
            activeFocusAnchor = nil
            activeTimeline = nil
            setState(.idle)
        }
    }

    private func beginLockedRecording(_ mode: DictationMode) {
        if state == .recording, activeMode == mode {
            return
        }

        invalidatePipeline()

        if state == .recording, let audioRecorder {
            audioRecorder.cancel()
            askEngine.discardSpeculativeAsk(reason: "lock-restart")
            activeMode = nil
            activeFocusAnchor = nil
            activeTimeline = nil
        }

        setState(.idle)
        beginRecording(mode)
    }

    private func endRecording(_ mode: DictationMode) {
        guard state == .recording,
              activeMode == mode,
              let audioRecorder else {
            return
        }

        do {
            activeTimeline?.keyUp = timelineClock.now
            let samples = try audioRecorder.stop()
            let focusAnchor = activeFocusAnchor
            activeMode = nil
            activeFocusAnchor = nil
            if !isOnboardingPresented {
                feedbackSounds.play(.end, for: mode)
            }
            setState(.transcribing, mode: mode)
            startPipeline(
                samples,
                mode: mode,
                focusAnchor: focusAnchor
            )
        } catch {
            print("audio recording failed to stop: \(error.localizedDescription)")
            activeMode = nil
            activeFocusAnchor = nil
            activeTimeline = nil
            setState(.idle)
        }
    }

    private func cancelRecording(_ mode: DictationMode) {
        guard state == .recording,
              activeMode == mode,
              let audioRecorder else {
            return
        }

        audioRecorder.cancel()
        askEngine.discardSpeculativeAsk(reason: "recording-cancel")
        activeMode = nil
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
        mode: DictationMode,
        focusAnchor: FocusAnchor?
    ) {
        pipelineGeneration += 1
        let generation = pipelineGeneration

        pipelineTask = Task { [weak self] in
            await self?.transcribeAndRoute(
                samples,
                mode: mode,
                focusAnchor: focusAnchor,
                generation: generation
            )
        }
    }

    private func transcribeAndRoute(
        _ samples: [Float],
        mode: DictationMode,
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

            switch mode {
            case .dictation:
                let rawHadCorrections = SelfCorrections.containsMarker(
                    in: transcript
                )
                let rawHadDuplicates =
                    RepetitionCollapse.containsImmediateDuplicate(
                        in: transcript
                    )
                let cleaner = DeterministicCleaner(
                    entries: dictionaryStore.entries
                )
                let rawTranscript = cleaner.clean(transcript)
                activeTimeline?.cleaned = timelineClock.now
                guard !rawTranscript.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty else {
                    activeTimeline = nil
                    return
                }
                let pasteTranscript: String
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
                    } else {
                        activeTimeline?.polished = timelineClock.now
                        pasteTranscript = rawTranscript
                    }
                }

                lastTranscript = rawTranscript
                showTranscriptFlash(pasteTranscript)
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
            case .command:
                let commandTranscript = DictionarySubstituter(
                    entries: dictionaryStore.entries
                ).apply(to: transcript)
                activeTimeline?.cleaned = timelineClock.now
                activeTimeline?.polished = timelineClock.now
                let command = commandRouter.route(
                    commandTranscript,
                    customActions: customActionStore.actions
                )

                if askEngine.hasOpenThread {
                    if case .custom = command {
                        askEngine.discardSpeculativeAsk(
                            reason: "follow-up-custom"
                        )
                        askEngine.clearThread()
                        completeTimeline(
                            at: timelineClock.now,
                            stage: .commandRouted
                        )
                        await commandExecutor.execute(command)
                    } else if case let .screenAsk(_, scope) = command {
                        askEngine.discardSpeculativeAsk(
                            reason: "follow-up-screen"
                        )
                        await requestScreenAsk(
                            commandTranscript,
                            scope: scope
                        )
                    } else {
                        await requestAsk(commandTranscript)
                    }
                    return
                }

                if case .ask = command {
                    // Ask completion owns the timeline so Esc can measure
                    // cancelRequested → idle while the CLI is in flight.
                } else if case .screenAsk = command {
                    askEngine.discardSpeculativeAsk(reason: "screen-route")
                    // Ask completion owns the timeline so Esc can measure
                    // cancelRequested → idle while the CLI is in flight.
                } else {
                    askEngine.discardSpeculativeAsk(reason: "non-ask-route")
                    completeTimeline(
                        at: timelineClock.now,
                        stage: .commandRouted
                    )
                }
                await commandExecutor.execute(command)
            }
        } catch is CancellationError {
            askEngine.discardSpeculativeAsk(reason: "pipeline-cancel")
            return
        } catch {
            askEngine.discardSpeculativeAsk(reason: "transcription-error")
            print("transcription failed: \(error.localizedDescription)")
        }
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
        askEngine.discardSpeculativeAsk(reason: "pipeline-invalidated")
        pipelineGeneration += 1
        pipelineTask?.cancel()
        pipelineTask = nil
        activeTimeline = nil
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
        defer { activeTimeline = nil }
        guard let timeline = activeTimeline?.complete(stage, at: instant) else {
            return
        }
        timelineStore.append(timeline)
    }

    private func finishPipeline(generation: Int) {
        guard generation == pipelineGeneration else {
            return
        }

        pipelineTask = nil
        if state == .transcribing {
            setState(.idle)
        }
    }

    private func showTranscriptFlash(_ transcript: String) {
        setState(.transcriptFlash(transcript))
        let generation = stateGeneration

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard let self,
                  generation == self.stateGeneration,
                  case .transcriptFlash = self.state else {
                return
            }
            self.setState(.idle)
        }
    }

    private func requestAsk(_ prompt: String) async {
        let isFollowUp = askEngine.hasOpenThread
        beginStreamingAnswer()
        setState(.asking(threadOpen: isFollowUp), mode: .command)
        let generation = stateGeneration

        do {
            try await performAsk(
                prompt: prompt,
                imagePath: nil,
                generation: generation,
                isScreenAsk: false,
                threadOpenWhileStreaming: isFollowUp
            )
        } catch {
            await handleAskFailure(error, generation: generation)
        }
    }

    private func requestScreenAsk(
        _ prompt: String,
        scope: ScreenAskScope
    ) async {
        let isFollowUp = askEngine.hasOpenThread
        // Screen capture determines an image flag after recording, so its
        // prompt-less speculative process was discarded at routing.
        beginStreamingAnswer()
        setState(
            .screenAsking(threadOpen: isFollowUp),
            mode: .command
        )
        let generation = stateGeneration

        do {
            let capture = try await screenCapture.capture(scope: scope)
            defer { capture.delete() }

            try await performAsk(
                prompt: prompt,
                imagePath: capture.url.path,
                generation: generation,
                isScreenAsk: true,
                threadOpenWhileStreaming: isFollowUp
            )
        } catch {
            await handleAskFailure(error, generation: generation)
        }
    }

    private func performAsk(
        prompt: String,
        imagePath: String?,
        generation: UInt64,
        isScreenAsk: Bool,
        threadOpenWhileStreaming: Bool
    ) async throws {
        let result = try await askEngine.ask(
            prompt: prompt,
            voiceAnswersEnabled: settings.voiceAnswersEnabled,
            imagePath: imagePath
        ) { [weak self] update in
            self?.receiveAskStreamUpdate(
                update,
                generation: generation,
                isScreenAsk: isScreenAsk,
                threadOpenAtStart: threadOpenWhileStreaming
            )
        }
        try Task.checkCancellation()
        guard generation == stateGeneration else {
            return
        }
        if isScreenAsk {
            switch state {
            case .screenAsking, .askStreaming:
                break
            default:
                return
            }
        } else {
            switch state {
            case .asking, .askStreaming:
                break
            default:
                return
            }
        }

        finishStreamingSpeech(with: result.answer)
        cancelStreamingHUDMorph()
        lastAnswer = result.answer
        completeTimeline(
            at: timelineClock.now,
            stage: .askAnswered
        )
        setState(
            .askAnswer(
                result.answer,
                threadOpen: result.hasOpenThread
            ),
            mode: .command
        )
        scheduleAnswerVisibility(
            threadOpen: result.hasOpenThread
        )
    }

    private func handleAskFailure(
        _ error: Error,
        generation: UInt64
    ) async {
        if error is CancellationError {
            return
        }
        guard generation == stateGeneration else {
            return
        }

        stopAnswerSpeech()
        cancelStreamingHUDMorph()
        activeTimeline = nil
        setState(.idle)

        if let captureError = error as? ScreenCaptureError {
            switch captureError {
            case .permissionDenied:
                _ = NSWorkspace.shared.open(
                    ScreenCapture.screenRecordingSettingsURL
                )
                await flashFeedback(
                    "screen access needed — grant in settings",
                    duration: 2
                )
            case .noCaptureTarget,
                 .captureFailed,
                 .emptyCapture,
                 .unableToEncode,
                 .unableToWrite:
                await flashFeedback(
                    "couldn't look at your screen",
                    duration: 2
                )
            }
            return
        }

        if let askError = error as? AskEngineError {
            switch askError {
            case .unknownAgentCLI:
                await flashFeedback(
                    "ask needs a known agent cli",
                    duration: 2
                )
            case .timedOut:
                await flashFeedback("ask timed out")
            case .cancelled:
                return
            case .unableToLaunch:
                askLogger.error(
                    "ask launch failed: \(String(describing: askError))"
                )
                await flashFeedback("couldn't launch the agent cli")
            case .failed, .emptyAnswer:
                askLogger.error(
                    "ask failed: \(String(describing: askError))"
                )
                await flashFeedback("couldn't ask agent")
            }
            return
        }

        await flashFeedback("couldn't ask agent")
    }

    private func scheduleAnswerVisibility(threadOpen: Bool) {
        answerVisibilityTask?.cancel()
        let generation = stateGeneration
        answerVisibilityTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                for: .seconds(AskEngine.answerVisibilityDuration)
            )
            guard !Task.isCancelled,
                  let self,
                  generation == self.stateGeneration,
                  case .askAnswer = self.state else {
                return
            }
            self.answerVisibilityTask = nil

            if threadOpen, self.askEngine.hasOpenThread {
                self.setState(.askThreadOpen, mode: .command)
            } else {
                self.setState(.idle)
            }
        }
    }

    private func threadDidExpire() {
        switch state {
        case .askAnswer, .askThreadOpen:
            answerVisibilityTask?.cancel()
            answerVisibilityTask = nil
            setState(.idle)
        case .idle,
             .prewarming,
             .recording,
             .transcribing,
             .asking,
             .screenAsking,
             .askStreaming,
             .gatePending,
             .transcriptFlash:
            break
        }
    }

    private func beginStreamingAnswer() {
        cancelStreamingHUDMorph()
        lastStreamingHUDMorphTime = nil
        answerSpeaker.stopSpeaking(at: .immediate)
        streamingSentences = settings.voiceAnswersEnabled
            ? StreamingSentenceAccumulator()
            : nil
    }

    private func receiveAskStreamUpdate(
        _ update: AskStreamUpdate,
        generation: UInt64,
        isScreenAsk: Bool,
        threadOpenAtStart: Bool
    ) {
        guard generation == stateGeneration else {
            return
        }
        switch state {
        case .asking where !isScreenAsk,
             .screenAsking where isScreenAsk,
             .askStreaming:
            break
        default:
            return
        }

        let threadOpen =
            threadOpenAtStart || update.sessionID != nil
        state = .askStreaming(
            update.answer,
            threadOpen: threadOpen
        )
        hudViewModel.updateStreamingAnswer(
            update.answer,
            threadOpen: threadOpen
        )
        synchronizeStreamingHUD()

        guard var accumulator = streamingSentences else {
            return
        }
        let sentences = accumulator.ingest(update.answer)
        streamingSentences = accumulator
        speak(sentences)
    }

    private func finishStreamingSpeech(with answer: String) {
        guard var accumulator = streamingSentences else {
            return
        }
        let sentences = accumulator.finish(with: answer)
        streamingSentences = nil
        speak(sentences)
    }

    private func speak(_ sentences: [String]) {
        for sentence in sentences where !sentence.isEmpty {
            answerSpeaker.speak(
                AVSpeechUtterance(string: sentence)
            )
        }
    }

    private func stopAnswerSpeech() {
        streamingSentences = nil
        answerSpeaker.stopSpeaking(at: .immediate)
    }

    private func synchronizeStreamingHUD() {
        let now = ProcessInfo.processInfo.systemUptime
        let interval: TimeInterval = 0.25
        if let lastStreamingHUDMorphTime {
            let elapsed = now - lastStreamingHUDMorphTime
            guard elapsed < interval else {
                streamingHUDMorphTask?.cancel()
                streamingHUDMorphTask = nil
                self.lastStreamingHUDMorphTime = now
                synchronizeHUD()
                return
            }

            guard streamingHUDMorphTask == nil else {
                return
            }
            streamingHUDMorphTask = Task {
                @MainActor [weak self] in
                try? await Task.sleep(
                    for: .seconds(interval - elapsed)
                )
                guard !Task.isCancelled,
                      let self else {
                    return
                }
                self.streamingHUDMorphTask = nil
                self.lastStreamingHUDMorphTime =
                    ProcessInfo.processInfo.systemUptime
                self.synchronizeHUD()
            }
            return
        }

        lastStreamingHUDMorphTime = now
        synchronizeHUD()
    }

    private func cancelStreamingHUDMorph() {
        streamingHUDMorphTask?.cancel()
        streamingHUDMorphTask = nil
        lastStreamingHUDMorphTime = nil
    }

    private func requestDelegation(_ prompt: String) async {
        let template = settings.agentCommandTemplate
        guard AgentCommandTemplate.isValid(template) else {
            await flashFeedback(
                "no agent cli configured — set one in settings",
                duration: 2
            )
            return
        }

        let commandPreview = AgentCommandTemplate.commandPreview(
            template: template,
            prompt: prompt
        )
        let keyName = settings.hotkeyBinding(for: .command).displayName
        setState(
            .gatePending(
                commandPreview: commandPreview,
                confirmationKeyName: keyName
            )
        )
        pendingGatedExecution = .delegation(prompt: prompt)
        delegationGate.present(
            prompt: prompt,
            commandPreview: commandPreview,
            generation: stateGeneration
        )
        scheduleGateTimeout()
    }

    private func requestCustomActionConfirmation(
        _ invocation: CustomActionInvocation,
        preview: String
    ) async {
        let keyName = settings.hotkeyBinding(for: .command).displayName
        setState(
            .gatePending(
                commandPreview: preview,
                confirmationKeyName: keyName
            )
        )
        pendingGatedExecution = .customAction(invocation)
        delegationGate.present(
            prompt: invocation.action.trigger,
            commandPreview: preview,
            generation: stateGeneration
        )
        scheduleGateTimeout()
    }

    private func handleModeKeyPressed(
        _ mode: DictationMode
    ) -> Bool {
        stopAnswerSpeech()

        if case .gatePending = state {
            return consumeGateKeyPress(mode)
        }

        switch state {
        case .transcribing, .asking, .screenAsking, .askStreaming:
            cancelCurrentInteraction(clearThread: true)
        case .askAnswer, .askThreadOpen:
            if mode == .command {
                askEngine.reserveThreadForUtterance()
            }
            answerVisibilityTask?.cancel()
            answerVisibilityTask = nil
            setState(.idle)
        case .transcriptFlash:
            if mode == .command {
                askEngine.reserveThreadForUtterance()
            }
            cancelCurrentInteraction(clearThread: false)
        case .idle, .prewarming, .recording:
            if activeFeedbackGeneration != nil {
                setState(.idle)
            }
        case .gatePending:
            break
        }

        return false
    }

    private func handleEscape() -> Bool {
        let hasThread = askEngine.hasOpenThread
        let hasActivePresentation =
            activeFeedbackGeneration != nil
            || state != .idle
            || answerSpeaker.isSpeaking
            || hasThread

        guard hasActivePresentation, state != .prewarming else {
            return false
        }

        cancelCurrentInteraction(clearThread: true)
        return true
    }

    private func cancelCurrentInteraction(clearThread: Bool) {
        let cancelRequested = timelineClock.now

        stopAnswerSpeech()
        cancelStreamingHUDMorph()
        screenCapture.cancelPendingCapture()
        answerVisibilityTask?.cancel()
        answerVisibilityTask = nil
        if clearThread {
            askEngine.cancel()
        }

        if state == .recording {
            audioRecorder?.cancel()
            activeMode = nil
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

    private func consumeGateKeyPress(_ mode: DictationMode) -> Bool {
        guard case .gatePending = state,
              delegationGate.isPending(
                generation: stateGeneration
              ) else {
            return false
        }

        switch mode {
        case .command:
            resolveGateOutcome(
                delegationGate.commandKeyPressed(
                    generation: stateGeneration
                )
            )
        case .dictation:
            resolveGateOutcome(
                delegationGate.cancel(
                    generation: stateGeneration
                )
            )
        }
        return true
    }

    private func consumeGateKeyRelease(_ mode: DictationMode) {
        guard mode == .command,
              case .gatePending = state else {
            return
        }
        resolveGateOutcome(
            delegationGate.commandKeyReleased(
                generation: stateGeneration
            )
        )
    }

    private func consumeGateEscape() -> Bool {
        guard case .gatePending = state,
              delegationGate.isPending(
                generation: stateGeneration
              ) else {
            return false
        }
        resolveGateOutcome(
            delegationGate.cancel(
                generation: stateGeneration
            )
        )
        return true
    }

    private func resolveGateOutcome(
        _ outcome: DelegationGate.Outcome
    ) {
        switch outcome {
        case .none:
            return
        case .cancelled:
            setState(.idle, fastHUDDismiss: true)
        case let .confirmed(prompt):
            let pendingExecution = pendingGatedExecution
                ?? .delegation(prompt: prompt)
            pendingGatedExecution = nil
            setState(.idle)
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                switch pendingExecution {
                case let .delegation(prompt):
                    await self.launchDelegation(prompt: prompt)
                case let .customAction(invocation):
                    await self.commandExecutor.executeCustomAction(
                        invocation,
                        bypassingGate: true
                    )
                }
            }
        }
    }

    private func scheduleGateTimeout() {
        gateTimeoutTask?.cancel()
        let generation = stateGeneration
        guard case .gatePending = state,
              let remainingTime = delegationGate.remainingTime(
                generation: generation
              ) else {
            gateTimeoutTask = nil
            return
        }

        gateTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(remainingTime))
            guard !Task.isCancelled, let self else {
                return
            }
            self.gateTimeoutTask = nil
            guard case .gatePending = self.state,
                  generation == self.stateGeneration else {
                return
            }
            let outcome = self.delegationGate.cancelIfTimedOut(
                generation: generation
            )
            if outcome == .none {
                self.scheduleGateTimeout()
            } else {
                self.resolveGateOutcome(outcome)
            }
        }
    }

    private func launchDelegation(prompt: String) async {
        do {
            try await agentDelegator.launch(prompt: prompt)
            await flashFeedback("→ launched in terminal")
        } catch {
            print(
                "agent delegation failed: "
                    + error.localizedDescription
            )
            await flashFeedback("couldn't launch agent")
        }
    }

    private func launchCustomShell(
        _ command: String,
        trigger: String
    ) async {
        do {
            try await agentDelegator.launchCommand(command)
            await flashFeedback("→ \(trigger)")
        } catch {
            print(
                "custom shell action failed: "
                    + error.localizedDescription
            )
            await flashFeedback("couldn't run action")
        }
    }

    private func flashFeedback(
        _ message: String,
        duration: TimeInterval = 1.2
    ) async {
        feedbackGeneration += 1
        let feedbackToken = feedbackGeneration
        let stateToken = stateGeneration
        activeFeedbackGeneration = feedbackToken
        hudViewModel.showCommandFeedback(message)
        synchronizeHUD()

        try? await Task.sleep(for: .seconds(duration))
        guard stateToken == stateGeneration,
              feedbackToken == feedbackGeneration,
              activeFeedbackGeneration == feedbackToken else {
            return
        }

        activeFeedbackGeneration = nil
        hudViewModel.clearCommandFeedback()
        synchronizeHUD()
    }

    private func setState(
        _ newState: State,
        mode: DictationMode? = nil,
        fastHUDDismiss: Bool = false
    ) {
        clearDelegationGateForStateReplacement()
        stateGeneration += 1
        feedbackGeneration += 1
        activeFeedbackGeneration = nil
        state = newState
        hudViewModel.update(state: newState, mode: mode)

        synchronizeHUD(fastDismiss: fastHUDDismiss)
    }

    private func clearDelegationGateForStateReplacement() {
        gateTimeoutTask?.cancel()
        gateTimeoutTask = nil
        pendingGatedExecution = nil
        _ = delegationGate.cancelForStateReplacement()
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
                to: layout.size,
                animated: !NSWorkspace.shared
                    .accessibilityDisplayShouldReduceMotion
            )
        }
    }
}

private extension DictationCoordinator.State {
    var isTranscriptFlash: Bool {
        if case .transcriptFlash = self {
            return true
        }
        return false
    }
}
