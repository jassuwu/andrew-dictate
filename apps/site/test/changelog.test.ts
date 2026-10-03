import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { inline, releases } from "../src/changelog";

// the changelog page is made from the release notes file, the one the
// release workflow already reads. this is the reading.

const notes = `## 0.2.0

the second one. it has \`code\` in it.

a second paragraph,
on two lines.

## 0.1.0

the first one.
`;

describe("release notes", () => {
  test("give one entry for each version heading, in the file's order", () => {
    expect(releases(notes).map((release) => release.version)).toEqual(["0.2.0", "0.1.0"]);
  });

  test("keep an entry's paragraphs, each on one line", () => {
    expect(releases(notes)[0].paragraphs).toEqual([
      "the second one. it has `code` in it.",
      "a second paragraph, on two lines.",
    ]);
    expect(releases(notes)[1].paragraphs).toEqual(["the first one."]);
  });

  test("with no entries are an error, so an empty page never ships", () => {
    expect(() => releases("")).toThrow();
    expect(() => releases("some words and no heading\n")).toThrow();
  });
});

describe("a paragraph", () => {
  test("is split into prose and code", () => {
    expect(inline("run `brew upgrade` and wait")).toEqual([
      { code: false, text: "run " },
      { code: true, text: "brew upgrade" },
      { code: false, text: " and wait" },
    ]);
  });

  test("with no code is one piece", () => {
    expect(inline("just words")).toEqual([{ code: false, text: "just words" }]);
  });
});

describe("the notes the app ships", () => {
  const shipped = releases(
    readFileSync(join(import.meta.dir, "../../mac/RELEASE_NOTES.md"), "utf8"),
  );

  test("are newest first", () => {
    const key = (version: string) =>
      version.split(".").reduce((sum, part) => sum * 1000 + Number(part), 0);
    const keys = shipped.map((release) => key(release.version));
    expect(keys).toEqual([...keys].sort((a, b) => b - a));
  });

  test("leave no entry empty", () => {
    for (const release of shipped) {
      expect(release.paragraphs.length).toBeGreaterThan(0);
    }
  });
});
