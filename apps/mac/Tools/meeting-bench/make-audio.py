#!/usr/bin/env python3
"""
two sides of a meeting, spoken by macOS `say`, as 16 kHz mono float32 wavs.

    ./make-audio.py [--out /tmp/meeting-bench] [--minutes 30] [--seed 7]

writes, under --out:

    audio/a-you.wav  audio/a-them.wav   variant a: ordinary alternating talk
    audio/b-you.wav  audio/b-them.wav   variant b: both sides talk at once
    audio/truth-a.json  truth-b.json    every turn: side, voice, language,
                                         start, end, text. the answer key.

each side's file is the whole meeting long, silence where that side is not
talking, so the two are time-aligned sample for sample.

how it is made:
- corpus.txt holds the sentences. a turn is a few of them in a row, drawn
  until the turn is 3 to 25 seconds long. each sentence is spoken once per
  voice and cached under --out/clips, then turns are assembled from the clips
  with a short breath between sentences.
- you is Rishi. them alternates Aman and Tara. about one them turn in seven
  is Hindi, spoken by Lekha.
- between turns there is a pause of 0.3 to 2 seconds.
- variant a: one side at a time, you / them / you / them.
- variant b: each side runs on its own clock, turn after turn, so they talk
  over each other most of the time. the overlap is printed and has to be at
  least a third of the meeting or the script stops.

generated audio is scratch. it does not belong in the repo.
"""
import argparse
import array
import concurrent.futures
import hashlib
import json
import math
import random
import struct
import subprocess
import wave
from pathlib import Path

RATE = 16_000
MIN_TURN, MAX_TURN = 3.0, 25.0
MIN_GAP, MAX_GAP = 0.3, 2.0
BREATH = (0.18, 0.45)  # between sentences inside one turn
HINDI_SHARE = 1 / 7
SPEAKING_RATE = {"Rishi": 185, "Aman": 180, "Tara": 175, "Lekha": 170}

HERE = Path(__file__).resolve().parent


def load_corpus():
    banks, current = {}, None
    for raw in (HERE / "corpus.txt").read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            current = line[1:-1]
            banks[current] = []
        else:
            banks[current].append(line)
    return banks


def clip_path(clips_dir, voice, text):
    key = hashlib.sha1(f"{voice}|{SPEAKING_RATE[voice]}|{text}".encode()).hexdigest()[:16]
    return clips_dir / f"{voice}-{key}.wav"


def speak(clips_dir, voice, text):
    path = clip_path(clips_dir, voice, text)
    if not path.exists():
        part = path.with_suffix(".part.wav")
        subprocess.run(
            ["say", "-v", voice, "-r", str(SPEAKING_RATE[voice]), "-o", str(part),
             "--file-format=WAVE", "--data-format=LEI16@16000", text],
            check=True)
        part.rename(path)
    return path


def read_clip(path):
    """int16 wav -> float32 array, with the silence `say` pads on both ends cut."""
    with wave.open(str(path), "rb") as w:
        assert w.getframerate() == RATE and w.getnchannels() == 1 and w.getsampwidth() == 2
        pcm = array.array("h")
        pcm.frombytes(w.readframes(w.getnframes()))
    floor = int(0.004 * 32768)
    start = next((i for i, s in enumerate(pcm) if abs(s) > floor), len(pcm))
    end = next((i for i in range(len(pcm) - 1, -1, -1) if abs(pcm[i]) > floor), start)
    return array.array("f", (s / 32768 for s in pcm[start:end + 1]))


class Clips:
    def __init__(self, clips_dir):
        self.dir = clips_dir
        self.cache = {}

    def get(self, voice, text):
        key = (voice, text)
        if key not in self.cache:
            self.cache[key] = read_clip(clip_path(self.dir, voice, text))
        return self.cache[key]


def prefetch(clips_dir, jobs):
    """speak every (voice, sentence) up front, a few `say`s at a time."""
    clips_dir.mkdir(parents=True, exist_ok=True)
    todo = [(v, t) for v, t in jobs if not clip_path(clips_dir, v, t).exists()]
    print(f"speaking {len(todo)} sentences ({len(jobs) - len(todo)} cached)")
    with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
        list(pool.map(lambda job: speak(clips_dir, *job), todo))


class Cast:
    """who speaks the next turn, and what they say."""

    def __init__(self, banks, clips, rng):
        self.banks, self.clips, self.rng = banks, clips, rng
        self.them_count = 0

    def turn(self, side):
        if side == "you":
            voice, lang, bank = "Rishi", "en", self.banks["you"]
        elif self.rng.random() < HINDI_SHARE:
            voice, lang, bank = "Lekha", "hi", self.banks["hindi"]
        else:
            self.them_count += 1
            voice = "Aman" if self.them_count % 2 else "Tara"
            lang, bank = "en", self.banks["them"]

        target = min(MAX_TURN, max(MIN_TURN, self.rng.lognormvariate(math.log(9), 0.6)))
        sentences, samples = [], array.array("f")
        pool = bank[:]
        self.rng.shuffle(pool)
        for sentence in pool:
            clip = self.clips.get(voice, sentence)
            breath = int(self.rng.uniform(*BREATH) * RATE) if sentences else 0
            if (len(samples) + breath + len(clip)) / RATE > MAX_TURN:
                if len(samples) / RATE >= MIN_TURN:
                    break
                continue
            samples.extend(array.array("f", bytes(4 * breath)))
            samples.extend(clip)
            sentences.append(sentence)
            if len(samples) / RATE >= target:
                break
        return {"side": side, "voice": voice, "lang": lang,
                "text": " ".join(sentences), "samples": samples}


