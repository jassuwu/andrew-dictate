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

describe("with more than one prompt", () => {
  const two: Prompt[] = [
    prompts[0],
    {
      reply: "Looking.",
      cuts: [
        { heard: "Find", pasted: "Find." },
        { heard: "Find it.", pasted: "Find it." },
      ],
    },
  ];
  const demo = dictationDemo(two);

  /** press at `at`, say `words` words, let go. returns the state and when. */
  const take = (state: ReturnType<typeof demo.initial>, at: number, words: number) => {
    const letGo = said(at, words);
    const pressed = demo.step(state, { type: "press", at });
    return { state: demo.step(pressed, { type: "release", at: letGo }), letGo };
  };

  test("each press takes the next prompt, and the list wraps", () => {
    const first = take(demo.initial(), 1000, 3);
    expect(demo.view(first.state, first.letGo + timing.wait).box).toBe("Run the tests.");

    const second = take(first.state, 10_000, 2);
    expect(demo.view(second.state, second.letGo + timing.wait).box).toBe("Find it.");

    const third = take(second.state, 20_000, 3);
    expect(demo.view(third.state, third.letGo + timing.wait).box).toBe("Run the tests.");
  });
});

describe("letting go early", () => {
  test("lands the words said so far", () => {
    const pressed = demo.step(demo.initial(), { type: "press", at: 1000 });
    const letGo = said(1000, 2) + 100; // "run the", and part of a third word
    const released = demo.step(pressed, { type: "release", at: letGo });
    expect(demo.view(released, letGo + timing.wait).box).toBe("Run the.");
  });

  test("before a word is out shows `heard nothing` and lands nothing", () => {
    const pressed = demo.step(demo.initial(), { type: "press", at: 1000 });
    const letGo = said(1000, 1) - 1;
    const released = demo.step(pressed, { type: "release", at: letGo });

    const now = demo.view(released, letGo);
    expect(now.pill).toBe("heard nothing");
    expect(now.lamp.state).toBe("off"); // no afterglow: it did not work
    expect(demo.view(released, letGo + timing.wait).box).toBe("");
    expect(demo.view(released, letGo + timing.pill).pill).toBeNull();
  });

  test("holding past the end lands the whole text", () => {
    const pressed = demo.step(demo.initial(), { type: "press", at: 1000 });
    const letGo = said(1000, 3) + 60_000;
    const released = demo.step(pressed, { type: "release", at: letGo });
    expect(demo.view(released, letGo + timing.wait).box).toBe("Run the tests.");
  });
});

describe("esc during a hold", () => {
  const pressed = demo.step(demo.initial(), { type: "press", at: 1000 });
  const at = said(1000, 2);
  const cancelled = demo.step(pressed, { type: "esc", at });

  test("lands nothing and says nothing", () => {
    const later = demo.view(cancelled, at + timing.wait + timing.send);
    expect(later.box).toBe("");
    expect(later.sent).toBeNull();
    expect(later.pill).toBeNull();
    expect(demo.view(cancelled, at).lamp.state).toBe("off");
  });

  test("a release that follows it is not a second ending", () => {
    const released = demo.step(cancelled, { type: "release", at: at + 50 });
    expect(demo.view(released, at + 50 + timing.wait).box).toBe("");
  });
});

describe("a take that landed nothing", () => {
  const two: Prompt[] = [prompts[0], { reply: "x", cuts: [{ heard: "Go.", pasted: "Go." }] }];
  const demo = dictationDemo(two);

  test("leaves its prompt for the next press, after `heard nothing`", () => {
    let state = demo.step(demo.initial(), { type: "press", at: 1000 });
    state = demo.step(state, { type: "release", at: 1010 });
    state = demo.step(state, { type: "press", at: 5000 });
    state = demo.step(state, { type: "release", at: said(5000, 3) });
    expect(demo.view(state, said(5000, 3) + timing.wait).box).toBe("Run the tests.");
  });

  test("leaves its prompt for the next press, after esc", () => {
    let state = demo.step(demo.initial(), { type: "press", at: 1000 });
    state = demo.step(state, { type: "esc", at: said(1000, 2) });
    state = demo.step(state, { type: "press", at: 5000 });
    state = demo.step(state, { type: "release", at: said(5000, 3) });
    expect(demo.view(state, said(5000, 3) + timing.wait).box).toBe("Run the tests.");
  });
});

describe("the start chime", () => {
  const pressed = demo.step(demo.initial(), { type: "press", at: 1000 });
  const lit = 1000 + timing.firstAudio;

  test("falls due once, when the lamp lights", () => {
    expect(demo.chimeDue(pressed, 1000, lit - 1)).toBe(false);
    expect(demo.chimeDue(pressed, lit - 1, lit)).toBe(true);
    expect(demo.chimeDue(pressed, lit, lit + 16)).toBe(false);
  });

  test("does not play for a key that came up before the mic was heard", () => {
    const brushed = demo.step(pressed, { type: "release", at: lit - 10 });
    expect(demo.chimeDue(brushed, 1000, lit + 100)).toBe(false);
  });

  test("does not play when the text lands: success is silent", () => {
    const letGo = said(1000, 3);
    const released = demo.step(pressed, { type: "release", at: letGo });
    expect(demo.chimeDue(released, letGo, letGo + timing.wait + 1000)).toBe(false);
  });
});

describe("the prompts the page ships", async () => {
  const pairs = (await import("../src/demo/pairs.json")).default;
  const { spoken } = await import("../src/demo/dictation");

  test("have one cut for each spoken word", () => {
    expect(pairs.prompts.length).toBeGreaterThanOrEqual(4);
    for (const prompt of pairs.prompts) {
      expect(spoken(prompt).length).toBe(prompt.cuts.length);
    }
  });
});
