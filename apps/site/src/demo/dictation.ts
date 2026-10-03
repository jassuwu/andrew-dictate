// the dictation demo's behaviour, with no page in it: a state, an event and a
// time go in, a state or a view comes out. the page draws the view and does
// nothing else, so everything a visitor can make happen is tested here.

/** one place a visitor can let go: what the speech model wrote for the words
    said so far, and what the cleaner makes of it. pinned to the real cleaner
    by DemoPairsTests in apps/mac. */
export type Cut = { heard: string; pasted: string };

/** a thing to say to an agent, cut after each word, and how the agent starts
    its answer. */
export type Prompt = { reply: string; cuts: Cut[] };

export const timing = {
  /** key-down to the mic's first audio. the lamp lights and the chime plays
      here, not at the press (glossary: lamp). */
  firstAudio: 50,
  /** one spoken word, at a quick talking pace. */
  word: 300,
  /** key-up to the text landing. this is the app's own wait: the median
      key-up to paste of real short dictations on jass's mac since 0.10.0
      (docs: wayfinder 019, further notes). the one place it is written, and
      the page never prints it. */
  wait: 210,
  /** the lamp's cool-out, as the app times it. */
  cool: 300,
  /** how long the landed text sits in the prompt box before it is sent. */
  send: 1100,
  /** the send to the agent's first words. */
  reply: 500,
  /** how long a pill stays. */
  pill: 2200,
} as const;

type Take = {
  prompt: number;
  pressedAt: number;
  end: null | { at: number; by: "release" | "esc" };
};

export type State = {
  /** the prompt the next press will say. */
  next: number;
  take: Take | null;
};

export type Event = { type: "press" | "release" | "esc"; at: number };

export type Lamp = "off" | "ember" | "lit" | "cooling";

export type View = {
  phase: "idle" | "holding" | "waiting" | "landed";
  lamp: { state: Lamp; since: number };
  /** the words said so far, for the speech line. */
  said: string[];
  /** words are still coming, so there is a voice in the lamp. */
  speaking: boolean;
  /** the agent's prompt box. empty for the whole hold: the app pastes once. */
  box: string;
  /** the prompt once it is sent, and the start of the agent's answer. */
  sent: string | null;
  reply: string | null;
  pill: string | null;
};

const idle: View = {
  phase: "idle",
  lamp: { state: "off", since: 0 },
  said: [],
  speaking: false,
  box: "",
  sent: null,
  reply: null,
  pill: null,
};

/** the words of a prompt as a person says them: no capitals, no stops. */
export function spoken(prompt: Prompt): string[] {
  const whole = prompt.cuts[prompt.cuts.length - 1]?.heard ?? "";
  return whole
    .toLowerCase()
    .split(/\s+/)
    .map((word) => word.replace(/[.,?!]/g, ""))
    .filter(Boolean);
}

export function dictationDemo(prompts: Prompt[]) {
  const litAt = (take: Take) => take.pressedAt + timing.firstAudio;

  /** how many words have been said by `at`. a word counts once it is out. */
  const wordsBy = (take: Take, at: number) => {
    const total = prompts[take.prompt].cuts.length;
    const count = Math.floor((at - litAt(take)) / timing.word);
    return Math.min(Math.max(count, 0), total);
  };

  /** a take is over once nothing more will come of it. */
  const settled = (take: Take, now: number) => {
    if (!take.end) return false;
    if (take.end.by === "esc") return true;
    return wordsBy(take, take.end.at) === 0
      ? true
      : now >= take.end.at + timing.wait;
  };

  function initial(): State {
    return { next: 0, take: null };
  }

  function step(state: State, event: Event): State {
    const take = state.take;
    switch (event.type) {
      case "press":
        // a press during a take is key repeat, or a second finger. a press
        // before the last text has landed waits for it.
        if (take && !settled(take, event.at)) return state;
        return {
          ...state,
          take: { prompt: state.next, pressedAt: event.at, end: null },
        };
      case "release":
      case "esc": {
        if (!take || take.end) return state;
        const by = event.type;
        const landed = by === "release" && wordsBy(take, event.at) > 0;
        return {
          // only a take that landed something uses its prompt up
          next: landed ? (take.prompt + 1) % prompts.length : state.next,
          take: { ...take, end: { at: event.at, by } },
        };
      }
    }
  }

  function view(state: State, now: number): View {
    const take = state.take;
    if (!take) return idle;
    const prompt = prompts[take.prompt];
    const words = spoken(prompt);

    if (!take.end) {
      const count = wordsBy(take, now);
      const lit = now >= litAt(take);
      return {
        ...idle,
        phase: "holding",
        lamp: lit
          ? { state: "lit", since: litAt(take) }
          : { state: "ember", since: take.pressedAt },
        said: words.slice(0, count),
        speaking: lit && count < words.length,
      };
    }

    const { at, by } = take.end;
    if (by === "esc") return idle;

    const count = wordsBy(take, at);
    if (count === 0) {
      // nothing was said. the afterglow is the success signal, so there is
      // none: the lamp goes out at once and the pill says why.
      return { ...idle, pill: now < at + timing.pill ? "heard nothing" : null };
    }

    const lamp: View["lamp"] =
      now < at + timing.cool
        ? { state: "cooling", since: at }
        : { state: "off", since: at + timing.cool };
    const landAt = at + timing.wait;
    if (now < landAt) {
      return { ...idle, phase: "waiting", lamp, said: words.slice(0, count) };
    }

    const pasted = prompt.cuts[count - 1].pasted;
    const sendAt = landAt + timing.send;
    const sent = now >= sendAt;
    return {
      ...idle,
      phase: "landed",
      lamp,
      box: sent ? "" : pasted,
      sent: sent ? pasted : null,
      reply: now >= sendAt + timing.reply ? prompt.reply : null,
    };
  }

  /** whether the start chime falls due in (from, to]. it plays when the
      lamp lights, once a take, and never for a key that came up first or
      with the sound switched off. */
  function chimeDue(
    state: State,
    from: number,
    to: number,
    { sound = true }: { sound?: boolean } = {},
  ): boolean {
    const take = state.take;
    if (!take || !sound) return false;
    const at = litAt(take);
    if (take.end && take.end.at < at) return false;
    return from < at && at <= to;
  }

  return { initial, step, view, chimeDue };
}
