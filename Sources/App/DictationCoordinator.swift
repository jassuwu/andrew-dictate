import Combine

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

    let dictionaryStore: DictionaryStore
    let settings: AppSettings

    private let hotkeyMonitor: HotkeyMonitor
    private let transcriptionEngine: ParakeetEngine
    private let paster: Paster
    private let audioRecorder: AudioRecorder?
    private let hudViewModel: HUDViewModel
    private let hudPanel: HUDPanel
    private var isPrewarmed = false
    private var activeMode: DictationMode?
    private var pipelineTask: Task<Void, Never>?
    private var pipelineGeneration = 0
    private var settingsCancellables: Set<AnyCancellable> = []
    private var isApplyingPreRollSetting = false

    init(settings: AppSettings = .shared) {
        self.settings = settings
        dictionaryStore = DictionaryStore()
        transcriptionEngine = ParakeetEngine()
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

        settings.$preRollEnabled
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] enabled in
                self?.applyPreRoll(enabled)
            }
            .store(in: &settingsCancellables)

        Task { [weak self] in
            await self?.prewarm()
        }
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

    private func prewarm() async {
        defer {
            transition(to: .idle)
        }

        do {
            try await transcriptionEngine.prewarm()
            isPrewarmed = true
        } catch {
            print("transcription engine prewarm failed: \(error.localizedDescription)")
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

        if newState == .idle {
            hudPanel.dismiss()
        } else {
            hudPanel.present()
        }
    }
}
