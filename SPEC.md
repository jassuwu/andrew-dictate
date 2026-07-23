# andrew dictate — v1 spec

> hold a key, talk, get text. hold the other key, talk, things happen.
> free forever. fully local. small enough to read.

decisions in this spec are backed by ADRs in `docs/adr/` and the verified research in `~/repos/personal/andrew-dictate-research/`. terms are defined in `GLOSSARY.md` and used exactly.

## 1. product

- **name:** Andrew Dictate. binary/app: `Andrew Dictate.app`, cask `andrew-dictate`, repo `jassuwu/andrew-dictate` (MIT, public day one — ADR 0010).
- **platform:** macOS 14+, Apple Silicon only.
- **thesis:** frontier-fast dictation + voice command mode, with the smallest possible surface: no account, no cloud, no settings maze, no subscription. trust is architectural — the app contains no networking code except the model downloader.
- **non-goals (v1):** windows/linux, iOS, always-on listening (deferred — ADR 0003), LLM cleanup (v1.1 — ADR 0004), meeting transcription, history browser, App Store.

## 2. the pipeline

one pipeline, two sinks (ADR 0003):

```
hold key ──▶ mic capture ──▶ key-up ──▶ engine (parakeet v2, prewarmed)
                                              │ transcript
                                              ▼ deterministic cleaner
                    fn held ──────────────▶ inserter (paste into frontmost app)
                    right-⌥ held ─────────▶ router (tier 1 → 2 → 3)
```

- **engine:** parakeet-tdt-0.6b-v2 int8 via FluidAudio, batch on key-up, prewarmed at launch with one dummy inference (ADR 0002, 0007). v3 optional in settings. engine sits behind an `Engine` protocol (streaming engines are additive later).
- **capture:** AVAudioEngine, hardware-native format, graph prepared at launch. **pre-roll is a user toggle (ADR 0012), chosen at onboarding:** ON = a ~300ms rolling ring buffer runs while the app is active (mic stays open, indicator stays lit, buffer lives only in memory and is discarded continuously) so the first word is never clipped; OFF = mic starts at key-down, maximum privacy posture. changeable in settings.
- **cleaner (v1, deterministic only — ADR 0004):** dictionary substitutions (wrong → right, dev vocabulary), filler removal rules (conservative list), spacing/casing normalization. microseconds, no model. behind a `Cleaner` protocol; qwen-based LLM cleanup is v1.1.
- **hotkeys (ADR 0008):** fn = dictation, right-⌥ = command, both rebindable, chord-cancel semantics. NSEvent flagsChanged monitoring; no Input Monitoring permission. **locked recording:** double-tap a mode key to lock its capture hands-free; a single tap ends it and runs the normal sink for that mode.

## 3. dictation mode

- key-up → transcript → cleaner → **inserter**.
- **insertion strategy (v1): transactional paste only.** snapshot pasteboard (all types), write plain text, synthetic cmd-V resolved for the active layout, verify change, restore only if `changeCount` still ours. AX selected-text insertion is v1.x.
- **target safety:** frontmost bundle id + focused-element captured at key-down; re-verified before paste. focus changed → don't paste; transcript stays on the clipboard + HUD shows "copied — focus changed."
- **secure fields:** detected via AX subrole → never auto-insert; HUD offers explicit copy.
- **escape hatch:** last transcript always available from the menu-bar menu ("copy last").

## 4. command mode

key-up → transcript → **router**, first match wins:

| tier | matcher | examples | execution |
|---|---|---|---|
| 1 · verbs | keyword grammar, fuzzy app-name match | "open arc", "switch to slack", "quit music", "go to news.ycombinator.com", "type lgtm" | NSWorkspace / app activation / `open` / inserter. instant. |
| 2 · templates | `<site> [search] <query>` | "chatgpt search swift actors", "google parakeet wer", "claude explain monads", "youtube lofi" | open templated URL with query slotted in. instant. |
| 3 · delegation | everything else | "brew install arc", "commit what's staged with a sensible message" | **gate** → spawn user's terminal running the configured agent CLI with the transcript as prompt (ADR 0005, 0011). |

