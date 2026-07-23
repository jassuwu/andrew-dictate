import Combine

@MainActor
final class DictationCoordinator: ObservableObject {
    enum State: String, Equatable, Sendable {
        case idle
        case prewarming
        case recording
        case transcribing

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
            }
        }
    }

    @Published private(set) var state: State = .prewarming

    let dictionaryStore: DictionaryStore

    private let hotkeyMonitor: HotkeyMonitor
    private let transcriptionEngine: ParakeetEngine
    private let paster: Paster
    private let audioRecorder: AudioRecorder?
    private let hudViewModel: HUDViewModel
    private let hudPanel: HUDPanel
    private var isPrewarmed = false

    init() {
        dictionaryStore = DictionaryStore()
        transcriptionEngine = ParakeetEngine()
        paster = Paster()

        let recorder: AudioRecorder?
        do {
            recorder = try AudioRecorder()
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

        hotkeyMonitor = HotkeyMonitor()
        hotkeyMonitor.onBegin = { [weak self] in
            self?.beginRecording()
        }
        hotkeyMonitor.onEnd = { [weak self] in
            self?.endRecording()
        }
        hotkeyMonitor.onCancel = { [weak self] in
            self?.cancelRecording()
        }

        Task { [weak self] in
            await self?.prewarm()
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

    private func beginRecording() {
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
            transition(to: .recording)
        } catch {
            print("audio recording failed to start: \(error.localizedDescription)")
            transition(to: .idle)
        }
    }

    private func endRecording() {
        guard state == .recording, let audioRecorder else {
            return
        }

        do {
            let samples = try audioRecorder.stop()
            transition(to: .transcribing)

            Task { [weak self] in
                await self?.transcribeAndPaste(samples)
            }
        } catch {
            print("audio recording failed to stop: \(error.localizedDescription)")
            transition(to: .idle)
        }
    }

    private func cancelRecording() {
        guard state == .recording, let audioRecorder else {
            return
        }

        audioRecorder.cancel()
        transition(to: .idle)
    }

    private func transcribeAndPaste(_ samples: [Float]) async {
        defer {
            transition(to: .idle)
        }

        do {
            let transcript = try await transcriptionEngine.transcribe(samples)
            let cleaner = DeterministicCleaner(entries: dictionaryStore.entries)
            let cleanedTranscript = cleaner.clean(transcript)

            guard !cleanedTranscript.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty else {
                return
            }

            await paster.paste(cleanedTranscript)
        } catch {
            print("transcription failed: \(error.localizedDescription)")
        }
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
