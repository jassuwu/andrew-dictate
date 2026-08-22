<p align="center">
  <img src="apps/mac/art/icon_1024.png" width="140" alt="Andrew Dictate" />
</p>

<h1 align="center">andrew dictate</h1>

<p align="center"><strong>escape the keyboard.</strong></p>

local speech-to-text for macOS. free, open source, runs entirely on your mac.

**alpha.** v0.7.0 works and is not finished. see the [roadmap](#roadmap).

## what it does

**hold `fn`, speak, release** → text pastes wherever your cursor is. ~250ms after key-up, on-device.

a personal dictionary fixes the words it mishears ("jason" → `json`).

cleanup is built in: spoken punctuation ("comma", "new paragraph"), emails ("jass at jass dot gg" → `jass@jass.gg`), numbers ("five hundred dollars" → $500), your own dictionary — all deterministic, all on-device, all instant. it renders what you said into how it's written and never rewrites your words: no filler stripping, no guessing at self-corrections. optional ai polish on top (apple's on-device model, off by default, three modes: off / on / always) with a local "cleanup lab" showing raw-vs-cleaned pairs so you can judge it on your own speech before trusting it.

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

## roadmap

**works today**

- hold `fn`, speak, release — text pastes wherever your cursor is
- transcription runs fully on-device (parakeet, via FluidAudio)
- eight deterministic cleanup transforms — spoken punctuation, emails, numbers, your dictionary, capitalization. it never rewrites the words you said
- a personal dictionary for the words it mishears
- optional ai polish on apple's on-device model, off by default
- a lab that shows raw-vs-cleaned pairs on your own speech, so you can judge the cleanup before you trust it
- locked recording — double-tap the key to go hands-free

**building next**

- signed and notarized builds with auto-update — this kills the `xattr` step
- meeting capture: record a call, get a transcript, with the speakers separated
- a history surface — everything you've dictated, not just the last thing
- published latency benchmarks you can reproduce on your own mac

**thinking about**

- formatting that adapts to the app you're dictating into
- learning from the corrections you make by hand
- inserting text directly instead of pasting, for apps where paste fights back
- always-on ambient mode
- more languages

**never**

- accounts, cloud, sync
- a paid tier — it's free, permanently
- telemetry of any kind
- windows, linux, ios — this is a mac app

## credits

[FluidAudio](https://github.com/FluidInference/FluidAudio) (apache-2.0) · [parakeet weights](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) (cc-by-4.0) · [mit](LICENSE) · made by [jass](https://jass.gg)

---

<p align="center">
  <img src="apps/mac/art/icon_1024.png" width="72" alt="" /><br/>
  <sub>the matrix wants you typing.</sub>
</p>
