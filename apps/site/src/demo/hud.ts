// the lamp, the pill and the menu bar badge: the three places the app shows
// its state, and so the three the demos speak through. there is one of each
// and two demos, so each demo says what it wants and this decides what shows,
// the way the app does: a take has the lamp while it lasts, and a meeting's
// light is back when the take is over.

import { createLamp, type LampFrame } from "./lamp";

const canvas = document.querySelector<HTMLCanvasElement>("canvas[data-lamp]");
const pillElement = document.querySelector<HTMLElement>("[data-pill]");
const pillStatus = document.querySelector<HTMLElement>("[data-pill-status]");
const badgeElement = document.querySelector<HTMLElement>("[data-badge]");
const lamp = canvas ? createLamp(canvas) : null;
const motion = window.matchMedia("(prefers-reduced-motion: reduce)");

export const reduceMotion = () => motion.matches;

export type Owner = "dictation" | "meeting";
export type BadgeMark = "none" | "dot" | "part" | "rim";
type Frame = Omit<LampFrame, "reduceMotion">;

const frames = new Map<Owner, Frame>();
const marks = new Map<Owner, BadgeMark>();
const pills = new Map<Owner, string | null>();
let said: { text: string; timer: number } | null = null;

function showPill() {
  if (!pillElement) return;
  // something said in passing outranks a standing pill, and the newest
  // standing pill outranks the older
  const text = said?.text ?? pills.get("dictation") ?? pills.get("meeting") ?? null;
  if ((pillElement.textContent ?? "") === (text ?? "") && pillElement.hidden === (text === null)) {
    return;
  }
  pillElement.textContent = text ?? "";
  pillElement.hidden = text === null;
  // the pill comes and goes, and a region that was hidden a moment ago is
  // not reliably read out. so the words are also put in one that never
  // leaves the page, which is the one a screen reader hears.
  if (pillStatus) pillStatus.textContent = text ?? "";
}

export const hud = {
  lamp(owner: Owner, frame: Frame) {
    frames.set(owner, frame);
    const take = frames.get("dictation");
    const showing = take && take.phase !== "off" ? take : frames.get("meeting");
    lamp?.draw({
      ...(showing ?? { phase: "off", elapsed: 0, now: frame.now, loudness: 0 }),
      reduceMotion: motion.matches,
    });
  },

  /** a pill that stands for as long as its demo says so. every pill is said
      out loud too, as the app announces its own. */
  pill(owner: Owner, text: string | null) {
    pills.set(owner, text);
    showPill();
  },

  /** a pill said once, in passing: a refusal. */
  say(text: string, ms: number) {
    if (said) window.clearTimeout(said.timer);
    said = {
      text,
      timer: window.setTimeout(() => {
        said = null;
        showPill();
      }, ms),
    };
    showPill();
  },

  badge(owner: Owner, mark: BadgeMark) {
    marks.set(owner, mark);
    const meeting = marks.get("meeting") ?? "none";
    // a meeting's rim is the mic's standing state; a take's dot is a moment
    const take = marks.get("dictation") ?? "none";
    badgeElement?.setAttribute("data-mark", meeting !== "none" ? meeting : take);
  },
};

/** the mic is one. a take and a meeting cannot both have it, and each demo
    refuses the way the app does while the other holds it. */
export const mic = { dictating: false, meeting: false };
