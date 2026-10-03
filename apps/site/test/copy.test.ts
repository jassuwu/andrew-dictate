import { describe, expect, test } from "bun:test";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { sizes, topBlock } from "../src/copy";

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
    for (const line of [
      topBlock.name,
      topBlock.tagline,
      ...topBlock.pitch,
      ...topBlock.why,
      topBlock.models,
    ]) {
      expect(page).toContain(line);
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
    expect(sizes.dictation).toBe(constant("dictationDownload")!);
    expect(sizes.meetings).toBe(constant("meetingsDownload")!);
  });
});
