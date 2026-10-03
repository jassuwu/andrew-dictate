// who the space bar belongs to. a browser cannot see fn, so space stands in
// for it, but space is also how a lot of people scroll and how every button
// is pressed. the demo takes it only when nothing else has a claim.

export function demoOwnsSpace(at: { demoOnScreen: boolean; controlFocused: boolean }): boolean {
  return at.demoOnScreen && !at.controlFocused;
}

/** shorter than this and a press of space was a tap, which is someone
    scrolling. the take does not start until a press has lasted this long, so
    a tap lights no lamp and plays no chime: the page just scrolls. */
export const tapMs = 120;

export function spaceRelease(heldMs: number): "scroll" | "release" {
  return heldMs < tapMs ? "scroll" : "release";
}
