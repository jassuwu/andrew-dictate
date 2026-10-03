// the thin layer between the demo's state machine and the page. it turns
// hands into events and a view into dom, and decides nothing.

import pairs from "./pairs.json";
import { dictationDemo, type State, type View } from "./dictation";

const demo = dictationDemo(pairs.prompts);

const root = document.querySelector<HTMLElement>("[data-demo]");
if (root) mount(root);

function mount(root: HTMLElement) {
  const key = root.querySelector<HTMLButtonElement>("[data-key]")!;
  const thread = root.querySelector<HTMLElement>("[data-thread]")!;
  const box = root.querySelector<HTMLElement>("[data-box]")!;
  const boxText = root.querySelector<HTMLElement>("[data-box-text]")!;
  const hint = root.querySelector<HTMLElement>("[data-hint]")!;
  const said = root.querySelector<HTMLElement>("[data-said]")!;
  const lamp = document.querySelector<HTMLElement>("[data-lamp]");
  const pill = document.querySelector<HTMLElement>("[data-pill]");

  let state: State = demo.initial();
  let frame = 0;
  let drawn = "";

  const send = (type: "press" | "release" | "esc") => {
    state = demo.step(state, { type, at: performance.now() });
    key.toggleAttribute("data-down", state.take !== null && state.take.end === null);
    if (!frame) frame = requestAnimationFrame(tick);
  };

  function tick(now: number) {
    const view = demo.view(state, now);
    render(view);
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
    if (view.sent !== null) thread.append(line("sent", view.sent));
    if (view.reply !== null) thread.append(line("reply", view.reply));

    const talking = view.phase === "holding" || view.phase === "waiting";
    hint.hidden = talking;
    said.hidden = !talking;
    said.textContent = view.said.join(" ");

    lamp?.setAttribute("data-state", view.lamp.state);
    lamp?.toggleAttribute("data-speaking", view.speaking);

    if (pill) {
      pill.hidden = view.pill === null;
      pill.textContent = view.pill ?? "";
    }
  }

  function line(kind: "sent" | "reply", text: string) {
    const p = document.createElement("p");
    p.className = `agent-line agent-line-${kind}`;
    p.textContent = text;
    return p;
  }

  // the key on the page: a mouse, a finger, or the keyboard on the button
  key.addEventListener("pointerdown", (event) => {
    key.setPointerCapture(event.pointerId);
    send("press");
  });
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

  render(demo.view(state, performance.now()));
}