- **gate (ADR 0006):** tier 3 only. HUD shows parsed intent (`→ codex exec "brew install arc"`); tap right-⌥ again to run; esc or ~8s timeout cancels. tiers 1–2 execute ungated.
- **agent CLI (ADR 0011):** detected at onboarding (`codex`/`claude`/`opencode` on PATH), codex recommended default, custom `{prompt}` template allowed. transcript shell-escaped, always.
- **terminal app:** detected/selectable (Terminal, iTerm2, ghostty, warp).
- **no-match behavior:** there is no "no match" — tier 3 is the catch-all. no agent configured → HUD hint, nothing executes.
- **grammar is english, fixed, and documented in the README** — a dozen verbs, not a DSL. custom verbs/templates are post-v1.

## 5. hud

one nonactivating, click-through `NSPanel` (borderless, floating, all-spaces). states:

`idle (hidden) → listening (level meter + mode color) → transcribing → [dictation: inserted ✓ / copied-instead] · [command: intent preview → gated? → running/launched ✓]`

no dock icon. menu-bar item: tiny glyph → menu: copy last, settings, about, quit.

## 6. onboarding (once, ~60 seconds)

1. **welcome** — one screen, one sentence, "get started."
2. **permissions** — mic, then accessibility, each with a one-line why. functional checks, not boolean checks.
3. **model** — parakeet v2 download (~443MB) with progress; hotkey test enabled the moment it's warm.
4. **keys, agent & first word** — shows the two defaults with press-to-test; fn "Do Nothing" system hint; detected agent CLIs with codex preselected + custom entry; the pre-roll choice, stated honestly ("never lose your first word — keeps the mic warm while the app runs" vs "mic only while holding a key"); skip allowed.

done. no account, no tour, no newsletter.

## 7. settings (one sheet)

dictation key · command key · pre-roll on/off · engine (v2 default, v3 downloadable) · dictionary editor (the one power feature: wrong→right pairs, import/export json) · agent CLI + custom template · terminal app · launch at login. that's the whole sheet.

## 8. instrumentation (internal)

every utterance logs its stage timestamps locally (debug menu to dump):

`keyDown → micFirstBuffer → keyUp → transcriptReady → cleaned → pasteVerified`

working targets, not commitments: key-up → transcript ≤ 250ms, key-up → inserted ≤ 450ms (base M4, warm, p50). the public bench harness + published p50/p95 is **post-v1** — the timers exist so slow moments are debuggable, nothing more.

## 9. distribution

- unsigned in v1 (ADR 0009): github releases dmg + personal tap cask `jassuwu/tap/andrew-dictate`; README documents the gatekeeper step honestly. signing + notarization + sparkle gate the "tell other people" milestone.
- **about screen:** FluidAudio (Apache-2.0) notice, parakeet weights (CC-BY-4.0) attribution, MIT license.

## 10. milestones

- **M0 — walking skeleton:** fn-hold → parakeet → paste, hardcoded everything. success: dictate into any textbox.
- **M1 — dictation shippable:** onboarding, HUD, cleaner+dictionary, settings sheet, menu bar, cask. success: WisprFlow uninstalled.
- **M2 — command tiers 1–2:** verbs + templates, instant path. success: "open arc", "chatgpt search x" daily-driver.
- **M3 — delegation:** tier 3 + gate + CLI/terminal config. success: "brew install <thing>" via voice, gated.
- **M4 — release:** README, cask, about/attributions, polish pass. success: someone else could install it from scratch.
- **post-v1 (ordered):** LLM cleanup (v1.1, ADR 0004) · signing (ADR 0009) · AX insertion · public bench harness + published p50/p95 · custom verbs/templates · always-on ambient mode (ADR 0003) · v3/multilingual polish.

## 11. open questions (parked, non-blocking)

- **branding — entirely undecided:** logo, app icon, phrases/taglines, og image, website. until that pass happens, the plain name "Andrew Dictate" is the only branding anything ships with.
- HUD placement/personality (bottom-center pill vs near-cursor) — decide with a prototype at M1.
- "quit <app>" in tier 1: currently ungated (it's cmd-Q-equivalent); demote to gated if it ever bites.
- dictation history beyond "copy last" — deliberately absent; revisit only if losing a transcript actually hurts.
- pre-roll buffer depth (~300ms is a starting guess) — tune once real first-word-loss data exists.
