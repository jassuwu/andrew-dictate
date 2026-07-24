# andrew dictate — glossary

the domain model. one term, one meaning. if a word isn't here, it doesn't get used in code or docs.

| term | meaning |
|---|---|
| **utterance** | one press-to-release audio capture. the atomic unit of the whole app. |
| **transcript** | raw text produced by the engine for one utterance. never mutated in place. |
| **engine** | the ASR backend that turns audio into a transcript. v1: parakeet via FluidAudio. |
| **mode** | which sink an utterance feeds. exactly two in v1: **dictation** and **command**. determined by which hotkey was held. |
| **sink** | the consumer of a transcript. dictation mode → the **inserter**. command mode → the **router**. |
| **inserter** | puts a transcript into the frontmost app (paste-based, transactional, clipboard-restoring). |
| **router** | decides which tier handles a command transcript. tier 1 → tier 2 → tier 3, first match wins. |
| **verb** (tier 1) | a deterministic built-in action matched by keyword: open, switch, go to, type. no LLM, <10ms. |
| **template** (tier 2) | a parameterized site action: "chatgpt search X" → url with X slotted in. no LLM. |
| **delegation** (tier 3) | handoff of the transcript to an agent CLI (claude/codex/opencode). the CLI is the agent runtime; we never build tool-calling. |
| **gate** | the confirmation step shown before a risky action executes. |
| **hud** | the single floating panel (nonactivating NSPanel). shows recording state, intent previews, gates, results. the only persistent ui. |
| **prewarm** | loading + compiling the engine at launch so the hotkey path never touches model loading. |
| **onboarding** | first run: two permission grants + model download. ends with a working hotkey. |
| **pre-roll** | optional ~300ms rolling in-memory mic buffer (user toggle) so the first word is never clipped. discarded continuously; never written anywhere. |
| **locked recording** | double-tap a mode key to record hands-free; a single tap ends it and runs that mode's sink. |
| **weaver** | the product philosophy: stitch tools that already exist on the mac (agent clis, screencapture, tts, shortcuts) instead of building capabilities; own only the voice layer and a session handle. |
| **ask** | inline question-answering: headless read-only agent-cli call, answer in the hud (+ optional voice). the command-mode catch-all. |
| **screen-ask** | an ask with an ephemeral screen capture attached; "this" → frontmost window, "my screen" → active display. |
| **follow-up window** | the multi-turn ux: pressing the command key while an answer is visible (+~12s) continues the same agent session. thread state = one in-memory session id; history lives in the agent's own storage. |
| **barge-in** | pressing to talk while the answer is being spoken cuts the speech instantly. |
| **custom action** | user-defined trigger phrase → { open, url, shortcut, shell, type, ask } payload with optional {arg} capture; matched first, exact-after-normalization. |
