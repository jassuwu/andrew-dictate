// the words the page and the readme share. each is written once, here, in
// markdown's two marks (src/markup.ts), and test/copy.test.ts holds the page
// and the readme to every line.

export const topBlock = {
  name: "andrew dictate",
  tagline: "escape the keyboard.",
  pitch: [
    "dictation for talking to your agents.",
    "meeting transcripts your agents can read.",
    "free. fast. local.",
  ],
} as const;

// onboarding is the source of these two (SPEC §5). the copy guard reads the
// swift and fails when they drift.
export const sizes = {
  dictation: "~460 mb",
  meetings: "~2.9 gb",
} as const;

const repo = "https://github.com/jassuwu/andrew-dictate";

export const intro =
  "a mac app. it's alpha. the words and the formatting aren't always right, and [they get better over time](https://dictate.jass.gg/changelog).";

export const dictate =
  "hold `fn`, talk, let go. the text lands where your cursor is, in any app. double-tap `fn` to talk hands-free, and `esc` throws it away. a dictionary fixes a word it keeps mishearing. if your keyboard eats `fn`, pick another key in settings. english, or 25 languages.";

export const meetings =
  "press record in the menu bar, or say yes when the app asks at the start of a call. it never starts by itself. your mic is you, and whatever the mac plays is them. press stop and you get one markdown file with the speakers split out, in english by default. point your agent at the folder. settings can run a script of yours after each meeting is saved.";

export const install = "brew install --cask jassuwu/tap/andrew-dictate";

export const upgrade = "brew upgrade --cask jassuwu/tap/andrew-dictate";

export const unblock = [
  'xattr -dr com.apple.quarantine "/Applications/Andrew Dictate.app"',
  'open "/Applications/Andrew Dictate.app"',
].join("\n");

export const installLines = {
  unsigned:
    "apple silicon, macOS 26. i'm broke, so i didn't pay apple $99 to sign this. run this once:",
  after: `there's no dock icon. it lives in the menu bar as the gold badge. setup asks which jobs you want: dictation (${sizes.dictation}), and meetings (${sizes.meetings}) if you tick it.`,
  noTerminal: `no terminal? open the app, let macOS refuse, then click \`open anyway\` in system settings › privacy & security within the hour. there's a dmg in [releases](${repo}/releases) too.`,
} as const;

export const updateLines = {
  menu: "the menu says when there's a new version, and a click updates it. or:",
  check:
    "to know, the app sends its version to dictate.jass.gg once a day, and nothing else. settings › general turns that off.",
} as const;

/** the speech models and the libraries that run them, with their licences. */
export const credits = [
  ["FluidAudio", "https://github.com/FluidInference/FluidAudio", "apache-2.0"],
  ["parakeet", "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2", "cc-by-4.0"],
  ["WhisperKit", "https://github.com/argmaxinc/WhisperKit", "mit"],
  ["whisper", "https://github.com/openai/whisper", "mit"],
  ["whistle", "https://huggingface.co/Cactus-Compute/whistle", "apache-2.0"],
  ["silero vad", "https://github.com/snakers4/silero-vad", "mit"],
] as const;

export const licence = `[mit](${repo}/blob/main/LICENSE), so fork it if you want it different.`;

/** every line both places say, in the order they say it. */
export const lines = [
  intro,
  dictate,
  meetings,
  installLines.unsigned,
  installLines.after,
  installLines.noTerminal,
  updateLines.menu,
  updateLines.check,
  licence,
];

/** the words in `intro` that link to the changelog, where the claim is kept. */
export const proof = "they get better over time";

export const description =
  "dictation and meeting transcripts for talking to your agents. hold fn, talk, let go. free, fast, local. macOS.";
