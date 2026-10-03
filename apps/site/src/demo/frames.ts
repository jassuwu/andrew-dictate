// what the two demos' views share: a loop that draws a view each frame for
// as long as it can still change by itself, and a way to skip a draw that
// would change nothing.

export function frameLoop<View>(scene: {
  read: (now: number) => View;
  draw: (view: View, now: number) => void;
  /** nothing more will change until a hand does something. */
  settled: (view: View, now: number) => boolean;
}) {
  let frame = 0;

  function tick(now: number) {
    const view = scene.read(now);
    scene.draw(view, now);
    frame = scene.settled(view, now) ? 0 : requestAnimationFrame(tick);
  }

  return {
    /** start drawing, if it is not drawing already. */
    wake() {
      if (!frame) frame = requestAnimationFrame(tick);
    },
    get asleep() {
      return frame === 0;
    },
  };
}

/** says whether what is on the page would differ: true the first time it is
    asked, and whenever the parts it is given have changed since. */
export function differ() {
  let last = "";
  return (parts: unknown[]) => {
    const next = JSON.stringify(parts);
    if (next === last) return false;
    last = next;
    return true;
  };
}
