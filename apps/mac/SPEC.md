# andrew dictate — v1 spec

> hold a key, talk, get text.
> free forever. fully local. small enough to read.

decisions in this spec are backed by ADRs kept in `docs/adr/` and research in `~/repos/personal/andrew-dictate-research/` — **both are local-only and deliberately untracked** (see `.gitignore`), a private archive of how each decision was reached, including the ones later reversed. if you cloned this repo, you have the spec, not the archive; nothing here depends on reading it. terms are defined in `GLOSSARY.md` and used exactly.

## 1. product

- **name:** Andrew Dictate. binary/app: `Andrew Dictate.app`, cask `andrew-dictate`, repo `jassuwu/andrew-dictate` (MIT, public day one — ADR 0010).
- **platform:** macOS 14+, Apple Silicon only.
- **thesis:** frontier-fast dictation, with the smallest possible surface: no account, no cloud, no settings maze, no subscription. trust is architectural — the app contains no networking code except the model downloader.
- **non-goals (v1):** windows/linux, iOS, always-on listening (deferred — ADR 0003), ~~meeting transcription~~ (**crossed 2026-08-22 — ADR 0023**: manual start and stop, the app never observes which processes hold the mic), ~~history browser~~ (**superseded — ADR 0022**), App Store.
- **voice command mode: removed (2026-08-06).** shipped in early v1 (router tiers, agent delegation, ask/screen-ask), cut entirely to focus the product on dictation. this spec describes the app as it is; command-mode sections and terms are gone from here and the glossary.

## 2. the pipeline

one pipeline, one sink (ADR 0003):

```
hold fn ──▶ mic capture ──▶ key-up ──▶ engine (parakeet v2, prewarmed)
                                              │ transcript
                                              ▼ deterministic cleaner (always)
                                              ▼ ai polish (optional, on-device)
                                              ▼ inserter (paste into frontmost app)
```

- **engine:** parakeet-tdt-0.6b-v2 int8 via FluidAudio, batch on key-up, prewarmed at launch with one dummy inference (ADR 0002, 0007). v3 optional in settings. engine sits behind an `Engine` protocol (streaming engines are additive later).
- **capture:** AVAudioEngine, hardware-native format, graph prepared at launch. **pre-roll is a user toggle (ADR 0012), chosen at onboarding:** ON = a ~300ms rolling ring buffer runs while the app is active (mic stays open, indicator stays lit, buffer lives only in memory and is discarded continuously) so the first word is never clipped; OFF = mic starts at key-down, maximum privacy posture. changeable in settings.
- **cleaner (deterministic, always on — ADR 0004, 0019, 0020):** eight staged transforms — whitespace normalization, spoken punctuation, email/url/number parsing, dictionary substitutions, capitalization, punctuation finishing. **it renders what you said into how it is written, and never decides you meant something else** (ADR 0020): the three stages that edited rather than transcribed — self-corrections, repetition collapse, filler removal — are gone, because each of them could silently change correct speech into something that still read perfectly. stumbles reach the page unless the optional polish is on. microseconds, no model, pure functions. not user-disableable: it is where the dictionary and spoken punctuation live, and without it you get raw asr.
- **ai polish (optional, shipped 2026-08 — ADR 0018):** apple's on-device foundation model (`SystemLanguageModel`, macOS 26+), off by default, three modes: `off` · `on` (600ms budget, raw on timeout) · `always` (15s ceiling). a messy gate decides whether a transcript is worth sending at all. when `always` can't deliver — model unavailable, threw, or blew the deadline — it pastes raw and **says so** in the hud; `on` falling back to raw is that mode working and stays silent. below macOS 26 the whole layer is absent and the settings row must say so rather than vanish.
- **hotkeys (ADR 0008):** fn = dictation, rebindable, chord-cancel semantics. NSEvent flagsChanged monitoring; no Input Monitoring permission. **locked recording:** double-tap the dictation key to lock its capture hands-free; a single tap ends it and inserts as normal.

