import { describe, expect, test } from "bun:test";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { lines, sizes, topBlock } from "../src/copy";
import { plain } from "../src/markup";

// the copy guard. it reads the page as it was built, because that is what a
// visitor gets, and fails when the old pitch comes back: the app sold by what
// it does not do, a named competitor, or a speed number. build first.

const site = join(import.meta.dir, "..");
const repo = join(site, "..", "..");

/** what a visitor can read: no scripts, no styles, no tags. */
export function visibleText(html: string): string {
  return html
    .replace(/<script[\s\S]*?<\/script>/gi, " ")
    .replace(/<style[\s\S]*?<\/style>/gi, " ")
    // a link or a keycap sits inside a sentence and adds no space to it
    .replace(/<\/?(a|span|kbd|code|em|strong)\b[^>]*>/gi, "")
    .replace(/<[^>]+>/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&#39;|&apos;/g, "'")
    .replace(/&quot;/g, '"')
    .replace(/&nbsp;/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function builtPage(name: string): string {
  const path = join(site, "dist", name);
  if (!existsSync(path)) {
    throw new Error(`${path} is not there. run \`bun run build\` first.`);
  }
  return visibleText(readFileSync(path, "utf8"));
}

const retired: [string, RegExp][] = [
  ["a named competitor", /wispr/i],
  ["never leaves", /never leaves/i],
  ["no account", /no account/i],
  ["free forever", /free,? forever/i],
  ["open source as a pitch", /open[- ]source/i],
  ["fully local or private", /fully (local|private)/i],
  ["the line count", /lines of swift/i],
  ["the no-rewrite brag", /no model rewrote/i],
  ["where your words go", /where your words go/i],
  ["a speed number", /\d\s?ms\b|milliseconds?/i],
];

describe("the page", () => {
  const page = builtPage("index.html");

  for (const [name, pattern] of retired) {
    test(`does not bring back ${name}`, () => {
      expect(page).not.toMatch(pattern);
    });
  }

  test("opens with the top block, word for word", () => {
    for (const line of [topBlock.name, topBlock.tagline, ...topBlock.pitch]) {
      expect(page).toContain(line);
    }
  });

  test("says every line of the copy", () => {
    for (const line of lines) expect(page).toContain(plain(line));
  });

  test("has no scripted demo left in it", () => {
    expect(page).not.toMatch(/hold the key|press record here|try it/i);
  });
});

/** what a reader of the readme on github can read. */
function markdownText(markdown: string): string {
  return visibleText(
    markdown
      .replace(/```[\s\S]*?```/g, " ")
      .replace(/!\[[^\]]*\]\([^)]*\)/g, " ")
      .replace(/\[([^\]]+)\]\([^)]*\)/g, "$1")
      .replace(/[*`]/g, ""),
  );
}

describe("the readme", () => {
  const readme = markdownText(readFileSync(join(repo, "README.md"), "utf8"));

  for (const [name, pattern] of retired) {
    test(`does not bring back ${name}`, () => {
      expect(readme).not.toMatch(pattern);
    });
  }

  test("opens with the banner, and its words are in the alt text", () => {
    const source = readFileSync(join(repo, "README.md"), "utf8");
    const alt = source.match(/^<p[^>]*>\s*<img src="apps\/mac\/art\/og\.png" alt="([^"]+)"/)?.[1];
    expect(alt).toBeDefined();
    for (const line of [topBlock.name, topBlock.tagline, topBlock.pitch[0]]) {
      expect(alt).toContain(line);
    }
  });

  test("says what the page says, line for line", () => {
    for (const line of lines) expect(readme).toContain(plain(line));
  });

  test("quotes the download sizes onboarding shows", () => {
    expect(readme).toContain(sizes.dictation);
    expect(readme).toContain(sizes.meetings);
  });

  test("leaves out the sections that sold what the app does not do", () => {
    for (const heading of ["where your words go", "limits", "next", "not coming"]) {
      expect(readme).not.toMatch(new RegExp(`(^|\\s)#+ ${heading}`, "i"));
    }
  });
});

describe("the download sizes", () => {
  // onboarding is the source (SPEC §5). the site quotes it, so it is held
  // to it here rather than trusted to be remembered.
  const swift = readFileSync(
    join(repo, "apps/mac/Sources/Onboarding/OnboardingState.swift"),
    "utf8",
  );
  const constant = (name: string) =>
    swift.match(new RegExp(`static let ${name} = "([^"]+)"`))?.[1];

  test("are the ones onboarding shows", () => {
    expect(constant("dictationDownload")).toBe(sizes.dictation);
    expect(constant("meetingsDownload")).toBe(sizes.meetings);
  });
});
