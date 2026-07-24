<p align="center">
  <img src="art/icon_1024.png" width="140" alt="Andrew Dictate" />
</p>

<h1 align="center">andrew dictate</h1>

<p align="center"><strong>escape the keyboard.</strong></p>

<p align="center">hold a key, talk, get text. hold the other key, talk, things happen.</p>

---

## what this is

a menu-bar app for macs that turns your voice into text, anywhere you can type — and into actions, questions, and answers when you want more than text. it runs entirely on your machine, costs nothing, and phones home to nobody.

i built it because i was paying a monthly subscription to dictate into my own computer, on my own cpu, through someone else's cloud. that felt backwards. the models are open, the hardware is right here, and the glue code isn't rocket science. so: free, local, open source, and honestly pretty fast — transcription lands in a few hundred milliseconds on apple silicon.

## what it does

**dictation** — hold `fn`, say the thing, let go. the cleaned-up text pastes wherever your cursor is. your personal dictionary fixes the words it always gets wrong ("jason" → `json`, whatever yours are).

**command mode** — hold right `⌥` and just say it:

- "open arc" · "switch to slack" · "quit music" — instant.
- "chatgpt search swift actors" · "youtube lofi" — opens with your query.
- "what's the tallest building in the world?" — answered right on the little glass panel. no browser, no window.
- "what's this error?" — it looks at your screen, sends it to your own ai agent, and explains. press again to ask a follow-up; the conversation continues. you can even pick that same conversation up later in your terminal — it was your agent's session all along.
- "brew install ripgrep" — shows you exactly what it's about to run, and runs it in your terminal only after you confirm. one tap.
- your own phrases too: teach it "standup" → your meet link, "deploy staging" → your script, or wire any macos shortcut to a spoken word. (settings → actions.)

it can also talk back — there's a toggle for spoken answers, and you can interrupt it mid-sentence by just starting to talk, which is more satisfying than it has any right to be.

## what it doesn't do

being honest here, because you'd find out anyway:

- **apple silicon only, macOS 14+.** intel macs and older systems are out.
- **english first.** the default model is english-only; a multilingual model (25 european languages) is one click away in settings, but english is where it shines.
- **the builds are unsigned.** i haven't bought the apple developer membership yet, so gatekeeper complains once on install (fix below). the app is open source — when the trust question comes up, the answer is the code.
- **no ai rewriting of your words yet.** what you say is what you get, cleaned up deterministically (fillers, spacing, your dictionary). a local-llm polish layer is the next big thing on the list.
- command mode's smart stuff (questions, screen-asks) works through **your own agent cli** — codex, claude, or opencode, whichever you already have. no agent installed? dictation and the instant commands work fine without one.

## install

```sh
brew install --cask jassuwu/tap/andrew-dictate
xattr -dr com.apple.quarantine "/Applications/Andrew Dictate.app"
```

or grab the dmg from [releases](https://github.com/jassuwu/andrew-dictate/releases). the `xattr` line clears the unsigned-app quarantine; right-click → open works too if you'd rather.

first run is one card and one click: it downloads the speech model (~450 mb, one time), asks for microphone (to hear you) and accessibility (to paste for you), and you're dictating in about a minute. everything's configurable later; nothing needs configuring now. screen access is only requested if you ever ask it about your screen.

## the trust part

this matters most, so plainly:

- your voice is transcribed **on your mac** by [nvidia parakeet](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) running through [FluidAudio](https://github.com/FluidInference/FluidAudio). audio never leaves the machine. the app has no accounts, no analytics, no telemetry, and no network code at all except the one-time model download.
- when you *ask* something in command mode, your question (and a screenshot, if you asked about your screen — deleted right after) goes to the agent cli **you** configured, under **your** keys and **your** subscriptions. we add read-only flags so asks can't touch anything. nothing is stored by this app — not even your conversation history, because your agent already keeps its own.
- shell commands never run silently. you see the exact command on screen and confirm it. you can mark your own trusted commands to skip the gate — your call, per command.
- don't take my word for any of this. it's a small swift codebase. read it.

## for the curious

native swift, one menu-bar process. parakeet v2 runs on the neural engine via coreml — the same engine family the fancy paid apps use. the floating indicator is a real blur panel with a gold soundwave that maps your actual voice level (decibels, like a proper meter). answers stream in as your agent generates them, and the agent process is actually launched *while you're still speaking*, so it feels quicker than it should. there's a pile of design notes and an architecture spec in the repo if you enjoy that sort of thing.

built in the open, fast, with a lot of help from ai agents — which felt right, for a tool whose command mode is basically a voice remote for ai agents. every release is built, tested, and published by ci from a tag.

## credits

- [FluidAudio](https://github.com/FluidInference/FluidAudio) — apache-2.0. the coreml asr runtime doing the heavy lifting.
- [nvidia parakeet tdt 0.6b](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) model weights — cc-by-4.0.
- [mit licensed](LICENSE). made by [jass](https://jass.gg).

---

<p align="center">
  <img src="art/icon_1024.png" width="72" alt="" /><br/>
  <sub>the matrix wants you typing.</sub>
</p>