## 3. dictation

- key-up → transcript → cleaner → **inserter**.
- **insertion strategy (v1): transactional paste only.** snapshot pasteboard (all types), write plain text, synthetic cmd-V resolved for the active layout, verify change, restore only if `changeCount` still ours. AX selected-text insertion is v1.x.
- **target safety:** frontmost bundle id + focused-element captured at key-down; re-verified before paste. focus changed → don't paste; transcript stays on the clipboard + HUD shows "copied — focus changed."
- **secure fields:** detected via AX subrole → never auto-insert; HUD offers explicit copy.
- **what it keeps (ADR 0022, 0026):** every delivered dictation is written to `dictations.jsonl` in application support — raw + inserted text, time, engine, key-up→inserted — **on by default**, stated in onboarding, with the toggle and `delete all` in settings. cancelled dictations are not kept; there was no text. chmod 0600. this is a deliberate contrast with pre-roll's off-by-default: pre-roll opens a microphone, this keeps text already produced and already pasted.
- **escape hatch:** last transcript always available from the menu-bar menu ("copy last"). it is the **raw** engine output, deliberately — which is also why "fix a word…" sits beside it: you point at what it misheard and the dictionary entry is built from the transcript rather than from your memory of it (ADR 0024). an entry typed from memory that is one character off silently never fires.

## 4. hud

one nonactivating, click-through `NSPanel` (borderless, floating, all-spaces), in two styles:

- **bare — the lamp (2026-08-12).** a single gold line drawn in a canvas on a transparent panel: dim ember while prewarming, a wave whose amplitude and tungsten colour ride your voice while recording, then a cool-out that collapses it to a hot dot and fades. no capsule, no shadow — they would clip the bloom. **success is silent: the afterglow is the whole goodbye.** the earlier glass capsule with eleven bars, and the transcript flash that followed a paste, are both removed.
- **glass — the pill.** the exceptional-message style, and the only thing that ever speaks: `copied — secure field` · `copied — focus changed` · `couldn't transcribe` · `heard nothing` · `recording was lost` · `polish timed out — pasted raw` · `couldn't polish — pasted raw` · `speech model failed — retrying` · `microphone access is off` · `no microphone available`.

the rule: **a failed dictation must never look like a successful one.** anything that goes wrong cuts the afterglow short and says why.

no dock icon. menu-bar item: the brand badge → menu: copy last, settings, finish setup / run onboarding again, about, quit. a red dot on the badge means a permission is missing.

## 5. onboarding (once, one app click)

one fixed card introduces Andrew Dictate and has one consent action: "set up Andrew Dictate." nothing downloads and hotkeys remain detection-only before that click.

the click starts the parakeet v2 download and warmup, requests microphone access, and prompts for accessibility together. one live checklist shows microphone, accessibility, and speech-model status; download progress stays inline, denied permissions link to system settings, and model failures can retry.

key, pre-roll, and dictionary configuration are omitted. defaults apply: fn for dictation, pre-roll off. settings owns every option.

when all three rows are ready, the card says "ready — hold fn and speak." and closes automatically after a short confirmation. no account, no tour, no newsletter.

**permissions are re-verified, never remembered (2026-08-13).** "skip for now" records only that the window was closed — it no longer claims setup succeeded. whether the app can dictate is asked of the system at launch, at reopen, on wake and unlock, and when macOS reports a trust change. a working setup is never nagged again; a broken one gets the window back at launch or reopen, and mid-session revocation only badges the menu bar — stealing focus while you type is the sin this app exists to prevent. settings shows what's missing and routes here, because this is the only place that knows how to ask.

## 6. settings (one sheet)

