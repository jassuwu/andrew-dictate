import { describe, expect, test } from "bun:test";
import { dictationDemo, timing, type Prompt } from "../src/demo/dictation";

// the dictation demo as a visitor meets it: a key goes down, words are said,
// the key comes up, and text lands. time is a number handed in, so every
// test says exactly when it is looking.

const prompts: Prompt[] = [
  {
    reply: "Running the suite now.",
    cuts: [
      { heard: "Run", pasted: "Run." },
      { heard: "Run the", pasted: "Run the." },
      { heard: "Run the tests.", pasted: "Run the tests." },
    ],
  },
];

const demo = dictationDemo(prompts);

/** the moment the last of `words` words has been said, for a press at `at`. */
const said = (at: number, words: number) =>
  at + timing.firstAudio + words * timing.word;

describe("a hold and a release", () => {
  const pressed = demo.step(demo.initial(), { type: "press", at: 1000 });
  const letGo = said(1000, 3) + 400;
  const released = demo.step(pressed, { type: "release", at: letGo });

  test("land the whole text after exactly the wait, and not before", () => {
    expect(demo.view(released, letGo + timing.wait - 1).box).toBe("");
    expect(demo.view(released, letGo + timing.wait).box).toBe("Run the tests.");
  });
});

describe("while the key is held", () => {
  const pressed = demo.step(demo.initial(), { type: "press", at: 1000 });

  test("the prompt box stays empty, because the app pastes once", () => {
    for (const now of [1000, 1050, said(1000, 1), said(1000, 3), 9000]) {
      expect(demo.view(pressed, now).box).toBe("");
    }
  });

  test("the lamp is dim at the press and lit once the mic is heard", () => {
    expect(demo.view(pressed, 1000).lamp.state).toBe("ember");
    expect(demo.view(pressed, 1000 + timing.firstAudio - 1).lamp.state).toBe("ember");
    expect(demo.view(pressed, 1000 + timing.firstAudio).lamp.state).toBe("lit");
  });

  test("the words are said one at a time", () => {
    expect(demo.view(pressed, 1000).said).toEqual([]);
    expect(demo.view(pressed, said(1000, 1)).said).toEqual(["run"]);
    expect(demo.view(pressed, said(1000, 2)).said).toEqual(["run", "the"]);
    expect(demo.view(pressed, said(1000, 3) + 5000).said).toEqual(["run", "the", "tests"]);
  });
});

describe("after the text lands", () => {
  const pressed = demo.step(demo.initial(), { type: "press", at: 1000 });
  const letGo = said(1000, 3);
  const released = demo.step(pressed, { type: "release", at: letGo });
  const landed = letGo + timing.wait;

  test("the lamp cools and goes out", () => {
    expect(demo.view(released, letGo).lamp.state).toBe("cooling");
    expect(demo.view(released, letGo + timing.cool).lamp.state).toBe("off");
  });

  test("the prompt is sent and the agent starts its answer", () => {
    expect(demo.view(released, landed).reply).toBeNull();
    const later = demo.view(released, landed + timing.send + timing.reply);
    expect(later.sent).toBe("Run the tests.");
    expect(later.reply).toBe("Running the suite now.");
    expect(later.box).toBe("");
  });

  test("a new press starts a new take with an empty box", () => {
    const again = demo.step(released, { type: "press", at: landed + 5000 });
    const view = demo.view(again, landed + 5000);
    expect(view.phase).toBe("holding");
    expect(view.box).toBe("");
    expect(view.sent).toBeNull();
    expect(view.reply).toBeNull();
  });

  test("a press before the text has landed waits for it", () => {
    const early = demo.step(released, { type: "press", at: landed - 1 });
    expect(demo.view(early, landed).box).toBe("Run the tests.");
  });
});

describe("key repeat", () => {
  test("a second press during a hold does not restart the take", () => {
    const pressed = demo.step(demo.initial(), { type: "press", at: 1000 });
    const repeated = demo.step(pressed, { type: "press", at: said(1000, 2) });
    expect(demo.view(repeated, said(1000, 2)).said).toEqual(["run", "the"]);
  });
});
