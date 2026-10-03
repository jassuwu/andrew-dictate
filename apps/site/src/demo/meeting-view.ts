// the thin layer between the meeting scene's state machine and the page.

import call from "./meeting.json";
import { agentLine } from "./agent";
import { hud, mic } from "./hud";
import type { LampPhase } from "./lamp";
import { meetingScene, pace, type State, type View } from "./meeting";

const scene = meetingScene(call);

export function mountMeeting(root: HTMLElement) {
  const button = root.querySelector<HTMLButtonElement>("[data-record]")!;
  const status = root.querySelector<HTMLElement>("[data-status]")!;
  const title = root.querySelector<HTMLElement>("[data-title]")!;
  const hint = root.querySelector<HTMLElement>("[data-meeting-hint]")!;
  const lines = root.querySelector<HTMLElement>("[data-lines]")!;
  const file = root.querySelector<HTMLElement>("[data-file]")!;
  const thread = root.querySelector<HTMLElement>("[data-meeting-thread]")!;
  root.querySelector<HTMLElement>("[data-scene]")!.hidden = false;

  let state: State = scene.initial();
  let frame = 0;
  let drawn = "";

  const send = (type: "record" | "stop") => {
    if (type === "record" && mic.dictating) {
      // the mic is one, and this is what the app says about it
      hud.say("finish dictating first", pace.pill);
      return;
    }
    state = scene.step(state, { type, at: performance.now() });
    if (!frame) frame = requestAnimationFrame(tick);
  };

  function tick(now: number) {
    const view = scene.view(state, now);
    render(view);
    light(view, now);
    frame = settled(view, now) ? 0 : requestAnimationFrame(tick);
  }

  /** a meeting that is recording with every line in changes nothing until
      the stop, and its light is steady, so it need not be drawn again. */
  const settled = (view: View, now: number) => {
    if (view.pill !== null) return false;
    switch (view.phase) {
      case "idle":
        return true;
      case "recording":
        return view.lines.length === call.lines.length && now - view.lamp.since > 1000;
      case "saved":
        return view.reply !== null && view.lamp.state === "off";
      default:
        return false;
    }
  };

  function render(view: View) {
    mic.meeting = view.phase === "ready" || view.phase === "recording";

    const next = JSON.stringify([
      view.phase,
      view.status,
      view.lines.length,
      view.canStop,
      view.pill,
      view.ask,
      view.reply,
      view.badge,
    ]);
    if (next === drawn) return;
    drawn = next;

    // one item, as in the app's menu: it starts a meeting or stops the one
    // that records
    const live = view.phase === "ready" || view.phase === "recording";
    button.textContent =
      view.phase === "writing" ? "writing it out…" : live ? "stop recording" : "record a meeting";
    button.disabled = view.phase === "writing" || (live && !view.canStop);
    button.toggleAttribute("data-live", live);

    status.textContent = view.status;
    title.textContent = view.file ? view.file.name : "live transcript";
    hint.hidden = view.phase !== "idle";

    lines.hidden = view.file !== null;
    if (lines.childElementCount !== view.lines.length) {
      lines.replaceChildren(
        ...view.lines.map((line) => {
          const item = document.createElement("li");
          const stamp = document.createElement("span");
          stamp.className = "live-stamp";
          stamp.textContent = line.stamp;
          const who = document.createElement("span");
          who.className = line.speaker === "you" ? "live-you" : "live-them";
          who.textContent = `${line.speaker}:`;
          item.append(stamp, " ", who, " ", line.text);
          return item;
        }),
      );
      lines.scrollTop = lines.scrollHeight;
    }

    file.hidden = view.file === null;
    file.textContent = view.file?.markdown ?? "";

    thread.replaceChildren();
    if (view.ask !== null) thread.append(agentLine("sent", view.ask));
    if (view.reply !== null) thread.append(agentLine("reply", view.reply));
    thread.hidden = view.ask === null;

    hud.pill("meeting", view.pill);
    hud.badge("meeting", view.badge);
  }

  const phases: Record<View["lamp"]["state"], LampPhase> = {
    off: "off",
    ember: "ember",
    pilot: "pilot",
    cooling: "cool",
  };

  function light(view: View, now: number) {
    hud.lamp("meeting", {
      phase: phases[view.lamp.state],
      elapsed: now - view.lamp.since,
      now,
      loudness: 0,
    });
  }

  button.addEventListener("click", () => {
    const view = scene.view(state, performance.now());
    send(view.phase === "ready" || view.phase === "recording" ? "stop" : "record");
  });

  render(scene.view(state, performance.now()));
}
