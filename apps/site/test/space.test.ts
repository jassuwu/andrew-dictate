import { describe, expect, test } from "bun:test";
import { spaceOwner, spaceRelease, tapMs } from "../src/demo/space";

// a browser cannot see fn, so the space bar stands in for it. it is also how
// a lot of people scroll, so the demo only takes it when that is safe.

describe("who owns the space bar", () => {
  test("the demo, when it is on screen and no control has focus", () => {
    expect(spaceOwner({ demoOnScreen: true, focus: "none" })).toBe("demo");
  });

  test("the page, when the demo is off screen", () => {
    expect(spaceOwner({ demoOnScreen: false, focus: "none" })).toBe("page");
  });

  test("a focused button or link, wherever the demo is", () => {
    expect(spaceOwner({ demoOnScreen: true, focus: "control" })).toBe("control");
    expect(spaceOwner({ demoOnScreen: false, focus: "control" })).toBe("control");
  });

  test("the demo's own key handles itself when it has focus", () => {
    expect(spaceOwner({ demoOnScreen: true, focus: "key" })).toBe("control");
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