def place(buffers, turn, at):
    """put a turn's samples into its side's buffer at `at` seconds."""
    start = int(at * RATE)
    samples = turn["samples"]
    buf = buffers[turn["side"]]
    buf[start:start + len(samples)] = samples
    turn["start"], turn["end"] = start / RATE, (start + len(samples)) / RATE


def variant_a(cast, rng, total):
    """one side at a time."""
    turns, t, side = [], 0.0, "you"
    while True:
        turn = cast.turn(side)
        if t + len(turn["samples"]) / RATE > total:
            return turns
        turn["at"] = t
        turns.append(turn)
        t += len(turn["samples"]) / RATE + rng.uniform(MIN_GAP, MAX_GAP)
        side = "them" if side == "you" else "you"


def variant_b(cast, rng, total):
    """each side on its own clock, so they overlap."""
    turns = []
    for side in ("you", "them"):
        t = rng.uniform(0, 1.5)
        while True:
            turn = cast.turn(side)
            if t + len(turn["samples"]) / RATE > total:
                break
            turn["at"] = t
            turns.append(turn)
            t += len(turn["samples"]) / RATE + rng.uniform(MIN_GAP, MAX_GAP)
    return turns


def overlap_seconds(turns):
    you = sorted((t["start"], t["end"]) for t in turns if t["side"] == "you")
    them = sorted((t["start"], t["end"]) for t in turns if t["side"] == "them")
    seconds = 0.0
    for a0, a1 in you:
        for b0, b1 in them:
            seconds += max(0.0, min(a1, b1) - max(a0, b0))
    return seconds


def write_float_wav(path, samples):
    """mono float32 wav (format tag 3). python's wave module only does ints."""
    data = samples.tobytes()
    header = (b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVE"
              + b"fmt " + struct.pack("<IHHIIHH", 16, 3, 1, RATE, RATE * 4, 4, 32)
              + b"data" + struct.pack("<I", len(data)))
    path.write_bytes(header + data)


def build(name, builder, banks, clips, seed, total, audio_dir):
    rng = random.Random(f"{seed}-{name}")
    cast = Cast(banks, clips, rng)
    turns = builder(cast, rng, total)
    n = int(total * RATE)
    buffers = {s: array.array("f", bytes(4 * n)) for s in ("you", "them")}
    for turn in turns:
        place(buffers, turn, turn["at"])
    for side, buf in buffers.items():
        write_float_wav(audio_dir / f"{name}-{side}.wav", buf)

    speech = {s: sum(t["end"] - t["start"] for t in turns if t["side"] == s) for s in buffers}
    both = overlap_seconds(turns)
    hindi = sum(1 for t in turns if t["lang"] == "hi")
    lengths = sorted(t["end"] - t["start"] for t in turns)
    print(f"variant {name}: {len(turns)} turns ({hindi} hindi), "
          f"turn length {lengths[0]:.1f} to {lengths[-1]:.1f} s, median {lengths[len(lengths) // 2]:.1f} s")
    print(f"  speech: you {speech['you']:.0f} s, them {speech['them']:.0f} s of {total:.0f} s; "
          f"both at once {both:.0f} s ({100 * both / total:.0f} percent of the meeting)")
    truth = [{k: (round(v, 3) if isinstance(v, float) else v) for k, v in t.items()
              if k not in ("samples", "at")} for t in sorted(turns, key=lambda t: t["start"])]
    (audio_dir / f"truth-{name}.json").write_text(
        json.dumps({"seconds": total, "bothAtOnceSeconds": round(both, 1), "turns": truth},
                   ensure_ascii=False, indent=1))
    return both


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", default="/tmp/meeting-bench")
    parser.add_argument("--minutes", type=float, default=30)
    parser.add_argument("--seed", default="7")
    args = parser.parse_args()

    out = Path(args.out)
    audio_dir = out / "audio"
    audio_dir.mkdir(parents=True, exist_ok=True)
    total = args.minutes * 60
    banks = load_corpus()

    jobs = [("Rishi", s) for s in banks["you"]]
    jobs += [(v, s) for v in ("Aman", "Tara") for s in banks["them"]]
    jobs += [("Lekha", s) for s in banks["hindi"]]
    clips_dir = out / "clips"
    prefetch(clips_dir, jobs)
    clips = Clips(clips_dir)

    build("a", variant_a, banks, clips, args.seed, total, audio_dir)
    both = build("b", variant_b, banks, clips, args.seed, total, audio_dir)
    if both < total / 3:
        raise SystemExit(f"variant b overlaps only {both:.0f} s, under a third of {total:.0f} s")
    print(f"written to {audio_dir}")


if __name__ == "__main__":
    main()
