// the meeting scene's behaviour, with no page in it, in the same shape as
// the dictation demo: a state, an event and a time go in, a state or a view
// comes out.

export type Line = { speaker: string; at: number; text: string };

/** one place a visitor can press stop: how long the meeting ran, what the
    lamp says, the file the app writes, and what an agent makes of it. the
    file is pinned to the real writer by DemoMeetingTests in apps/mac. */
export type Stop = { duration: number; saved: string; reply: string; markdown: string };

export type Call = { file: string; ask: string; lines: Line[]; stops: Stop[] };

/** the scene plays faster than life, and says so on the page. */
export const pace = {
  /** record to recording: the model loads and the tap hears the start sound. */
  ready: 700,
  /** one line of the call. */
  line: 1300,
  /** stop to the file. the real one is on disk in seconds. */
  write: 900,
  /** the lamp's cool-out, as the app times it. */
  cool: 300,
  /** the file to the agent being asked, and the ask to its answer. */
  ask: 900,
  reply: 700,
  /** how long a pill stays. */
  pill: 2200,
} as const;

type Run = { recordAt: number; stopAt: number | null };

export type State = { run: Run | null };

export type Event = { type: "record" | "stop"; at: number };

export type LiveLine = { speaker: string; stamp: string; text: string };

export type View = {
  phase: "idle" | "ready" | "recording" | "writing" | "saved";
  /** the menu's first line, in the app's words. */
  status: string;
  /** the live transcript: finished stretches, `you` and `them`. */
  lines: LiveLine[];
  canStop: boolean;
  pill: string | null;
  file: { name: string; markdown: string } | null;
  ask: string | null;
  reply: string | null;
  badge: "none" | "part" | "rim";
  lamp: { state: "off" | "ember" | "pilot" | "cooling"; since: number };
};

const idle: View = {
  phase: "idle",
  status: "",
  lines: [],
  canStop: false,
  pill: null,
  file: null,
  ask: null,
  reply: null,
  badge: "none",
  lamp: { state: "off", since: 0 },
};

/** `00:01:10`, as the transcript stamps a turn. */
const stamp = (seconds: number) =>
  [Math.floor(seconds / 3600), Math.floor((seconds % 3600) / 60), seconds % 60]
    .map((part) => String(part).padStart(2, "0"))
    .join(":");

/** `01:10`, as the menu counts a recording. */
const clock = (seconds: number) => stamp(seconds).slice(3);

export function meetingScene(call: Call) {
  const startAt = (run: Run) => run.recordAt + pace.ready;

  /** how many lines are on the panel by `at`. */
  const linesBy = (run: Run, at: number) => {
    const count = Math.floor((at - startAt(run)) / pace.line);
    return Math.min(Math.max(count, 0), call.lines.length);
  };

  // the live view cannot tell the far voices apart yet. the file can.
  const live = (count: number): LiveLine[] =>
    call.lines.slice(0, count).map((line) => ({
      speaker: line.speaker.startsWith("them") ? "them" : line.speaker,
      stamp: stamp(line.at),
      text: line.text,
    }));

  function initial(): State {
    return { run: null };
  }

  function step(state: State, event: Event): State {
    const run = state.run;
    switch (event.type) {
      case "record":
        // a meeting still recording, or still being written out, is the one
        // meeting there is
        if (run && (run.stopAt === null || event.at < run.stopAt + pace.write)) return state;
        return { run: { recordAt: event.at, stopAt: null } };
      case "stop":
        if (!run || run.stopAt !== null || linesBy(run, event.at) === 0) return state;
        return { run: { ...run, stopAt: event.at } };
    }
  }

  function view(state: State, now: number): View {
    const run = state.run;
    if (!run) return idle;

    if (run.stopAt === null) {
      if (now < startAt(run)) {
        return {
          ...idle,
          phase: "ready",
          status: "getting ready…",
          badge: "part",
          lamp: { state: "ember", since: run.recordAt },
        };
      }
      const count = linesBy(run, now);
      const last = count > 0 ? call.lines[count - 1].at : 0;
      return {
        ...idle,
        phase: "recording",
        status: `recording · ${clock(last)}`,
        lines: live(count),
        canStop: count > 0,
        pill: now < startAt(run) + pace.pill ? "recording a meeting" : null,
        badge: "rim",
        lamp: { state: "pilot", since: startAt(run) },
      };
    }

    const count = linesBy(run, run.stopAt);
    const stop = call.stops[count - 1];
    const lamp: View["lamp"] =
      now < run.stopAt + pace.cool
        ? { state: "cooling", since: run.stopAt }
        : { state: "off", since: run.stopAt + pace.cool };
    const savedAt = run.stopAt + pace.write;
    if (now < savedAt) {
      return {
        ...idle,
        phase: "writing",
        status: "writing it out…",
        lines: live(count),
        pill: "writing it out…",
        badge: "part",
        lamp,
      };
    }

    return {
      ...idle,
      phase: "saved",
      status: stop.saved,
      lines: live(count),
      pill: now < savedAt + pace.pill ? stop.saved : null,
      file: { name: call.file, markdown: stop.markdown },
      ask: now >= savedAt + pace.ask ? call.ask : null,
      reply: now >= savedAt + pace.ask + pace.reply ? stop.reply : null,
      lamp,
    };
  }

  return { initial, step, view };
}
