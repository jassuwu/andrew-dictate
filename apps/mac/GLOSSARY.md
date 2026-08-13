# andrew dictate — glossary

the domain model. one term, one meaning. if a word isn't here, it doesn't get used in code or docs.

| term | meaning |
|---|---|
| **utterance** | one press-to-release audio capture. the atomic unit of the whole app. |
| **transcript** | raw text produced by the engine for one utterance. never mutated in place. |
| **engine** | the ASR backend that turns audio into a transcript. parakeet via FluidAudio. **code-only term** — every user-facing surface calls it the *speech model*. |
| **cleaner** | the deterministic pass. eleven staged transforms, always on, no model. |
| **polish** | the optional on-device LLM pass after the cleaner (apple foundation models, macOS 26+). off by default. never silently substitutes for the cleaner. |
| **lamp** | the bare gold line the hud draws while prewarming, recording, and cooling. its afterglow is the success signal, which is why failure must cut it short. |
| **pill** | the glass hud style. carries every exceptional message and nothing else — if the pill is showing, something needs saying. |
| **inserter** | puts a transcript into the frontmost app (paste-based, transactional, clipboard-restoring). the sole consumer of a transcript. |
| **hud** | the single floating panel (nonactivating NSPanel). shows recording state and results. the only persistent ui. |
| **prewarm** | loading + compiling the engine at launch so the hotkey path never touches model loading. |
| **onboarding** | the only place that asks macOS for permissions. first run: two grants + model download, ending with a working hotkey — and it returns whenever the app can no longer do its job. |
| **setup** | whether the app can dictate *right now*: both grants live, model ready. a fact about the present, re-asked; never a stored claim that it once succeeded. |
| **pre-roll** | optional ~300ms rolling in-memory mic buffer (user toggle) so the first word is never clipped. discarded continuously; never written anywhere. |
| **locked recording** | double-tap the dictation key to record hands-free; a single tap ends it and inserts as normal. |
