import Foundation

@MainActor
final class PipelinePlaygroundViewModel: ObservableObject {
    @Published var input: String
    @Published private(set) var selection = PipelineSelection()
    @Published private(set) var results: [PipelineStageResult] = []
    @Published private(set) var isPolishing = false

    /// read live: a word you teach andrew after opening this window should
    /// show up in the next run, not the next launch.
    private let entriesProvider: @MainActor () -> [DictionaryEntry]
    private let polisher: TranscriptPolisher
    private var polishTask: Task<Void, Never>?
    /// bumped on every input or toggle change; a polish that finishes after a
    /// newer one started is stale and must not overwrite the newer answer.
    private var runGeneration = 0

    init(
        entries: @escaping @MainActor () -> [DictionaryEntry],
        polisher: TranscriptPolisher = FoundationModelPolisher(),
        input: String = PipelineSample.text
    ) {
        entriesProvider = entries
        self.polisher = polisher
        self.input = input
        recompute()
    }

    var isPolishAvailable: Bool {
        polisher.isAvailable
    }

    func toggle(_ stage: PipelineStage) {
        guard !stage.isAlwaysOn else {
            return
        }
        selection.toggle(stage)
        recompute()
    }

    /// the settings pipe drives this from the real cleanup mode rather than
    /// a scratch toggle: there, the pipe *is* the control.
    func setPolishEnabled(_ enabled: Bool) {
        guard selection.polishEnabled != enabled else {
            return
        }
        selection.polishEnabled = enabled
        recompute()
    }

    func setDeterministicEnabled(_ enabled: Bool) {
        guard selection.deterministicEnabled != enabled else {
            return
        }
        selection.deterministicEnabled = enabled
        recompute()
    }

    func useSample() {
        input = PipelineSample.text
        recompute()
    }

    /// the deterministic half is pure and instant, so it runs on every
    /// keystroke. the model is not, so it waits for the typing to settle.
    func recompute() {
        runGeneration += 1
        let generation = runGeneration
        polishTask?.cancel()
        polishTask = nil

        let entries = entriesProvider()
        let cleaned = PipelineRun.throughCleaner(
            input,
            selection: selection,
            entries: entries
        )

        guard selection.polishEnabled else {
            isPolishing = false
            results = cleaned + [
                PipelineRun.polishResult(
                    input: PipelineRun.polishInput(from: cleaned),
                    output: nil,
                    isEnabled: false,
                    unavailableReason: nil
                ),
            ]
            return
        }

        let polishInput = PipelineRun.polishInput(from: cleaned)

        guard polisher.isAvailable else {
            isPolishing = false
            results = cleaned + [
                PipelineRun.polishResult(
                    input: polishInput,
                    output: nil,
                    isEnabled: true,
                    unavailableReason:
                        "needs macOS 26 and apple's on-device model"
                ),
            ]
            return
        }

        results = cleaned + [
            PipelineRun.polishResult(
                input: polishInput,
                output: nil,
                isEnabled: true,
                unavailableReason: nil
            ),
        ]
        isPolishing = true

        polishTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, generation == self.runGeneration else {
                return
            }

            var output: String?
            var failure: String?
            do {
                output = try await self.polisher.polish(
                    polishInput,
                    protectedTerms: entries.map(\.right)
                )
            } catch {
                failure = "the model couldn't polish this one"
            }

            guard !Task.isCancelled, generation == self.runGeneration else {
                return
            }

            self.isPolishing = false
            self.results = cleaned + [
                PipelineRun.polishResult(
                    input: polishInput,
                    output: output,
                    isEnabled: true,
                    unavailableReason: failure
                ),
            ]
        }
    }
}
