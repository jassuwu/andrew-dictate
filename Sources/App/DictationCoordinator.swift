import Combine
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
    enum State: Equatable, Sendable {
        case idle
        case prewarming
        case recording
        case transcribing
        case gatePending(
            commandPreview: String,
            confirmationKeyName: String
        )

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
            case .gatePending:
                "gate pending"
            }
        }

    }

    @Published private(set) var state: State = .prewarming
    @Published private(set) var enginePreparationState:
        EnginePreparationState = .notStarted
    @Published private(set) var hotkeyDetection: HotkeyDetection?
    @Published private(set) var lastTranscript: String?

    let dictionaryStore: DictionaryStore
    let settings: AppSettings

    private let hotkeyMonitor: HotkeyMonitor
    private var transcriptionEngine: ParakeetEngine
    private let paster: Paster
    private let commandRouter = CommandRouter()
    private let commandExecutor: CommandExecutor
    private let agentDelegator: AgentDelegator
    private let audioRecorder: AudioRecorder?
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
    private var enginePreparationRequested: Bool
    private var settingsCancellables: Set<AnyCancellable> = []
    private var isApplyingPreRollSetting = false
    private var settingsWindowController: SettingsWindowController?
    private var onboardingWindowController: OnboardingWindowController?
    private var isOnboardingPresented: Bool
    private var hotkeyDetectionSequence = 0
    private var stateGeneration: UInt64 = 0
    private var delegationGate = DelegationGate()
    private var gateTimeoutTask: Task<Void, Never>?
    private var feedbackGeneration: UInt64 = 0
    private var activeFeedbackGeneration: UInt64?
    private let timelineClock = ContinuousClock()
    private let timelineStore = UtteranceTimelineStore()
    private var timelineSequence: UInt64 = 0
    private var activeTimeline: UtteranceTimelineBuilder?
    private var aboutWindowController: AboutWindowController?
    private var workspaceNotificationObservers: [NSObjectProtocol] = []
    private var distributedNotificationObservers: [NSObjectProtocol] = []

    init(settings: AppSettings = .shared) {
        self.settings = settings
        isOnboardingPresented = !settings.onboardingCompleted
        enginePreparationRequested = settings.onboardingCompleted
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
            print("audio recorder initialization failed: \(error.localizedDescription)")
        }
        audioRecorder = recorder

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

        let monitor = HotkeyMonitor(settings: settings)
        hotkeyMonitor = monitor

        executor.onDelegate = { [weak self] prompt in
            await self?.requestDelegation(prompt)
        }
        executor.onFeedback = { [weak self] message in
            await self?.flashFeedback(message)
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
            self?.consumeGateKeyPress(mode) ?? false
        }
        monitor.onModeKeyReleased = { [weak self] mode, _ in
            self?.consumeGateKeyRelease(mode)
        }
        monitor.onEscape = { [weak self] in
            self?.consumeGateEscape() ?? false
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
                self?.replaceEngine(with: version)
            }
            .store(in: &settingsCancellables)

        installSystemLifecycleObservers()

        if enginePreparationRequested {
            startPrewarming(transcriptionEngine)
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

    func copyLastTranscript() {
        guard let lastTranscript else {
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        _ = pasteboard.setString(lastTranscript, forType: .string)
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

    func onboardingSectionsDidChange(enabled: Bool) {
        guard isOnboardingPresented else {
            return
        }

        hotkeyMonitor.setDetectionOnly(enabled)
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
        guard version == settings.engineVersion else {
            return
        }

        invalidatePipeline()
        if state == .recording {
            audioRecorder?.cancel()
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
        setState(.idle)

        await transcriptionEngine.unloadModels()
    }

    private func presentOnboarding() {
        isOnboardingPresented = true
        hotkeyMonitor.setDetectionOnly(false)
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

    private func replaceEngine(with version: EngineVersion) {
        invalidatePipeline()
        if state == .recording {
            audioRecorder?.cancel()
            activeMode = nil
            activeFocusAnchor = nil
            activeTimeline = nil
        }

        enginePrewarmTask?.cancel()
        enginePrewarmTask = nil
        engineHealthTask?.cancel()
        engineHealthTask = nil
        engineGeneration += 1
        let generation = engineGeneration
        isPrewarmed = false
        enginePreparationState = enginePreparationRequested
            ? .downloading(progress: 0)
            : .notStarted
        setState(.prewarming)

        let previousEngine = transcriptionEngine
        let replacement = ParakeetEngine(version: version)
        transcriptionEngine = replacement
        engineSwapTask = Task { @MainActor [weak self] in
            await previousEngine.cancelPreparation()

            guard !Task.isCancelled,
                  let self,
                  generation == self.engineGeneration else {
                return
            }

            self.engineSwapTask = nil
            if self.enginePreparationRequested {
                self.startPrewarming(replacement)
            }
        }
    }

    private func requestEnginePreparation() {
        enginePreparationRequested = true
        guard !isPrewarmed,
              enginePrewarmTask == nil,
              engineSwapTask == nil else {
            return
        }

        startPrewarming(transcriptionEngine)
    }

    private func startPrewarming(_ engine: ParakeetEngine) {
        engineGeneration += 1
        let generation = engineGeneration
        isPrewarmed = false
        enginePreparationState = .downloading(progress: 0)
        setState(.prewarming)

        enginePrewarmTask = Task { [weak self] in
            do {
                try await engine.prewarm { [weak self] update in
                    Task { @MainActor [weak self] in
                        self?.applyPreparationUpdate(
                            update,
                            generation: generation
                        )
                    }
                }
                try Task.checkCancellation()
                guard let self,
                      generation == self.engineGeneration else {
                    return
                }
                self.isPrewarmed = true
                self.enginePreparationState = .ready
                self.enginePrewarmTask = nil
                self.setState(.idle)
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      generation == self.engineGeneration else {
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

    private func applyPreparationUpdate(
        _ update: TranscriptionPreparationUpdate,
        generation: Int
    ) {
        guard generation == engineGeneration,
              enginePrewarmTask != nil,
              !isPrewarmed else {
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
            activeMode = nil
            activeFocusAnchor = nil
            activeTimeline = nil
            setState(.idle)
        case .gatePending:
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
        if state == .transcribing {
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
            activeMode = mode
            activeFocusAnchor = focusAnchor
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
            activeTimeline?.transcriptReady = timelineClock.now

            switch mode {
            case .dictation:
                let cleaner = DeterministicCleaner(
                    entries: dictionaryStore.entries
                )
                let cleanedTranscript = cleaner.clean(transcript)
                activeTimeline?.cleaned = timelineClock.now
                guard !cleanedTranscript.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty else {
                    activeTimeline = nil
                    return
                }
                lastTranscript = cleanedTranscript
                let pasteResult = await paster.paste(
                    cleanedTranscript,
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
                    settings.recordDictatedTranscript(cleanedTranscript)
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
                    await flashFeedback(
                        feedbackMessage(for: reason)
                    )
                }
            case .command:
                let commandTranscript = DictionarySubstituter(
                    entries: dictionaryStore.entries
                ).apply(to: transcript)
                activeTimeline?.cleaned = timelineClock.now
                let command = commandRouter.route(commandTranscript)
                completeTimeline(
                    at: timelineClock.now,
                    stage: .commandRouted
                )
                await commandExecutor.execute(command)
            }
        } catch is CancellationError {
            return
        } catch {
            print("transcription failed: \(error.localizedDescription)")
        }
    }

    private func invalidatePipeline() {
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
        delegationGate.present(
            prompt: prompt,
            commandPreview: commandPreview,
            generation: stateGeneration
        )
        scheduleGateTimeout()
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
            setState(.idle)
            Task { @MainActor [weak self] in
                await self?.flashFeedback("cancelled")
            }
        case let .confirmed(prompt):
            setState(.idle)
            Task { @MainActor [weak self] in
                await self?.launchDelegation(prompt: prompt)
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
        mode: DictationMode? = nil
    ) {
        clearDelegationGateForStateReplacement()
        stateGeneration += 1
        feedbackGeneration += 1
        activeFeedbackGeneration = nil
        state = newState
        hudViewModel.update(state: newState, mode: mode)

        synchronizeHUD()
    }

    private func clearDelegationGateForStateReplacement() {
        gateTimeoutTask?.cancel()
        gateTimeoutTask = nil
        _ = delegationGate.cancelForStateReplacement()
    }

    private func synchronizeHUD() {
        if isOnboardingPresented {
            withHUDPanel { $0.dismiss() }
        } else if activeFeedbackGeneration != nil || state != .idle {
            withHUDPanel { $0.present() }
        } else {
            withHUDPanel { $0.dismiss() }
        }
    }
}
