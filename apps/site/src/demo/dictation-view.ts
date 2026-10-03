// the thin layer between the dictation demo's state machine and the page. it
// turns hands into events and a view into dom, and decides nothing.

import pairs from "./pairs.json";
import { agentLine } from "./agent";
import { dictationDemo, timing, type State, type View } from "./dictation";
import { differ, frameLoop } from "./frames";
import { hud, mic, reduceMotion } from "./hud";
import { scriptedLoudness } from "./lamp";
import { demoOwnsSpace, spaceRelease, tapMs } from "./space";

const demo = dictationDemo(pairs.prompts);

/** the sound switch, remembered for the visit where the browser allows it. */
const soundChoice = {
  read(): boolean {
    try {
      return sessionStorage.getItem("sound") !== "off";
    } catch {
      return true;
    }
  },
  write(on: boolean) {
    try {
      sessionStorage.setItem("sound", on ? "on" : "off");
    } catch {
      // storage is blocked: the switch still works, it is just not kept
    }
  },
};

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

  // the app's own start sound. it plays when the lamp lights, and only ever
  // after the visitor's own press.
  const chime = new Audio("/start.wav");
  chime.preload = "auto";
  let sound = soundChoice.read();
  let chimedUpTo = 0;
  const showSound = () => {
    soundSwitch.textContent = sound ? "sound on" : "sound off";
    soundSwitch.setAttribute("aria-pressed", String(sound));
  };
  showSound();
  soundSwitch.addEventListener("click", () => {
    sound = !sound;
    soundChoice.write(sound);
    showSound();
  });

  const changed = differ();

  const loop = frameLoop<View>({
    read: (now) => demo.view(state, now),
    draw(view, now) {
      render(view);
      light(view, now);
      if (demo.chimeDue(state, chimedUpTo, now, { sound })) {
        chime.currentTime = 0;
        void chime.play().catch(() => {});
      }
      chimedUpTo = now;
    },
    // nothing changes by itself once a take has played out, so stop asking
    settled: (view) =>
      view.pill === null &&
      (view.phase === "idle" ||
        (view.phase === "landed" && view.reply !== null && view.lamp.state === "off")),
  });

  function send(type: "press" | "release" | "esc", at = performance.now()) {
    if (type === "press" && mic.meeting) {
      // the mic is one. the app refuses a take while a meeting records, and
      // this is the pill it refuses with.
      hud.say("recording a meeting — stop it to dictate", timing.pill);
      return;
    }
    if (loop.asleep) chimedUpTo = at;
    state = demo.step(state, { type, at });
    mic.dictating = state.take !== null && state.take.end === null;
    key.toggleAttribute("data-down", mic.dictating);
    loop.wake();
  }

  function render(view: View) {
    if (
      !changed([
        view.phase,
        view.lamp.state,
        view.said.length,
        view.box,
        view.sent,
        view.reply,
        view.pill,
      ])
    ) {
      return;
    }

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
    hud.badge("dictation", view.lamp.state === "burn" ? "dot" : "none");
  }

  /** the lamp is drawn every frame it is on: it is the one thing that moves. */
  function light(view: View, now: number) {
    const elapsed = now - view.lamp.since;
    const words = state.take ? pairs.prompts[state.take.prompt].cuts.length : 0;
    hud.lamp("dictation", {
      phase: view.lamp.state,
      elapsed,
      now,
      loudness:
        view.lamp.state === "burn"
          ? scriptedLoudness(elapsed, timing.word, words)
          : view.lamp.state === "cool"
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
  // a screen reader presses a button, it does not hold one. a click that no
  // pointer and no key made is that press, and the demo says a whole prompt
  // for it: the take is held for as long as the words take, then let go.
  key.addEventListener("click", (event) => {
    if (event.detail !== 0 || mic.dictating) return;
    send("press");
    const words = state.take ? pairs.prompts[state.take.prompt].cuts.length : 0;
    window.setTimeout(() => send("release"), timing.firstAudio + words * timing.word + 150);
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

  const controlFocused = () =>
    document.activeElement?.matches(
      "a[href], button, input, textarea, select, summary, [contenteditable]",
    ) ?? false;

  // a press of space is not a take until it has outlasted a tap. the take is
  // then dated from when the key really went down, so the words keep time.
  let space: { downAt: number; pending: number; began: boolean } | null = null;
  document.addEventListener("keydown", (event) => {
    if (event.key !== " " || event.metaKey || event.ctrlKey || event.altKey) return;
    if (space) {
      // key repeat while it is held: still ours, and not a new take
      event.preventDefault();
      return;
    }
    if (!demoOwnsSpace({ demoOnScreen: onScreen, controlFocused: controlFocused() })) return;
    event.preventDefault();
    const downAt = performance.now();
    const held = {
      downAt,
      began: false,
      pending: window.setTimeout(() => {
        held.began = true;
        send("press", downAt);
      }, tapMs),
    };
    space = held;
  });
  document.addEventListener("keyup", (event) => {
    if (event.key !== " " || !space) return;
    const { downAt, pending, began } = space;
    space = null;
    window.clearTimeout(pending);
    if (spaceRelease(performance.now() - downAt) === "release") {
      // a timer can run late. if the take has not begun, begin it now
      if (!began) send("press", downAt);
      send("release");
      return;
    }
    // a tap was someone scrolling. no take began, so there is nothing to
    // undo: scroll for them.
    window.scrollBy({
      top: window.innerHeight * (event.shiftKey ? -0.9 : 0.9),
      behavior: reduceMotion() ? "auto" : "smooth",
    });
  });
  window.addEventListener("blur", () => {
    if (space) window.clearTimeout(space.pending);
    space = null;
  });

  render(demo.view(state, performance.now()));
}
