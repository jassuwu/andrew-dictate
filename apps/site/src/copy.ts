// the words every public place opens with. the page prints them, the readme
// repeats them, and test/copy.test.ts holds the two to this file.

export const topBlock = {
  name: "andrew dictate",
  tagline: "escape the keyboard.",
  pitch: [
    "dictation for talking to your agents.",
    "meeting transcripts your agents can read.",
    "free. fast. local.",
  ],
  why: [
    "i made this to be fast and free. speed is the part that doesn't change.",
    "the words and the formatting aren't always right. they get better over time, and i fix mistakes as i see them.",
  ],
  models:
    "the speech models are parakeet and whisper. this app puts them together and stays out of your way.",
} as const;

/** the words in `why` that link to the changelog, where the claim is kept. */
export const proof = "they get better over time";

// onboarding is the source of these two (SPEC §5). the copy guard reads the
// swift and fails when they drift.
export const sizes = {
  dictation: "~460 mb",
  meetings: "~2.9 gb",
} as const;

export const install = "brew install --cask jassuwu/tap/andrew-dictate";

export const unblock = [
  'xattr -dr com.apple.quarantine "/Applications/Andrew Dictate.app"',
  'open "/Applications/Andrew Dictate.app"',
].join("\n");

export const description =
  "dictation and meeting transcripts for talking to your agents. hold fn, talk, let go. free, fast, local. macOS.";
