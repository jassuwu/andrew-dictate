import Foundation

@MainActor
final class PipelinePlaygroundViewModel: ObservableObject {
    @Published var input: String
    @Published private(set) var selection = PipelineSelection()
    @Published private(set) var results: [PipelineStageResult] = []

    /// read live: a word you teach andrew after opening this window should
    /// show up in the next run, not the next launch.
    private let entriesProvider: @MainActor () -> [DictionaryEntry]

    init(
        entries: @escaping @MainActor () -> [DictionaryEntry],
        input: String = PipelineSample.text
    ) {
        entriesProvider = entries
        self.input = input
        recompute()
    }

    func toggle(_ stage: PipelineStage) {
        guard !stage.isAlwaysOn else {
            return
        }
        selection.toggle(stage)
        recompute()
    }

    /// the settings pipe drives this from the real cleanup switch rather than
    /// a scratch toggle: there, the pipe *is* the control.
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

    /// pure and instant, so it runs on every keystroke.
    func recompute() {
        results = PipelineRun.throughCleaner(
            input,
            selection: selection,
            entries: entriesProvider()
        )
    }
}
