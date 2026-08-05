<p align="center">
  <img src="apps/mac/art/icon_1024.png" width="140" alt="Andrew Dictate" />
</p>

<h1 align="center">andrew dictate</h1>

<p align="center"><strong>escape the keyboard.</strong></p>

local speech-to-text for macOS. free, open source, runs entirely on your mac.

## what it does

**hold `fn`, speak, release** → text pastes wherever your cursor is. ~250ms after key-up, on-device.

a personal dictionary fixes the words it mishears ("jason" → `json`).

cleanup is built in: spoken punctuation ("comma", "new paragraph"), emails ("jass at jass dot gg" → `jass@jass.gg`), numbers ("five hundred dollars" → $500), self-corrections ("ship it friday, actually monday" → "ship it monday"), and stumble removal — all deterministic, all on-device, all instant. optional ai polish on top (apple's on-device model, off by default, three modes: off / on / always) with a local "cleanup lab" showing raw-vs-cleaned pairs so you can judge it on your own speech before trusting it.

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
- small swift codebase. read it.

## limits

- apple silicon, macOS 14+.
- english by default; multilingual model optional in settings.
- ai polish uses apple's on-device model (macos 26) — no downloadable model option yet.

## credits

[FluidAudio](https://github.com/FluidInference/FluidAudio) (apache-2.0) · [parakeet weights](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) (cc-by-4.0) · [mit](LICENSE) · made by [jass](https://jass.gg)

---

<p align="center">
  <img src="apps/mac/art/icon_1024.png" width="72" alt="" /><br/>
  <sub>the matrix wants you typing.</sub>
</p>
