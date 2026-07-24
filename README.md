<p align="center">
  <img src="art/icon_1024.png" width="140" alt="Andrew Dictate" />
</p>

<h1 align="center">andrew dictate</h1>

<p align="center"><strong>escape the keyboard.</strong></p>

local speech-to-text and voice commands for macOS. free, open source, runs entirely on your mac.

## what it does

**hold `fn`, speak, release** → text pastes wherever your cursor is. ~250ms after key-up, on-device.

**hold right `⌥`, speak, release** → things happen:

| you say | it does |
|---|---|
| "open arc" / "switch to slack" / "quit music" | instant app control |
| "chatgpt search swift actors" / "youtube lofi" | opens the site with your query |
| "what's the tallest building in the world?" | answers inline on the floating panel |
| "what's this error?" | screenshots the window, asks your agent cli, answers inline; press again for follow-ups |
| "brew install ripgrep" | shows the exact command, runs in your terminal after one confirming tap |
| "standup" / "deploy {branch}" / any phrase you define | your urls, scripts, macos shortcuts, snippets — settings → actions |

spoken answers are a toggle; talking over it interrupts it. a personal dictionary fixes the words it mishears ("jason" → `json`).

cleanup is built in: spoken punctuation ("comma", "new paragraph"), emails ("john at cypher dot io" → `john@cypher.io`), numbers ("five hundred dollars" → $500), self-corrections ("ship it friday, actually monday" → "ship it monday"), and stumble removal — all deterministic, all on-device, all instant. optional ai polish on top (apple's on-device model, off by default, three modes: off / on / always) with a local "cleanup lab" showing raw-vs-cleaned pairs so you can judge it on your own speech before trusting it.

## install

```sh
brew install --cask jassuwu/tap/andrew-dictate
xattr -dr com.apple.quarantine "/Applications/Andrew Dictate.app"
```

or the dmg from [releases](https://github.com/jassuwu/andrew-dictate/releases). builds are unsigned (no apple developer membership); the `xattr` line or right-click → open clears gatekeeper.

first run: one click, ~450 mb model download, mic + accessibility permissions. dictating in about a minute.

## privacy

- transcription is fully on-device ([parakeet](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) via [FluidAudio](https://github.com/FluidInference/FluidAudio)). audio never leaves the mac.
- no accounts, no telemetry, no network code except the model download.
- questions/screen-asks go to the agent cli **you** configure (codex / claude / opencode), read-only flags enforced, screenshots deleted after send. no history stored — your agent keeps its own sessions.
- shell commands always show before they run. per-command "always allow" is your choice.
- small swift codebase. read it.

## limits

- apple silicon, macOS 14+.
- english by default; multilingual model optional in settings.
- ai polish uses apple's on-device model (macos 26) — no downloadable model option yet.
- ask/screen-ask need an agent cli installed; everything else works without one.

## credits

[FluidAudio](https://github.com/FluidInference/FluidAudio) (apache-2.0) · [parakeet weights](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) (cc-by-4.0) · [mit](LICENSE) · made by [jass](https://jass.gg)

---

<p align="center">
  <img src="art/icon_1024.png" width="72" alt="" /><br/>
  <sub>the matrix wants you typing.</sub>
</p>
