# meeting-bench

a developer tool, not part of the app. it answers two questions the meetings
work needs numbers for before it is built:

- **a.** if a voice-activity detector cuts each side of a meeting into
  stretches and one model decodes every stretch once, does that keep up while
  the meeting is still going? whisper large-v3, and parakeet for comparison.
- **b.** how long does the end of a meeting take today: reading the spool back,
  the speaker split, and the last decode?

the models are read from the folders the app keeps
(`~/Library/Application Support/FluidAudio/Models`). whisper is never
downloaded; if it is missing the tool says so. parakeet and the Silero VAD
download on first use, as they do in the app.

## build

```
cd apps/mac/Tools/meeting-bench
swift build -c release
```

the first build fetches FluidAudio and WhisperKit, pinned to the same versions
as `apps/mac/project.yml`. if you move those pins, move the ones in
`Package.swift`. always time with the release build.

## 0. test audio

```
./make-audio.py                       # about 30 minutes, into /tmp/meeting-bench
./make-audio.py --minutes 5 --out /tmp/short
```

two sides of a meeting, spoken by macOS `say`: `you` is Rishi, `them` is Aman
and Tara taking turns, with about one `them` turn in seven in Hindi (Lekha).
turns are 3 to 25 seconds, with 0.3 to 2 seconds between them. the sentences
are in `corpus.txt`; a turn is a few of them in a row, and a sentence comes
round again in another turn after a while, so the text repeats.

it writes 16 kHz mono float wavs, one per side, the whole meeting long and
silent where that side is not talking, so the two line up sample for sample:

- `a-you.wav`, `a-them.wav`: ordinary talk, one side at a time.
- `b-you.wav`, `b-them.wav`: a stress case, each side on its own clock, so both
  talk at once most of the time. it prints how much and refuses to finish if
  that is under a third of the meeting.
- `truth-a.json`, `truth-b.json`: every turn with side, voice, language, times
  and text.

generated audio is scratch and belongs outside the repo.

## a. do two sides keep up?

```
.build/release/meeting-bench vad-check --you a-you.wav --them a-them.wav --truth truth-a.json
.build/release/meeting-bench decode --engine whisper-large-v3 --you b-you.wav --them b-them.wav --out whisper-b.json
.build/release/meeting-bench simulate whisper-b.json
.build/release/meeting-bench live --engine whisper-large-v3 --you b-you.wav --them b-them.wav \
    --seconds 600 --out whisper-b-live.json --compare whisper-b.json
```

**cutting.** Silero VAD (FluidAudio's), one probability per 256 ms, with
FluidAudio's own entry threshold (0.85) and exit rule. a stretch ends after
`--min-silence` (0.5 s) of quiet, or at `--cap` seconds: 25 for whisper, 15 for
parakeet, cut at the quietest chunk of the last six seconds. each end is padded
by 0.1 s. `vad-check` sets the cuts beside the turns in the truth file.

**decode.** cuts both sides, then decodes every stretch once, one after
another, with the app's own settings: whisper with the `translate` task,
language detection on and temperature 0, as `WhisperMeetingTranscriber` calls
it; parakeet as `ParakeetEngine` calls it. one decode of the first stretch goes
first and is not counted, so the model is warm, as it would be in a meeting.
for every stretch the run file keeps the side, start and end, the seconds its
decode took, the language whisper detected and the text. a `.txt` beside it
has the transcript in time order for reading by eye.

**simulate.** one decoder, one queue, both sides in it. a stretch becomes
available at its end and the decoder takes them in order of availability. lag
is the decode's finish minus the stretch's end. it prints max, p95 and mean
lag, utilisation (decode seconds per second of meeting, so above 1 can never
keep up), how many times the decoder was idle when a stretch arrived, and
whether the queue grows without bound. it prints the same again with a stretch
available only once the VAD knows it is over (end plus the pause), which is the
earliest a live run could have it.

**live.** the same, but the audio is fed at wall-clock speed in 256 ms steps,
each step goes through the VAD, a finished stretch is queued, and one decoder
takes them in order. nothing is simulated. with `--compare` it prints the real
lag beside the simulation, fed the decode times of this run and of the offline
run.

## b. how long does the end take?

```
.build/release/meeting-bench spool --you a-you.wav --them a-them.wav --hours 3 --out spool-3h.caf
.build/release/meeting-bench tail --from a-them.wav --start 1569.7 --out tail.wav
/usr/bin/time -l .build/release/meeting-bench ending --spool spool-3h.caf --tail tail.wav
```

**spool.** a two-channel 16 kHz float caf, left `you` and right `them`, written
the way `SpoolAudioFile` writes it, with the two wavs looped to the length
asked for.

**tail.** twenty seconds of a wav as its own file. give `--start` to pick a
stretch of speech; without it, the window ends where the last audible sample is.

**ending.** the steps of `MeetingCoordinator.finish`, in the app's order, each
timed on its own and numbered as the plan numbers them:

3. the last stretch at stop: one whisper large-v3 decode of the 20 s tail, the
   model already loaded and warm. the model is then let go, as the transcriber
   does after its last pass.
1. the whole spool read back with `SpoolAudioFile.read` (copied unchanged).
2. the speaker split on `them`: `FluidDiarizer`'s manager, models loaded from
   disk, clustering threshold 0.55. the time includes loading the models,
   because `split` loads them every time.

it prints resident memory now and the peak so far after each step. `time -l`
gives the process's maximum resident set size, which includes the model load
at the start; `--no-whisper` skips the model and step 3, to see steps 1 and 2
alone.

## timing

other builds on the same machine move every number here. each run waits until
no `xcodebuild`, `swift-frontend` or `swiftc` is running (up to 20 minutes),
prints the 1-minute load average when it starts, and samples both every 15
seconds while it runs, saying at the end whether a build showed up. do not
build while a timed run is going.

## what the numbers do not say

- the voices are synthetic: no breaths, no coughs, no crosstalk bleed from one
  side into the other, a steady level. real talk has more short pauses, so
  more and shorter stretches than these.
- the two sides are separate files, as in the spool. the app today decodes a
  mix of them; nothing here measures the mix.
- the run decodes on this machine's neural engine and gpu, with whatever else
  is using them.

## where things are

the audio, the spools and the run files are scratch. keep them in
`/tmp/meeting-bench` or any folder outside the repo.
