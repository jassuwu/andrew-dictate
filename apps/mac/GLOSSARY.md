# andrew dictate — glossary

the domain model. one term, one meaning. if a word isn't here, it doesn't get used in code or docs.

| term | meaning |
|---|---|
| **utterance** | one press-to-release audio capture. the atomic unit of the whole app. |
| **transcript** | raw text produced by the engine for one utterance. never mutated in place. |
| **engine** | the ASR backend that turns audio into a transcript. v1: parakeet via FluidAudio. |
| **inserter** | puts a transcript into the frontmost app (paste-based, transactional, clipboard-restoring). the sole consumer of a transcript. |
| **hud** | the single floating panel (nonactivating NSPanel). shows recording state and results. the only persistent ui. |
| **prewarm** | loading + compiling the engine at launch so the hotkey path never touches model loading. |
| **onboarding** | first run: two permission grants + model download. ends with a working hotkey. |
| **pre-roll** | optional ~300ms rolling in-memory mic buffer (user toggle) so the first word is never clipped. discarded continuously; never written anywhere. |
| **locked recording** | double-tap the dictation key to record hands-free; a single tap ends it and inserts as normal. |
