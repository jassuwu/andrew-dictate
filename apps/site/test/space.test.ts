import { describe, expect, test } from "bun:test";
import { demoOwnsSpace, spaceRelease, tapMs } from "../src/demo/space";

// a browser cannot see fn, so the space bar stands in for it. it is also how
// a lot of people scroll, so the demo only takes it when that is safe.

describe("the space bar", () => {
  test("is the demo's when the demo is on screen and no control has focus", () => {
    expect(demoOwnsSpace({ demoOnScreen: true, controlFocused: false })).toBe(true);
  });

  test("is the page's when the demo is off screen", () => {
    expect(demoOwnsSpace({ demoOnScreen: false, controlFocused: false })).toBe(false);
  });

  test("is a focused button's or link's, wherever the demo is", () => {
    expect(demoOwnsSpace({ demoOnScreen: true, controlFocused: true })).toBe(false);
    expect(demoOwnsSpace({ demoOnScreen: false, controlFocused: true })).toBe(false);
  });
});

describe("space coming back up", () => {
  test("after a tap, the page scrolls as it would have", () => {
    expect(spaceRelease(0)).toBe("scroll");
    expect(spaceRelease(tapMs - 1)).toBe("scroll");
  });

  test("after a hold, the take ends", () => {
    expect(spaceRelease(tapMs)).toBe("release");
    expect(spaceRelease(4000)).toBe("release");
  });
});
