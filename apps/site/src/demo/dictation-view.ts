// the thin layer between the dictation demo's state machine and the page. it
// turns hands into events and a view into dom, and decides nothing.

import pairs from "./pairs.json";
import { agentLine } from "./agent";
import { dictationDemo, timing, type State, type View } from "./dictation";
import { hud, mic, reduceMotion } from "./hud";
import { scriptedLoudness, type LampPhase } from "./lamp";
import { spaceOwner, spaceRelease, type Focus } from "./space";

const demo = dictationDemo(pairs.prompts);

export function mountDictation(root: HTMLElement) {
  const key = root.querySelector<HTMLButtonElement>("[data-key]")!;
  const thread = root.querySelector<HTMLElement>("[data-thread]")!;
  const box = root.querySelector<HTMLElement>("[data-box]")!;
  const boxText = root.querySelector<HTMLElement>("[data-box-text]")!;
  const hint = root.querySelector<HTMLElement>("[data-hint]")!;
  const said = root.querySelector<HTMLElement>("[data-said]")!;

  const soundSwitch = root.querySelector<HTMLButtonElement>("[data-sound]")!;
  root.querySelector<HTMLElement>("[data-controls]")!.hidden = false;

  let state: State = demo.initial();
  let frame = 0;
  let drawn = "";

  // the app's own start sound. it plays when the lamp lights, and only ever
  // after the visitor's own press. the switch is remembered for the visit.
  const chime = new Audio("/start.wav");
  chime.preload = "auto";
  let sound = sessionStorage.getItem("sound") !== "off";
  let ticked = 0;
  const showSound = () => {
    soundSwitch.textContent = sound ? "sound on" : "sound off";
    soundSwitch.setAttribute("aria-pressed", String(sound));
  };
  showSound();
  soundSwitch.addEventListener("click", () => {
    sound = !sound;
    sessionStorage.setItem("sound", sound ? "on" : "off");
    showSound();
  });

  const send = (type: "press" | "release" | "esc") => {
    if (type === "press" && mic.meeting) {
      // the mic is one. the app refuses a take while a meeting records, and
      // this is the pill it refuses with.
      hud.say("recording a meeting — stop it to dictate", timing.pill);
      return;
    }
    const at = performance.now();
    if (!frame) ticked = at;
    state = demo.step(state, { type, at });
    mic.dictating = state.take !== null && state.take.end === null;
    key.toggleAttribute("data-down", mic.dictating);
    if (!frame) frame = requestAnimationFrame(tick);
  };

  function tick(now: number) {
    const view = demo.view(state, now);
    render(view);
    light(view, now);
    if (demo.chimeDue(state, ticked, now, { sound })) {
      chime.currentTime = 0;
      void chime.play().catch(() => {});
    }
    ticked = now;
    // nothing changes by itself once a take has played out, so stop asking
    frame = settled(view) ? 0 : requestAnimationFrame(tick);
  }

  const settled = (view: View) =>
    (view.phase === "idle" && view.pill === null) ||
    (view.phase === "landed" && view.reply !== null && view.lamp.state === "off");

  function render(view: View) {
    const next = JSON.stringify([
      view.phase,
      view.lamp.state,
      view.said.length,
      view.box,
      view.sent,
      view.reply,
      view.pill,
    ]);
    if (next === drawn) return;
    drawn = next;

    boxText.textContent = view.box;
    box.toggleAttribute("data-filled", view.box !== "");

    thread.replaceChildren();
    if (view.sent !== null) thread.append(agentLine("sent", view.sent));
    if (view.reply !== null) thread.append(agentLine("reply", view.reply));

    const talking = view.phase === "holding" || view.phase === "waiting";
    hint.hidden = talking;
    said.hidden = !talking;
    said.textContent = view.said.join(" ");

    hud.pill("dictation", view.pill);
    // a gold dot on the badge means the mic is live for a take
    hud.badge("dictation", view.lamp.state === "lit" ? "dot" : "none");
  }

  const phases: Record<View["lamp"]["state"], LampPhase> = {
    off: "off",
    ember: "ember",
    lit: "burn",
    cooling: "cool",
  };

  /** the lamp is drawn every frame it is on: it is the one thing that moves. */
  function light(view: View, now: number) {
    const elapsed = now - view.lamp.since;
    const words = state.take ? pairs.prompts[state.take.prompt].cuts.length : 0;
    hud.lamp("dictation", {
      phase: phases[view.lamp.state],
      elapsed,
      now,
      loudness:
        view.lamp.state === "lit"
          ? scriptedLoudness(elapsed, timing.word, words)
          : view.lamp.state === "cooling"
            ? 0.5
            : 0,
    });
  }

  // the key on the page: a mouse, a finger, or the keyboard on the button
  key.addEventListener("pointerdown", (event) => {
    key.setPointerCapture(event.pointerId);
    send("press");
  });
  // a long press on a phone is a hold, not a request for a menu
  key.addEventListener("contextmenu", (event) => event.preventDefault());
  key.addEventListener("pointerup", () => send("release"));
  key.addEventListener("pointercancel", () => send("release"));
  key.addEventListener("keydown", (event) => {
    if (event.key !== " " && event.key !== "Enter") return;
    event.preventDefault();
    if (!event.repeat) send("press");
  });
  key.addEventListener("keyup", (event) => {
    if (event.key !== " " && event.key !== "Enter") return;
    event.preventDefault();
    send("release");
  });
  // a hand that leaves mid-take ends it, the way the app keeps what it heard
  key.addEventListener("blur", () => send("release"));
  window.addEventListener("blur", () => send("release"));

  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape") send("esc");
  });

  // the space bar, standing in for fn. it is the demo's only while the key
  // is on screen and nothing else has a claim on it (space.ts).
  let onScreen = false;
  new IntersectionObserver(([entry]) => (onScreen = entry.isIntersecting), {
    threshold: 0.6,
  }).observe(key);

  const focus = (): Focus => {
    const active = document.activeElement;
    if (active === key) return "key";
    return active?.matches("a[href], button, input, textarea, select, summary, [contenteditable]")
      ? "control"
      : "none";
  };

  let spaceDownAt: number | null = null;
  let beforeSpace = state;
  document.addEventListener("keydown", (event) => {
    if (event.key !== " " || event.metaKey || event.ctrlKey || event.altKey) return;
    if (spaceDownAt !== null) {
      // key repeat while it is held: still ours, and not a new take
      event.preventDefault();
      return;
    }
    if (spaceOwner({ demoOnScreen: onScreen, focus: focus() }) !== "demo") return;
    event.preventDefault();
    spaceDownAt = performance.now();
    beforeSpace = state;
    send("press");
  });
  document.addEventListener("keyup", (event) => {
    if (event.key !== " " || spaceDownAt === null) return;
    const held = performance.now() - spaceDownAt;
    spaceDownAt = null;
    if (spaceRelease(held) === "release") {
      send("release");
      return;
    }
    // a tap was someone scrolling. put back what was there, as if the key
    // had never gone down, and scroll for them.
    state = beforeSpace;
    mic.dictating = false;
    key.removeAttribute("data-down");
    if (!frame) frame = requestAnimationFrame(tick);
    window.scrollBy({
      top: window.innerHeight * (event.shiftKey ? -0.9 : 0.9),
      behavior: reduceMotion() ? "auto" : "smooth",
    });
  });
  window.addEventListener("blur", () => (spaceDownAt = null));

  render(demo.view(state, performance.now()));
}
