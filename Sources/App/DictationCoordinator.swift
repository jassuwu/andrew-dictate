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

    private let hotkeyMonitor: HotkeyMonitor
    private let transcriptionEngine: ParakeetEngine
    private let paster: Paster
    private let audioRecorder: AudioRecorder?
    private var isPrewarmed = false

    init() {
        transcriptionEngine = ParakeetEngine()
        paster = Paster()

        do {
            audioRecorder = try AudioRecorder()
        } catch {
            audioRecorder = nil
            print("audio recorder initialization failed: \(error.localizedDescription)")
        }

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
            state = .idle
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
            print("still warming up")
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
            state = .recording
        } catch {
            print("audio recording failed to start: \(error.localizedDescription)")
            state = .idle
        }
    }

    private func endRecording() {
        guard state == .recording, let audioRecorder else {
            return
        }

        do {
            let samples = try audioRecorder.stop()
            state = .transcribing

            Task { [weak self] in
                await self?.transcribeAndPaste(samples)
            }
        } catch {
            print("audio recording failed to stop: \(error.localizedDescription)")
            state = .idle
        }
    }

    private func cancelRecording() {
        guard state == .recording, let audioRecorder else {
            return
        }

        audioRecorder.cancel()
        state = .idle
    }

    private func transcribeAndPaste(_ samples: [Float]) async {
        defer {
            state = .idle
        }

        do {
            let transcript = try await transcriptionEngine.transcribe(samples)
            await paster.paste(transcript)
        } catch {
            print("transcription failed: \(error.localizedDescription)")
        }
    }
}
