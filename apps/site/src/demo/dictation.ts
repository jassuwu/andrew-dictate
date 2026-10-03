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

import { coolMs, pillMs } from "./timings";

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
  cool: coolMs,
  /** how long the landed text sits in the prompt box before it is sent. */
  send: 1100,
  /** the send to the agent's first words. */
  reply: 500,
  pill: pillMs,
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
  /** when a press came while the last take was still being written out. */
  refusedAt: number | null;
};

export type Event = { type: "press" | "release" | "esc"; at: number };

/** the lamp's phases, by the names the app gives them (GoldRippleLine.Phase):
    an ember from the press, the burn once the mic is heard, the cool-out. */
export type Lamp = "off" | "ember" | "burn" | "cool";

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
    return { next: 0, take: null, refusedAt: null };
  }

  function step(state: State, event: Event): State {
    const take = state.take;
    switch (event.type) {
      case "press":
        if (take && !settled(take, event.at)) {
          // a press during a hold is key repeat, or a second finger. a press
          // while the last take is still being written out is refused, and
          // the app says so: no press ends in silence.
          return take.end ? { ...state, refusedAt: event.at } : state;
        }
        return {
          next: state.next,
          take: { prompt: state.next, pressedAt: event.at, end: null },
          refusedAt: null,
        };
      case "release":
      case "esc": {
        if (!take || take.end) return state;
        const by = event.type;
        const landed = by === "release" && wordsBy(take, event.at) > 0;
        return {
          ...state,
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
          ? { state: "burn", since: litAt(take) }
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
        ? { state: "cool", since: at }
        : { state: "off", since: at + timing.cool };
    const refused = state.refusedAt !== null && now < state.refusedAt + timing.pill;
    const pill = refused ? "still finishing the last one" : null;
    const landAt = at + timing.wait;
    if (now < landAt) {
      return { ...idle, phase: "waiting", lamp, said: words.slice(0, count), pill };
    }

    const pasted = prompt.cuts[count - 1].pasted;
    const sendAt = landAt + timing.send;
    const sent = now >= sendAt;
    return {
      ...idle,
      phase: "landed",
      lamp,
      pill,
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
