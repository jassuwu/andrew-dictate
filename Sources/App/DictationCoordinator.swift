import Combine

enum EnginePreparationState: Equatable, Sendable {
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
    enum State: String, Equatable, Sendable {
        case idle
        case prewarming
        case recording
        case transcribing
        case commandModeComingSoon = "command mode coming soon"

        var systemImage: String {
            switch self {
            case .idle:
                "waveform"
            case .prewarming:
                "waveform.badge.exclamationmark"
            case .recording:
                "waveform.badge.mic"
            case .transcribing:
                "hourglass"
            case .commandModeComingSoon:
                "terminal"
            }
        }
    }

    @Published private(set) var state: State = .prewarming
    @Published private(set) var enginePreparationState:
        EnginePreparationState = .downloading(progress: 0)
    @Published private(set) var hotkeyDetection: HotkeyDetection?

    let dictionaryStore: DictionaryStore
    let settings: AppSettings

    private let hotkeyMonitor: HotkeyMonitor
    private var transcriptionEngine: ParakeetEngine
    private let paster: Paster
    private let audioRecorder: AudioRecorder?
    private let hudViewModel: HUDViewModel
    private let hudPanel: HUDPanel
    private var isPrewarmed = false
    private var activeMode: DictationMode?
    private var pipelineTask: Task<Void, Never>?
    private var pipelineGeneration = 0
    private var enginePrewarmTask: Task<Void, Never>?
    private var engineGeneration = 0
    private var settingsCancellables: Set<AnyCancellable> = []
    private var isApplyingPreRollSetting = false
    private var settingsWindowController: SettingsWindowController?
    private var onboardingWindowController: OnboardingWindowController?
    private var isOnboardingPresented: Bool
    private var hotkeyDetectionSequence = 0

    init(settings: AppSettings = .shared) {
        self.settings = settings
        isOnboardingPresented = !settings.onboardingCompleted
        dictionaryStore = DictionaryStore()
        transcriptionEngine = ParakeetEngine(
            version: settings.engineVersion
        )
        paster = Paster()

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
        hudPanel = HUDPanel(viewModel: viewModel)

        hotkeyMonitor = HotkeyMonitor(settings: settings)
        hotkeyMonitor.onBegin = { [weak self] mode in
            self?.beginRecording(mode)
        }
        hotkeyMonitor.onEnd = { [weak self] mode in
            self?.endRecording(mode)
        }
        hotkeyMonitor.onCancel = { [weak self] mode in
            self?.cancelRecording(mode)
        }
        hotkeyMonitor.onLockBegin = { [weak self] mode in
            self?.beginLockedRecording(mode)
        }
        hotkeyMonitor.onLockEnd = { [weak self] mode in
            self?.endRecording(mode)
        }
        hotkeyMonitor.onLockCancel = { [weak self] mode in
            self?.cancelRecording(mode)
        }
        hotkeyMonitor.onKeyDetected = { [weak self] mode in
            guard let self else {
                return
            }
            self.hotkeyDetectionSequence += 1
            self.hotkeyDetection = HotkeyDetection(
                mode: mode,
                sequence: self.hotkeyDetectionSequence
            )
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

        startPrewarming(transcriptionEngine)

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
        settings.onboardingCompleted = true
        onboardingWindowController?.close()
    }

    func onboardingWindowDidClose(
        _ controller: OnboardingWindowController
    ) {
        guard onboardingWindowController === controller else {
            return
        }
        onboardingWindowController = nil
        isOnboardingPresented = false
        synchronizeHUD()
    }

    func retryEnginePrewarm() {
        guard enginePreparationState == .failed else {
            return
        }
        startPrewarming(transcriptionEngine)
    }

    private func presentOnboarding() {
        isOnboardingPresented = true
        hudPanel.dismiss()

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
            transition(to: .idle)
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
        }

        enginePrewarmTask?.cancel()
        isPrewarmed = false

        let replacement = ParakeetEngine(version: version)
        transcriptionEngine = replacement
        startPrewarming(replacement)
    }

    private func startPrewarming(_ engine: ParakeetEngine) {
        engineGeneration += 1
        let generation = engineGeneration
        isPrewarmed = false
        enginePreparationState = .downloading(progress: 0)
        transition(to: .prewarming)

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
                self.transition(to: .idle)
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
                self.transition(to: .idle)
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

    private func beginRecording(_ mode: DictationMode) {
        if state == .transcribing || state == .commandModeComingSoon {
            invalidatePipeline()
            transition(to: .idle)
        }

        guard isPrewarmed else {
            transition(to: .prewarming)
            return
        }
        guard state == .idle else {
            return
        }
        guard let audioRecorder else {
            print("audio recorder unavailable")
            return
        }

        do {
            try audioRecorder.start()
            activeMode = mode
            transition(to: .recording)
        } catch {
            print("audio recording failed to start: \(error.localizedDescription)")
            activeMode = nil
            transition(to: .idle)
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
        }

        transition(to: .idle)
        beginRecording(mode)
    }

    private func endRecording(_ mode: DictationMode) {
        guard state == .recording,
              activeMode == mode,
              let audioRecorder else {
            return
        }

        do {
            let samples = try audioRecorder.stop()
            activeMode = nil
            transition(to: .transcribing)
            startPipeline(samples, mode: mode)
        } catch {
            print("audio recording failed to stop: \(error.localizedDescription)")
            activeMode = nil
            transition(to: .idle)
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
        transition(to: .idle)
    }

    private func startPipeline(
        _ samples: [Float],
        mode: DictationMode
    ) {
        pipelineGeneration += 1
        let generation = pipelineGeneration

        pipelineTask = Task { [weak self] in
            await self?.transcribeAndRoute(
                samples,
                mode: mode,
                generation: generation
            )
        }
    }

    private func transcribeAndRoute(
        _ samples: [Float],
        mode: DictationMode,
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

            let cleaner = DeterministicCleaner(entries: dictionaryStore.entries)
            let cleanedTranscript = cleaner.clean(transcript)

            guard !cleanedTranscript.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty else {
                return
            }

            switch mode {
            case .dictation:
                await paster.paste(cleanedTranscript)
            case .command:
                print("command: \(cleanedTranscript)")
                transition(to: .commandModeComingSoon)
                try await Task.sleep(for: .milliseconds(1_500))
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
    }

    private func finishPipeline(generation: Int) {
        guard generation == pipelineGeneration else {
            return
        }

        pipelineTask = nil
        transition(to: .idle)
    }

    private func transition(to newState: State) {
        state = newState
        hudViewModel.update(state: newState)

        synchronizeHUD()
    }

    private func synchronizeHUD() {
        if isOnboardingPresented || state == .idle {
            hudPanel.dismiss()
        } else {
            hudPanel.present()
        }
    }
}
