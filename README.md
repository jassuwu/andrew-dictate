<p align="center">
  <img src="art/icon_1024.png" width="128" alt="Andrew Dictate" />
</p>

<h1 align="center">andrew dictate</h1>

<p align="center">hold a key, talk, get text. — free · open source · fully local</p>

Andrew Dictate is a native macOS menu-bar app for fast, local speech-to-text. hold a key, talk, and either paste clean text or route a spoken command.

## two modes

- dictation — hold `fn`, speak, then release to paste the cleaned transcript into the current app.
- command — hold right `⌥`, speak, then release to route a command. try “open Arc” or “ChatGPT search swift actors”; catch-all commands such as “brew install ripgrep” require a second right-`⌥` confirmation before the configured agent CLI runs.

## install from source

requirements: macOS 14 or newer on Apple Silicon, Xcode, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
git clone https://github.com/jassuwu/andrew-dictate.git
cd andrew-dictate
xcodegen generate
xcodebuild \
  -project AndrewDictate.xcodeproj \
  -scheme AndrewDictate \
  -configuration Release \
  -derivedDataPath .build \
  build
open ".build/Build/Products/Release/Andrew Dictate.app"
```

source builds are unsigned. if Gatekeeper blocks the first launch, locate the app in Finder, right-click it, choose **Open**, then confirm **Open**.

## first run

Andrew Dictate asks for microphone access to record speech and accessibility access to paste into other apps. it then downloads the roughly 450 MB NVIDIA Parakeet v2 model and warms it locally; command-line agent setup can be skipped.

## settings

- dictation key — choose the hold key for text insertion.
- command key — choose a different hold key for command routing.
- pre-roll — keep a short microphone buffer warm or capture only while a key is held.
- engine — use Parakeet v2 by default or download Parakeet v3.
- dictionary — maintain wrong-to-right substitutions, with JSON import and export.
- agent CLI — select a detected agent or provide a custom `{prompt}` command template.
- terminal — choose where gated agent commands launch.
- launch at login — start Andrew Dictate when you sign in.

## privacy

transcription, cleanup, command routing, and the short pre-roll buffer all stay on this Mac. the app contains no network code beyond model download.

with pre-roll on, the microphone stays open while the app runs and about 300 ms of audio is held only in memory, continuously overwritten and discarded; this protects the first word from clipping. with pre-roll off, the microphone captures only while a mode key is held.

## license and attributions

Andrew Dictate is released under the [MIT license](LICENSE).

- [FluidAudio](https://github.com/FluidInference/FluidAudio) — Apache-2.0.
- [NVIDIA Parakeet TDT 0.6B v2/v3 model weights](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) — CC-BY-4.0.
