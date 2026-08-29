import Foundation

/// walks one piece of text through the stages the user has switched on and
/// records what each layer handed to the next. the same order the real
/// dictation path uses — if these two ever disagree, the playground is a lie.
enum PipelineRun {
    /// pure, instant, safe to run on every keystroke.
    static func throughCleaner(
        _ input: String,
        selection: PipelineSelection,
        entries: [DictionaryEntry]
    ) -> [PipelineStageResult] {
        let heard = PipelineStageResult(
            stage: .transcription,
            input: input,
            // you are standing in for the microphone: what you typed is what
            // parakeet is pretending to have heard.
            output: input,
            isEnabled: true
        )

        guard selection.deterministicEnabled else {
            // off is not "nothing": the dictionary still applies, exactly as
            // it does on the real path.
            return [
                heard,
                PipelineStageResult(
                    stage: .deterministic,
                    input: input,
                    output: DeterministicCleaner(
                        entries: entries,
                        fullCleanup: false
                    ).clean(input),
                    isEnabled: false
                ),
            ]
        }

        let cleaned = DeterministicCleaner(entries: entries).clean(input)
        return [
            heard,
            PipelineStageResult(
                stage: .deterministic,
                input: input,
                output: cleaned,
                isEnabled: true
            ),
        ]
    }
}
