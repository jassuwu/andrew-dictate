// who the space bar belongs to. a browser cannot see fn, so space stands in
// for it, but space is also how a lot of people scroll and how every button
// is pressed. the demo takes it only when nothing else has a claim.

export type Focus =
  /** nothing that answers to space has focus */
  | "none"
  /** a button, a link, a field: space is theirs */
  | "control"
  /** the demo's own key, which listens for space itself */
  | "key";

export type SpaceOwner = "demo" | "page" | "control";

export function spaceOwner(at: { demoOnScreen: boolean; focus: Focus }): SpaceOwner {
  if (at.focus !== "none") return "control";
  return at.demoOnScreen ? "demo" : "page";
}

/** shorter than this and a press of space was a tap, which is someone
    scrolling. the demo gives the tap back to the page. */
export const tapMs = 180;

export function spaceRelease(heldMs: number): "scroll" | "release" {
  return heldMs < tapMs ? "scroll" : "release";
}
