# fidelity

a developer tool, not part of the app. it answers one question: does feeding
audio to FluidAudio's sliding-window manager while you speak give the same
words as transcribing the whole utterance at key-up, which is what the app
does today?

same model both ways: parakeet v2, read from the cache the app already keeps
(`~/Library/Application Support/FluidAudio/Models`). nothing is downloaded. if
the models are missing, run the app once.

## build

```
cd apps/mac/Tools/fidelity
swift build -c release
```

the first build fetches FluidAudio, pinned to the same version as
`apps/mac/project.yml`. if you move that pin, move the one in `Package.swift`.

## 1. pick passages

```
.build/release/fidelity passages
```

reads `~/Library/Application Support/Andrew Dictate Dev/dictations.jsonl` and
picks about 20 distinct dictations of 60 to 250 words, spread across that
range, as things to read aloud. it prints a count and nothing of the text. the
prompts go to `prompts.json` in the recordings folder below. it will not
overwrite them unless you pass `--force`, because new prompts would no longer
match the recordings already made.

## 2. record them

```
.build/release/fidelity record 1
.build/release/fidelity record 2
...
```

shows prompt n. press Enter, read it aloud the way you would dictate it, press
Enter again. it saves `passage-NN.wav`, 16 kHz mono 32-bit float. record in the
room and at the distance you dictate from. recording again replaces the file.

the terminal needs microphone access (System Settings, Privacy & Security,
Microphone).

## 3. compare

```
.build/release/fidelity compare
.build/release/fidelity compare --files a.wav b.wav
```

with no `--files`, every `passage-*.wav` in the recordings folder. for each file
it prints batch and streaming timings and either `EQUAL` or a word diff:
`[-word-]` is in batch only, `{+word+}` in streaming only. only whitespace is
normalised; a different comma or capital counts. for a file that differs it
adds a second line saying whether the words still differ once case and
punctuation are ignored. that line is information, not the verdict.

it exits 1 if any file differs, 2 if it could not run.

the streaming settings are printed at the top of every run, as the call that
builds them. defaults are FluidAudio's own: 2 s left context, 11 s chunk, 2 s
right context, fed in 100 ms buffers. to try others:

```
--chunk 11 --left 2 --right 2 --buffer-ms 100
```

left + chunk + right can be at most 15 s, the model's input.

how the timings are taken:

- batch is `AsrManager.transcribe` on the whole file, as the app calls it.
- streaming is the time from the last buffer handed over to the final text.
  windows the earlier audio set off are allowed to finish first, because on a
  real mic they run while you are still talking. the count of windows that ran
  live is printed next to it.

## 4. bench

```
.build/release/fidelity bench --make
.build/release/fidelity bench
```

how long the engine takes to answer a take, by word count (1–5, 6–20, 21–60,
61–150), p50 and p90. `--make` synthesizes 16 clips with `say` into
`fidelity/bench/`, so no voice of yours is in them. three ways:

- warm: the engine just ran.
- cold: after `--idle` seconds of nothing (default 60), when the ANE has gone
  to sleep.
- woken at key-down: after the same idle, the app's wake (half a second of
  silence), then the take `--gap` seconds later (default 1). this is what a
  press does now.

it also prints what the wake pass itself costs. `--decay` adds how fast the ANE
forgets after a run. `--warm-only` skips the idle waits, which take about half
an hour. close other heavy work first; a busy cpu moves the numbers.

## 5. the app's own numbers

```
log show --last 1d --predicate 'subsystem == "gg.jass.dictate" AND category == "press"' \
  | .build/release/fidelity presses
```

reads press-log lines on stdin (from `log show`, `log stream`, or `copy
diagnostics`) and prints key-up → ⌘V for delivered presses by word count, the
same under 15 s of audio split by stage, and key-down → first audio by how the
mic is attached. `gg.jass.dictate` is the release build; the dev build logs
under `gg.jass.dictate.dev`.

## 6. the mic

```
.build/release/fidelity mic
```

how soon the default input is heard after a press asks for it, built the way
the app's capture is: cold (the engine built at the press, as the first press
after a device change used to be) and warm (built and prepared ahead, as the app
now does once the hardware settles), each timed to `start()` returning, to the
first sink-node callback (what lights the lamp now) and to the first tap buffer
(what used to). first it asks Core Audio whether `prepare()` alone started this
process's input, which is what the mic indicator shows. the terminal needs
microphone access.

## where things are

recordings and prompts are your voice and your own words. they live outside the
repo, in `~/Library/Application Support/Andrew Dictate Dev/fidelity/`, and are
never committed.
