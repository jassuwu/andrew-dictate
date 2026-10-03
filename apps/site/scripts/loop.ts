// bun run loop
//
// makes demo.gif, the short silent loop of the dictation demo that the
// readme shows, from the built page. github cannot run the page, so this is
// the page run once and filmed.
//
// it serves dist/, opens it in a headless chromium, holds the key for one
// whole prompt, and takes a picture every fifteenth of a second of the
// page's own clock. the clock is stepped by hand, so every run gives the
// same frames, and the text lands after exactly the wait the demo uses.
//
// it needs ffmpeg on the path, and a chromium: `bunx playwright install
// chromium`, or CHROMIUM=/path/to/a/chromium.

import { $ } from "bun";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { chromium } from "playwright-core";
import { timing } from "../src/demo/dictation";
import pairs from "../src/demo/pairs.json";

const site = join(import.meta.dir, "..");
const dist = join(site, "dist");
if (!existsSync(join(dist, "index.html"))) {
  throw new Error("dist/ is not there. run `bun run build` first, or `bun run loop`.");
}

const server = Bun.serve({
  port: 0,
  async fetch(request) {
    const path = new URL(request.url).pathname;
    const file = Bun.file(join(dist, path.endsWith("/") ? `${path}index.html` : path));
    return (await file.exists()) ? new Response(file) : new Response("not found", { status: 404 });
  },
});

const fps = 15;
const frameMs = 1000 / fps;
const frames = mkdtempSync(join(tmpdir(), "andrew-loop-"));

const browser = await chromium.launch({ executablePath: process.env.CHROMIUM });
// narrow enough that the page is one column, and short enough that the
// frame is the demo and nothing else: the agent's box, the key, the lamp
const page = await browser.newPage({
  viewport: { width: 760, height: 540 },
  deviceScaleFactor: 2,
  reducedMotion: "no-preference",
});
await page.clock.install({ time: 0 });
await page.goto(`http://localhost:${server.port}/`, { waitUntil: "networkidle" });
// the menu bar and the paragraphs under the demo are not part of the picture
await page.addStyleTag({ content: ".menubar { display: none } .hero-why { visibility: hidden }" });

// the agent's box at the top of the frame, the key under it, the lamp below
await page.evaluate(() => {
  const box = document.querySelector(".agent")!.getBoundingClientRect();
  window.scrollTo(0, box.top + window.scrollY - 36);
});

let count = 0;
async function film(ms: number) {
  for (let elapsed = 0; elapsed < ms; elapsed += frameMs) {
    await page.clock.runFor(frameMs);
    await page.screenshot({ path: join(frames, `${String(count++).padStart(4, "0")}.png`) });
  }
}

const key = page.locator("[data-key]");
const box = (await key.boundingBox())!;
const words = pairs.prompts[0].cuts.length;

await film(700);
await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
await page.mouse.down();
await film(timing.firstAudio + words * timing.word + 350);
await page.mouse.up();
await film(timing.wait + timing.send + timing.reply + 1700);

await browser.close();
server.stop();

// two passes, so the gif gets a palette made for these frames: mostly black
// and a few golds
const out = join(site, "demo.gif");
const filters = "fps=15,scale=760:-1:flags=lanczos";
await $`ffmpeg -y -loglevel error -framerate ${fps} -i ${join(frames, "%04d.png")} -vf ${`${filters},palettegen=max_colors=64:stats_mode=diff`} ${join(frames, "palette.png")}`;
await $`ffmpeg -y -loglevel error -framerate ${fps} -i ${join(frames, "%04d.png")} -i ${join(frames, "palette.png")} -lavfi ${`${filters} [x]; [x][1:v] paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle`} -loop 0 ${out}`;
rmSync(frames, { recursive: true });

console.log(`${out}: ${count} frames, ${(Bun.file(out).size / 1024).toFixed(0)} kb`);
