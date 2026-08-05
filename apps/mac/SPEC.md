# andrew dictate — v1 spec

> hold a key, talk, get text.
> free forever. fully local. small enough to read.

decisions in this spec are backed by ADRs in `docs/adr/` and the verified research in `~/repos/personal/andrew-dictate-research/`. terms are defined in `GLOSSARY.md` and used exactly.

## 1. product

- **name:** Andrew Dictate. binary/app: `Andrew Dictate.app`, cask `andrew-dictate`, repo `jassuwu/andrew-dictate` (MIT, public day one — ADR 0010).
- **platform:** macOS 14+, Apple Silicon only.
- **thesis:** frontier-fast dictation, with the smallest possible surface: no account, no cloud, no settings maze, no subscription. trust is architectural — the app contains no networking code except the model downloader.
- **non-goals (v1):** windows/linux, iOS, always-on listening (deferred — ADR 0003), LLM cleanup (v1.1 — ADR 0004), meeting transcription, history browser, App Store.
- **voice command mode: removed (2026-08-06).** shipped in early v1 (router tiers, agent delegation, ask/screen-ask), cut entirely to focus the product on dictation. this spec describes the app as it is; command-mode sections and terms are gone from here and the glossary.

## 2. the pipeline

one pipeline, one sink (ADR 0003):

```
hold fn ──▶ mic capture ──▶ key-up ──▶ engine (parakeet v2, prewarmed)
                                              │ transcript
                                              ▼ deterministic cleaner
                                              ▼ inserter (paste into frontmost app)
```

- **engine:** parakeet-tdt-0.6b-v2 int8 via FluidAudio, batch on key-up, prewarmed at launch with one dummy inference (ADR 0002, 0007). v3 optional in settings. engine sits behind an `Engine` protocol (streaming engines are additive later).
- **capture:** AVAudioEngine, hardware-native format, graph prepared at launch. **pre-roll is a user toggle (ADR 0012), chosen at onboarding:** ON = a ~300ms rolling ring buffer runs while the app is active (mic stays open, indicator stays lit, buffer lives only in memory and is discarded continuously) so the first word is never clipped; OFF = mic starts at key-down, maximum privacy posture. changeable in settings.
- **cleaner (v1, deterministic only — ADR 0004):** dictionary substitutions (wrong → right, dev vocabulary), filler removal rules (conservative list), spacing/casing normalization. microseconds, no model. behind a `Cleaner` protocol; qwen-based LLM cleanup is v1.1.
- **hotkeys (ADR 0008):** fn = dictation, rebindable, chord-cancel semantics. NSEvent flagsChanged monitoring; no Input Monitoring permission. **locked recording:** double-tap the dictation key to lock its capture hands-free; a single tap ends it and inserts as normal.

## 3. dictation

- key-up → transcript → cleaner → **inserter**.
- **insertion strategy (v1): transactional paste only.** snapshot pasteboard (all types), write plain text, synthetic cmd-V resolved for the active layout, verify change, restore only if `changeCount` still ours. AX selected-text insertion is v1.x.
- **target safety:** frontmost bundle id + focused-element captured at key-down; re-verified before paste. focus changed → don't paste; transcript stays on the clipboard + HUD shows "copied — focus changed."
- **secure fields:** detected via AX subrole → never auto-insert; HUD offers explicit copy.
- **escape hatch:** last transcript always available from the menu-bar menu ("copy last").

## 4. hud

one nonactivating, click-through `NSPanel` (borderless, floating, all-spaces). states:

`idle (hidden) → listening (level meter) → transcribing → inserted ✓ / copied-instead`

no dock icon. menu-bar item: tiny glyph → menu: copy last, settings, about, quit.

## 5. onboarding (once, one app click)

one fixed card introduces Andrew Dictate and has one consent action: "set up Andrew Dictate." nothing downloads and hotkeys remain detection-only before that click.

the click starts the parakeet v2 download and warmup, requests microphone access, and prompts for accessibility together. one live checklist shows microphone, accessibility, and speech-model status; download progress stays inline, denied permissions link to system settings, and model failures can retry.

key, pre-roll, and dictionary configuration are omitted. defaults apply: fn for dictation, pre-roll off. settings owns every option.

when all three rows are ready, the card says "ready — hold fn and speak." and closes automatically after a short confirmation. "skip for now" closes into a degraded but re-runnable app. no account, no tour, no newsletter.

## 6. settings (one sheet)

dictation key · pre-roll on/off · engine (v2 default, v3 downloadable) · dictionary editor (the one power feature: wrong→right pairs, import/export json) · launch at login. that's the whole sheet.

## 7. instrumentation (internal)

every utterance logs its stage timestamps locally (debug menu to dump):

`keyDown → micFirstBuffer → keyUp → transcriptReady → cleaned → pasteVerified`

working targets, not commitments: key-up → transcript ≤ 250ms, key-up → inserted ≤ 450ms (base M4, warm, p50). the public bench harness + published p50/p95 is **post-v1** — the timers exist so slow moments are debuggable, nothing more.

## 8. distribution

- unsigned in v1 (ADR 0009): github releases dmg + personal tap cask `jassuwu/tap/andrew-dictate`; README documents the gatekeeper step honestly. signing + notarization + sparkle gate the "tell other people" milestone.
- **about screen:** FluidAudio (Apache-2.0) notice, parakeet weights (CC-BY-4.0) attribution, MIT license.

## 9. milestones

- **M0 — walking skeleton:** fn-hold → parakeet → paste, hardcoded everything. success: dictate into any textbox.
- **M1 — dictation shippable:** onboarding, HUD, cleaner+dictionary, settings sheet, menu bar, cask. success: WisprFlow uninstalled.
- **M2 — release:** README, cask, about/attributions, polish pass. success: someone else could install it from scratch.
- *(historical: M2/M3 were command-mode tiers and delegation — built, shipped, then removed 2026-08-06. see §1.)*
- **post-v1 (ordered):** LLM cleanup (v1.1, ADR 0004) · signing (ADR 0009) · AX insertion · public bench harness + published p50/p95 · always-on ambient mode (ADR 0003) · v3/multilingual polish.

## 10. open questions (parked, non-blocking)

- **branding — v1 identity decided (2026-07-24):** five-bar waveform mark, charcoal `#1B1B1F` / cream `#EFEAE0` / persimmon accent `#E4593B` (the "held key" bar); lowercase wordmark in the system font; taglines fixed: "hold a key, talk, get text." + "free · open source · fully local". source of truth: `art/render.swift` (regenerates icon + og deterministically). website: still none, deliberately.
- HUD placement/personality (bottom-center pill vs near-cursor) — decide with a prototype at M1.
- dictation history beyond "copy last" — deliberately absent; revisit only if losing a transcript actually hurts.
- pre-roll buffer depth (~300ms is a starting guess) — tune once real first-word-loss data exists.
