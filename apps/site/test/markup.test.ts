import { describe, expect, test } from "bun:test";
import { pieces, plain } from "../src/markup";

// the copy is written once, in markdown's two marks, so the readme can hold
// it as it is and the page can set it.

describe("pieces", () => {
  test("a key in backticks is a keycap, anything else in backticks is code", () => {
    expect(pieces("hold `fn`, click `open anyway`")).toEqual([
      { kind: "text", text: "hold " },
      { kind: "key", text: "fn" },
      { kind: "text", text: ", click " },
      { kind: "code", text: "open anyway" },
    ]);
  });

  test("a link keeps its words, and the site's own address becomes a path", () => {
    expect(pieces("[they get better](https://dictate.jass.gg/changelog) and [mit](https://github.com/x/LICENSE).")).toEqual([
      { kind: "link", text: "they get better", href: "/changelog" },
      { kind: "text", text: " and " },
      { kind: "link", text: "mit", href: "https://github.com/x/LICENSE" },
      { kind: "text", text: "." },
    ]);
  });

  test("an address that only starts like the site's stays whole", () => {
    expect(pieces("[x](https://dictate.jass.gg.example.com/a)")).toEqual([
      { kind: "link", text: "x", href: "https://dictate.jass.gg.example.com/a" },
    ]);
  });

  test("plain text is one piece", () => {
    expect(pieces("english, or 25 languages.")).toEqual([
      { kind: "text", text: "english, or 25 languages." },
    ]);
  });
});

describe("plain", () => {
  test("is what a reader reads: no backticks, link words only", () => {
    expect(plain("hold `fn`. [releases](https://x.y/releases) too.")).toBe("hold fn. releases too.");
  });
});
