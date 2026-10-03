// the lamp, the pill and the menu bar badge: the three places the app shows
// its state, and so the three the demos speak through.

import { createLamp, type LampFrame } from "./lamp";

const canvas = document.querySelector<HTMLCanvasElement>("canvas[data-lamp]");
const pillElement = document.querySelector<HTMLElement>("[data-pill]");
const badgeElement = document.querySelector<HTMLElement>("[data-badge]");
const lamp = canvas ? createLamp(canvas) : null;
const motion = window.matchMedia("(prefers-reduced-motion: reduce)");

export const reduceMotion = () => motion.matches;

export type BadgeMark = "none" | "dot" | "part" | "rim";

export const hud = {
  lamp(frame: Omit<LampFrame, "reduceMotion">) {
    lamp?.draw({ ...frame, reduceMotion: motion.matches });
  },

  /** every pill is said out loud too: it is a `status` region. */
  pill(text: string | null) {
    if (!pillElement) return;
    if ((pillElement.textContent ?? "") === (text ?? "") && pillElement.hidden === (text === null)) {
      return;
    }
    pillElement.textContent = text ?? "";
    pillElement.hidden = text === null;
  },

  badge(mark: BadgeMark) {
    badgeElement?.setAttribute("data-mark", mark);
  },
};
