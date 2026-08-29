# andrew dictate — glossary

the domain model. one term, one meaning. if a word isn't here, it doesn't get used in code or docs.

| term | meaning |
|---|---|
| **utterance** | one press-to-release audio capture. the atomic unit of the whole app. |
| **transcript** | raw text produced by the engine for one utterance. never mutated in place. |
| **engine** | the ASR backend that turns audio into a transcript. parakeet via FluidAudio for dictation, whisper via WhisperKit for meetings. **code-only term** — every user-facing surface calls it the *speech model*. |
| **cleaner** | the deterministic pass. eight staged transforms, always on, no model. renders speech as writing; never decides you meant something else. |
| **lamp** | the bare gold line the hud draws while prewarming, recording, and cooling. its afterglow is the success signal, which is why failure must cut it short. |
| **pill** | the glass hud style. carries every exceptional message and nothing else — if the pill is showing, something needs saying. |
| **inserter** | puts a transcript into the frontmost app (paste-based, transactional, clipboard-restoring). the sole consumer of a transcript. |
| **hud** | the single floating panel (nonactivating NSPanel). shows recording state and results. the only persistent ui. |
| **prewarm** | loading + compiling the engine at launch so the hotkey path never touches model loading. |
| **onboarding** | the only place that asks macOS for permissions. first run: two grants + model download, ending with a working hotkey — and it returns whenever the app can no longer do its job. |
| **setup** | whether the app can dictate *right now*: both grants live, model ready. a fact about the present, re-asked; never a stored claim that it once succeeded. |
| **pre-roll** | optional ~300ms rolling in-memory mic buffer (user toggle) so the first word is never clipped. discarded continuously; never written anywhere. |
| **locked recording** | double-tap the dictation key to record hands-free; a single tap ends it and inserts as normal. |
| **dictation** | one delivered utterance, kept: raw + inserted text, time, engine, key-up→inserted. your own speech. deleted only by you. |
| **meeting recording** | a local recording of one named app plus your mic, from `record a meeting` to `stop`. holds other people's words, so it is its own noun with its own rules (ADR 0022). what survives is the transcript. |
| **tap** | the Core Audio process tap on the app you named. its channel is *them*. proved alive by hearing the start sound; never asked. |
| **you / them** | the two channels of a meeting: your mic is *you*, the tapped app is *them*. after stop the diarizer splits *them* into `them 1`, `them 2`… |
| **spool** | the 0600 audio file a meeting writes to while it runs. deleted the moment the transcript is saved; a spool orphaned by a crash is transcribed at next launch and saved `recovered`. |
| **live transcript** | the floating glass panel during a meeting: confirmed lines in ink, the tentative tail dimmed. the live pass *is* the transcript. |
| **transcript file** | the markdown file a meeting produces: front matter, then `you` / `them` lines with timestamps. english, always. |
| **hook** | one executable, run detached after a transcript is saved, with the path as `$1` and the details as json on stdin. the only event is `meeting-saved`. |
| **nudge** | after an hour of silence in a meeting, a notification asks `still recording?`. it asks; it never acts. |
