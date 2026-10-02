# andrew dictate — glossary

the domain model. one term, one meaning. if a word isn't here, it doesn't get used in code or docs.

| term | meaning |
|---|---|
| **utterance** | the audio from one press to its release. the atomic unit of the whole app. only you throw one away (`esc`); sleep, the lock, the mic changing and the capture ceiling end it but keep it. |
| **transcript** | raw text produced by the engine for one utterance. never mutated in place. |
| **engine** | the ASR backend that turns audio into a transcript. parakeet via FluidAudio for dictation; whisper via WhisperKit for meetings, or parakeet v3 when it is the meeting model you picked. **code-only term** — every user-facing surface calls it the *speech model*. |
| **cleaner** | the deterministic pass. eight staged transforms, always on, no model. renders speech as writing; never decides you meant something else. |
| **lamp** | the bare gold line the hud draws while prewarming, recording, and cooling. it comes up dim at the press and lights, with the start chime, on the mic's first audio: lit means the mic is hearing you, not that a key went down. its afterglow is the success signal, which is why failure must cut it short. |
| **pill** | the glass hud style. carries every exceptional message and nothing else — if the pill is showing, something needs saying. |
| **inserter** | puts a transcript into the frontmost app (paste-based, transactional, clipboard-restoring). the sole consumer of a transcript. |
| **delivered** | a dictation whose ⌘V was posted with focus still where we left it. the only completion that counts toward the published latency; the app does not claim the target app accepted the text. |
| **dead press** | a press of the dictation key that ends in neither a delivered dictation nor a pill saying why: silence, an endless lamp, or "restart the app". the trust bar is zero of them, and that includes recovering by itself from anything the mac does underneath (sleep, the lid, displays, bluetooth, a call taking the mic). |
| **press record** | how one press of the dictation key ended — delivered, left on the pasteboard, heard nothing, refused and why… — with the mic and how it is attached, samples, peak level and stage timings. never a word of what was said; a word count at most. exactly one per press, whatever the ending: it is the evidence a dead press leaves. |
| **press log** | the press records: one notice-level line each in the unified log, and the last 200 in a 0600 file next to the dictation archive, wiped with your history. `copy diagnostics` hands over the last 50. |
| **hud** | the single floating panel (nonactivating NSPanel). shows recording state and results. the only persistent ui. |
| **streaming** | the engine transcribes while you are still talking, so key-up only finishes the tail. invisible: the text still lands once, at key-up, in one paste, and must match what the whole utterance would have produced. never live typing into the target app. |
| **learned entry** | a dictionary entry the app added itself: you made the same sound-alike swap to text we inserted twice. announced once, undone in one click, owned by you like any other entry. |
| **prewarm** | loading + compiling the engine at launch so the hotkey path never touches model loading. |
| **wake** | a throwaway pass through the engine at key-down, so it is warm at key-up. prewarm loads the engine; wake keeps it from idling. skipped while the engine is busy, so it never stands in front of an utterance. |
| **onboarding** | the only place that asks macOS for permissions. first run: two grants + model download, ending with a working hotkey — and it returns whenever the app can no longer do its job. |
| **setup** | whether the app can dictate *right now*: both grants live, model ready. a fact about the present, re-asked; never a stored claim that it once succeeded. |
| **capture** | the mic as the app holds it between presses: one `AVAudioEngine` on its own queue, bound to the default input, reused press after press until the hardware changes, then replaced — never rebuilt in place. |
| **pre-roll** | optional ~300ms rolling in-memory mic buffer (user toggle) so the first word is never clipped. discarded continuously; never written anywhere. |
| **mic turn** | the machine's hold on the capture for one utterance: started at key-down, stopped at its end. one capture serves many mic turns. |
| **chord** | another key going down while the dictation key is held. inside the first second it is a shortcut (fn+arrow) and the utterance is thrown away quietly; after that, or over a locked recording, it ends the utterance and keeps it. |
| **locked recording** | double-tap the dictation key to record hands-free; a single tap ends it and inserts as normal. |
| **capture ceiling** | five minutes of one utterance. the capture stops accepting frames; the take is kept and still inserted. |
| **dictation** | one delivered utterance, kept: raw + inserted text, time, engine, key-up→inserted. your own speech. deleted only by you. |
| **meeting recording** | a local recording of everything the mac plays plus your mic, from `record a meeting` to `stop`. no app is picked (ADR 0049); the file is called `meeting` unless the call app's name was known at the start. holds other people's words, so it is its own noun with its own rules (ADR 0022). what survives is the transcript. |
| **tap** | the Core Audio tap on the whole mac — every process, this app's included. its channel is *them*. proved alive by hearing the start sound; never asked. |
| **you / them** | the two channels of a meeting: your mic is *you*, everything the mac plays is *them* — the call, and a video or a notification sound if one plays. after stop the diarizer splits *them* into `them 1`, `them 2`… |
| **spool** | the 0600 audio file a meeting writes to while it runs. deleted the moment the transcript is saved; a spool orphaned by a crash is transcribed at next launch and saved `recovered`. |
| **live transcript** | the floating glass panel during a meeting: finished stretches, as they are decoded. the live pass *is* the transcript. |
| **transcript file** | the markdown file a meeting produces: front matter (who spoke, how many words, whether it is whole and why not), then one paragraph per speaker turn, `[hh:mm:ss] you: …`, with a new one every minute of a long monologue. english when the model translates (whisper large, the default); as spoken when it cannot (turbo). a `README.md` beside the month folders tells an agent what they are. |
| **hollow transcript** | a transcript file that says `complete` and does not cover what was said: empty, thin, or cut short, with the audio already gone. the meeting bar is zero of them, and zero lost meetings. |
| **meeting record** | how one meeting ended — saved, recovered, hollow, nothing kept and why — with speech seconds and word counts per side, gaps, mic and tap events and the coverage result. never a word of what was said. exactly one per meeting: it is the evidence a lost meeting or a hollow transcript leaves. |
| **hook** | one executable, run detached after a transcript is saved, with the path as `$1` and the details as json on stdin. the only event is `meeting-saved`. |
| **nudge** | after an hour of silence in a meeting, a notification asks `still recording?`. it asks; it never acts. |
| **update check** | the one request the app makes on its own. once a day it sends the running version to dictate.jass.gg and nothing else. never while dictating or recording a meeting. on unless switched off in settings (ADR 0043). |
| **update line** | `update to <x>` in the menu, shown when the update check heard of a newer version. a line and nothing else, no dot on the badge. a brew install runs the upgrade in the background and the line follows it: `updating…`, then `restart to finish`, or `couldn't update — command copied`. a dmg install gets the releases page. |
