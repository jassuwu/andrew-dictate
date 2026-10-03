import { describe, expect, test } from "bun:test";
import { meetingScene, pace, type Call } from "../src/demo/meeting";

// the meeting scene as a visitor meets it: press record, lines come in, press
// stop, one file appears, an agent reads it.

const call: Call = {
  file: "2026-10-03-1402-zoom.md",
  ask: "What did I promise?",
  lines: [
    { speaker: "you", second: 4, text: "Can you hear me?" },
    { speaker: "them 1", second: 7, text: "Yes." },
    { speaker: "you", second: 15, text: "I'll cut the release." },
  ],
  stops: [
    { duration: 10, saved: "saved · <1m", reply: "Nothing yet.", markdown: "one line" },
    { duration: 13, saved: "saved · <1m", reply: "Nothing yet.", markdown: "two lines" },
    { duration: 61, saved: "saved · 1m", reply: "One thing.", markdown: "three lines" },
  ],
};

const scene = meetingScene(call);

/** when line `n` (1-based) is on the panel, for a record at `at`. */
const line = (at: number, n: number) => at + pace.ready + n * pace.line;

describe("record, then stop", () => {
  const recording = scene.step(scene.initial(), { type: "record", at: 1000 });
  const stopAt = line(1000, 3) + 500;
  const stopped = scene.step(recording, { type: "stop", at: stopAt });

  test("gives the file after `writing it out…` and `saved`", () => {
    const writing = scene.view(stopped, stopAt);
    expect(writing.phase).toBe("writingOut");
    expect(writing.pill).toBe("writing it out…");
    expect(writing.file).toBeNull();

    // `saved` is a moment, said on the pill. it is not a phase.
    const saved = scene.view(stopped, stopAt + pace.write);
    expect(saved.phase).toBe("idle");
    expect(saved.status).toBe("");
    expect(saved.pill).toBe("saved · 1m");
    expect(scene.view(stopped, stopAt + pace.write + pace.pill).pill).toBeNull();
    expect(saved.file).toEqual({ name: "2026-10-03-1402-zoom.md", markdown: "three lines" });
  });

  test("then an agent is asked, and answers from the file", () => {
    const at = stopAt + pace.write;
    expect(scene.view(stopped, at).ask).toBeNull();
    expect(scene.view(stopped, at + pace.ask).ask).toBe("What did I promise?");
    expect(scene.view(stopped, at + pace.ask).reply).toBeNull();
    expect(scene.view(stopped, at + pace.ask + pace.reply).reply).toBe("One thing.");
  });

  test("and record again starts the scene over", () => {
    const again = scene.step(stopped, { type: "record", at: stopAt + 60_000 });
    const view = scene.view(again, stopAt + 60_000);
    expect(view.phase).toBe("gettingReady");
    expect(view.lines).toEqual([]);
    expect(view.file).toBeNull();
    expect(view.reply).toBeNull();
  });
});

describe("while it records", () => {
  const recording = scene.step(scene.initial(), { type: "record", at: 1000 });

  test("it gets ready first, and says when it is recording", () => {
    expect(scene.view(recording, 1000).phase).toBe("gettingReady");
    expect(scene.view(recording, 1000).status).toBe("getting ready…");
    const started = scene.view(recording, 1000 + pace.ready);
    expect(started.phase).toBe("recording");
    expect(started.pill).toBe("recording a meeting");
  });

  test("lines come in one at a time, the far side plain `them`", () => {
    expect(scene.view(recording, line(1000, 1) - 1).lines).toEqual([]);
    expect(scene.view(recording, line(1000, 2)).lines).toEqual([
      { speaker: "you", stamp: "00:00:04", text: "Can you hear me?" },
      { speaker: "them", stamp: "00:00:07", text: "Yes." },
    ]);
    expect(scene.view(recording, line(1000, 3) + 60_000).lines.length).toBe(3);
  });

  test("stop is not offered before the first line", () => {
    expect(scene.view(recording, line(1000, 1) - 1).canStop).toBe(false);
    expect(scene.view(recording, line(1000, 1)).canStop).toBe(true);
    const early = scene.step(recording, { type: "stop", at: line(1000, 1) - 1 });
    expect(scene.view(early, line(1000, 1)).phase).toBe("recording");
  });

  test("a stop in the middle gives a file with the lines so far", () => {
    const stopAt = line(1000, 2) + 10;
    const stopped = scene.step(recording, { type: "stop", at: stopAt });
    const saved = scene.view(stopped, stopAt + pace.write);
    expect(saved.file?.markdown).toBe("two lines");
    expect(saved.pill).toBe("saved · <1m");
    expect(saved.lines.length).toBe(2);
  });

  test("a second record does not start a second meeting", () => {
    const twice = scene.step(recording, { type: "record", at: line(1000, 2) });
    expect(scene.view(twice, line(1000, 2)).lines.length).toBe(2);
  });
});

describe("the mic", () => {
  const recording = scene.step(scene.initial(), { type: "record", at: 1000 });
  const stopAt = line(1000, 2);
  const stopped = scene.step(recording, { type: "stop", at: stopAt });

  test("is the meeting's from record to stop, and nobody's after", () => {
    expect(scene.view(scene.initial(), 0).live).toBe(false);
    expect(scene.view(recording, 1000).live).toBe(true);
    expect(scene.view(recording, line(1000, 1)).live).toBe(true);
    expect(scene.view(stopped, stopAt).live).toBe(false);
  });
});

describe("the scene at its end", () => {
  test("is the whole file and the agent's answer, with nothing still moving", () => {
    const view = scene.view(scene.finished(50_000), 50_000);
    expect(view.phase).toBe("idle");
    expect(view.file?.markdown).toBe("three lines");
    expect(view.reply).toBe("One thing.");
    expect(view.pill).toBeNull();
    expect(view.lamp.state).toBe("off");
  });
});

describe("what the badge and the lamp wear", () => {
  const recording = scene.step(scene.initial(), { type: "record", at: 1000 });
  const stopAt = line(1000, 2);
  const stopped = scene.step(recording, { type: "stop", at: stopAt });

  test("part of a rim while it gets ready or writes, the whole rim while it records", () => {
    expect(scene.view(scene.initial(), 0).badge).toBe("none");
    expect(scene.view(recording, 1000).badge).toBe("part");
    expect(scene.view(recording, 1000 + pace.ready).badge).toBe("rim");
    expect(scene.view(stopped, stopAt).badge).toBe("part");
    expect(scene.view(stopped, stopAt + pace.write).badge).toBe("none");
  });

  test("the lamp is an ember, then the meeting's steady light, and out at stop", () => {
    expect(scene.view(recording, 1000).lamp.state).toBe("ember");
    expect(scene.view(recording, 1000 + pace.ready).lamp.state).toBe("pilot");
    expect(scene.view(stopped, stopAt).lamp.state).toBe("cool");
    expect(scene.view(stopped, stopAt + pace.cool).lamp.state).toBe("off");
  });
});

describe("the call the page ships", async () => {
  const shipped = (await import("../src/demo/meeting.json")).default;

  test("has a file and an answer for every place to stop", () => {
    expect(shipped.stops.length).toBe(shipped.lines.length);
    for (const stop of shipped.stops) {
      expect(stop.markdown).toStartWith("---\napp: zoom\n");
      expect(stop.reply.length).toBeGreaterThan(0);
    }
  });
});