one scroll, in order: **setup** (only when something is missing — names it, hands back to onboarding) · **dictation key** · **dictation** (pre-roll · sound feedback · ai cleanup · cleanup lab) · **speech model** (v2 default, v3 downloadable, with preparation status and removal) · **dictionary** (the one power feature: wrong→right pairs, import/export json) · **general** (launch at login).

two rules, both learned the hard way: options that appear on more than one screen are **defined once** (`DictationOption`) and rendered twice — the copy cannot drift because there is only one copy. and the user-facing word for the asr backend is **speech model** everywhere; `engine` survives only in code (`ParakeetEngine`, `EngineVersion`). "parakeet 0.3" is a value, not a category.

## 7. instrumentation (internal)

every utterance logs its stage timestamps locally (debug menu to dump):

`keyDown → micFirstBuffer → keyUp → transcriptReady → cleaned → pasteVerified`

working targets, not commitments: key-up → transcript ≤ 250ms, key-up → inserted ≤ 450ms (base M4, warm, p50). **the published quantity is key-up → inserted** — key-up → transcript would flatter us by excluding the span the claim is about (ADR 0025). "copy timings" ships in **release**: it prints p50/p95/max over verified pastes only, with the sample size, the exclusions, and the machine/chip/os/engine/build it was measured on, above the per-utterance table it came from. anyone can produce that number on their own mac from their own speech, which is the point — it replaces the standalone bench harness rather than deferring it. **no competitor benchmark is published**: the only figure that exists anywhere is a rival founder's estimate, and a claim resting on that is not evidence.

## 8. distribution

- unsigned in v1 (ADR 0009): github releases dmg + personal tap cask `jassuwu/tap/andrew-dictate`; README documents the gatekeeper step honestly. signing + notarization + sparkle gate the "tell other people" milestone.
- **about screen:** FluidAudio (Apache-2.0) notice, parakeet weights (CC-BY-4.0) attribution, MIT license.

## 9. milestones

- **M0 — walking skeleton:** fn-hold → parakeet → paste, hardcoded everything. success: dictate into any textbox.
- **M1 — dictation shippable:** onboarding, HUD, cleaner+dictionary, settings sheet, menu bar, cask. success: WisprFlow uninstalled.
- **M2 — release:** README, cask, about/attributions, polish pass. success: someone else could install it from scratch.
- *(historical: M2/M3 were command-mode tiers and delegation — built, shipped, then removed 2026-08-06. see §1.)*
- *(historical: LLM cleanup was post-v1 until it shipped as on-device ai polish, 2026-08. see §2.)*
- **post-v1 (ordered):** signing (ADR 0009) · AX insertion · public bench harness + published p50/p95 · always-on ambient mode (ADR 0003) · v3/multilingual polish.

## 10. open questions (parked, non-blocking)

- **branding — settled.** black + gold; the badge is the logo everywhere and is never a template image. art lives in `art/`: `logo-character.svg` rasterizes to the icon set via `build.sh`, which then runs `og-compose.swift` for the og image. *(the icons currently committed came from a different path than `build.sh` produces — unreconciled, 2026-08-13.)* taglines: "escape the keyboard." + "free · open source · fully local".
- **website — shipped (2026-08-11):** dictate.jass.gg, astro, in `apps/site`.
- **HUD placement/personality — decided (2026-08-12):** bottom-centre, the lamp. see §4.
- ~~dictation history beyond "copy last" — deliberately absent~~ **superseded 2026-08-22 (ADR 0022).** two durable nouns: a **dictation** is your own speech and is kept until you delete it (raw + inserted text, 0600 on disk, no record of which app you were in); a **meeting recording** holds other people's words and is a separate type with its own retention rules, decided alongside meeting capture. the old test — "revisit only if losing a transcript hurts" — was measured and fails: nothing is lost, because a bad dictation gets fixed in place. history exists because a tool used a hundred times a day should leave a trace, not as a safety net.
- pre-roll buffer depth (~300ms is a starting guess) — tune once real first-word-loss data exists.
