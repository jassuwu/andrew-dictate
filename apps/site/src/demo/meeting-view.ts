// the thin layer between the meeting scene's state machine and the page.

import call from "./meeting.json";
import { agentLine } from "./agent";
import { differ, frameLoop } from "./frames";
import { hud, mic, reduceMotion } from "./hud";
import { meetingScene, pace, type LiveLine, type State, type View } from "./meeting";

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

  // someone who asked for less motion gets the end of the scene, the file,
  // and can still press record to watch it play
  let state: State = reduceMotion() ? scene.finished(performance.now()) : scene.initial();

  const changed = differ();

  const loop = frameLoop<View>({
    read: (now) => scene.view(state, now),
    draw(view, now) {
      render(view);
      hud.lamp("meeting", {
        phase: view.lamp.state,
        elapsed: now - view.lamp.since,
        now,
        loudness: 0,
      });
    },
    // a meeting that is recording with every line in changes nothing until
    // the stop, and its light is steady, so it need not be drawn again
    settled(view, now) {
      if (view.pill !== null) return false;
      switch (view.phase) {
        case "idle":
          return view.file === null || (view.reply !== null && view.lamp.state === "off");
        case "recording":
          return view.lines.length === call.lines.length && now - view.lamp.since > 1000;
        default:
          return false;
      }
    },
  });

  function send(type: "record" | "stop") {
    if (type === "record" && mic.dictating) {
      // the mic is one, and this is what the app says about it
      hud.say("finish dictating first", pace.pill);
      return;
    }
    state = scene.step(state, { type, at: performance.now() });
    loop.wake();
  }

  function render(view: View) {
    mic.meeting = view.live;

    if (
      !changed([
        view.phase,
        view.status,
        view.lines.length,
        view.canStop,
        view.pill,
        view.file?.name,
        view.ask,
        view.reply,
        view.badge,
      ])
    ) {
      return;
    }

    // one item, as in the app's menu: it starts a meeting or stops the one
    // that records
    button.textContent =
      view.phase === "writingOut"
        ? "writing it out…"
        : view.live
          ? "stop recording"
          : "record a meeting";
    // not `disabled`: that would drop the keyboard's focus from the button
    // the moment it is pressed
    const waiting = view.phase === "writingOut" || (view.live && !view.canStop);
    button.setAttribute("aria-disabled", String(waiting));
    button.toggleAttribute("data-live", view.live);

    status.textContent = view.status;
    title.textContent = view.file ? view.file.name : "live transcript";
    hint.hidden = view.phase !== "idle" || view.file !== null;

    lines.hidden = view.file !== null;
    showLines(view.lines);

    file.hidden = view.file === null;
    file.textContent = view.file?.markdown ?? "";

    showThread(view);

    hud.pill("meeting", view.pill);
    hud.badge("meeting", view.badge);
  }

  /** the list is a live region, so a new line is added to it and the lines
      already there are left alone: a screen reader reads the new one only. */
  function showLines(live: LiveLine[]) {
    if (live.length < lines.childElementCount) lines.replaceChildren();
    for (const line of live.slice(lines.childElementCount)) {
      const item = document.createElement("li");
      const stamp = document.createElement("span");
      stamp.className = "live-stamp";
      stamp.textContent = line.stamp;
      const who = document.createElement("span");
      who.className = line.speaker === "you" ? "live-you" : "live-them";
      who.textContent = `${line.speaker}:`;
      item.append(stamp, " ", who, " ", line.text);
      lines.append(item);
    }
    lines.scrollTop = lines.scrollHeight;
  }

  /** the same for the agent's thread: the ask, then its answer, each once. */
  function showThread(view: View) {
    const wanted = [view.ask, view.reply].filter((text) => text !== null).length;
    if (wanted < thread.childElementCount) thread.replaceChildren();
    if (view.ask !== null && thread.childElementCount === 0) {
      thread.append(agentLine("sent", view.ask));
    }
    if (view.reply !== null && thread.childElementCount === 1) {
      thread.append(agentLine("reply", view.reply));
    }
    thread.hidden = view.ask === null;
  }

  button.addEventListener("click", () => {
    if (button.getAttribute("aria-disabled") === "true") return;
    send(scene.view(state, performance.now()).live ? "stop" : "record");
  });

  render(scene.view(state, performance.now()));
}
