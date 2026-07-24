// Strudel pattern  →  normalized WAV in public/.  Run with:  node render-audio.mjs
//
// Pipeline: query the pattern into timed events ("haps"), play each through superdough onto an
// OfflineAudioContext (faster than realtime, no browser), then peak-normalize and write a 16-bit WAV.
// Every line that looks defensive is guarding a real footgun — see REFERENCE.md.

import './audio-globals.mjs';                       // FIRST: install Web Audio globals (see that file)
import { OfflineAudioContext } from 'node-web-audio-api';
import * as core from '@strudel/core';
import * as miniMod from '@strudel/mini';
import '@strudel/tonal';                            // registers scale()/voicing()/chord() controls
import * as SD from 'superdough';
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import { CPS, CYCLES, DURATION_SECONDS, DURATION_IN_FRAMES, BPM } from './sync.mjs';
import { getPattern, SAMPLES, USE_WORKLETS } from './music.mjs';

core.setStringParser(miniMod.mini);                 // wire mini-notation — without this, "c3 e3" is ONE dead atom

const SR = 44100;
const TARGET_PEAK = 0.89;                           // -1 dBFS: loud, with headroom, never clips
const OUT = process.argv[2] || 'public/audio.wav';

const ctx = new OfflineAudioContext(2, Math.ceil(SR * DURATION_SECONDS), SR);
SD.setAudioContext(ctx);                            // inject our offline context BEFORE any sound is made
SD.registerSynthSounds();                           // sine/sawtooth/square/triangle (silent without this)
if (USE_WORKLETS) await SD.loadWorklets();          // supersaw/wavetable/crush/coarse/shape
for (const bank of SAMPLES) await SD.samples(bank); // preload sample maps (network fetch)

// Query the whole timeline once; keep only note-ONsets (a held note re-appears as fragments we must skip).
const pattern = getPattern(core);
const haps = pattern.queryArc(0, CYCLES).filter((h) => h.hasOnset());

// Schedule one superdough voice per hap. begin/end are Fractions of cycles → divide by cps for seconds.
const results = await Promise.allSettled(
  haps.map((h) => {
    const begin = h.whole.begin.valueOf();
    const dur = (h.whole.end.valueOf() - begin) / CPS;   // synths REQUIRE a duration or the voice throws
    return SD.superdough(h.value, begin / CPS, dur, CPS, begin);
  }),
);
const failed = results.filter((r) => r.status === 'rejected');
if (failed.length) {
  console.warn(`⚠ ${failed.length}/${haps.length} voices errored — first:`, String(failed[0].reason).slice(0, 140));
}

const buf = await ctx.startRendering();

// ---- master: peak-normalize to TARGET_PEAK. Guarantees no clipping no matter how hot the mix is. ----
const ch = buf.numberOfChannels, n = buf.length, chans = [];
let peak = 0;
for (let c = 0; c < ch; c++) {
  const d = buf.getChannelData(c);
  chans.push(d);
  for (let i = 0; i < n; i++) { const a = Math.abs(d[i]); if (a > peak) peak = a; }
}
const gain = peak > 0 ? TARGET_PEAK / peak : 1;

// ---- 16-bit PCM WAV (44-byte RIFF header + interleaved samples; no dependency needed) ----
const blockAlign = ch * 2, dataLen = n * blockAlign;
const ab = new ArrayBuffer(44 + dataLen), dv = new DataView(ab);
const str = (o, s) => { for (let i = 0; i < s.length; i++) dv.setUint8(o + i, s.charCodeAt(i)); };
str(0, 'RIFF'); dv.setUint32(4, 36 + dataLen, true); str(8, 'WAVE'); str(12, 'fmt ');
dv.setUint32(16, 16, true); dv.setUint16(20, 1, true); dv.setUint16(22, ch, true);
dv.setUint32(24, SR, true); dv.setUint32(28, SR * blockAlign, true);
dv.setUint16(32, blockAlign, true); dv.setUint16(34, 16, true); str(36, 'data'); dv.setUint32(40, dataLen, true);
let off = 44;
for (let i = 0; i < n; i++) for (let c = 0; c < ch; c++) {
  const v = Math.max(-1, Math.min(1, chans[c][i] * gain));
  dv.setInt16(off, v < 0 ? v * 0x8000 : v * 0x7fff, true); off += 2;
}

mkdirSync(dirname(OUT), { recursive: true });
writeFileSync(OUT, Buffer.from(ab));
console.log(`✓ ${OUT}  ·  ${DURATION_SECONDS.toFixed(2)}s @ ${BPM} BPM  ·  peak ${peak.toFixed(2)} → -1 dBFS  ·  ${haps.length} voices`);
console.log(`  Composition is ${DURATION_IN_FRAMES} frames — src/Root.tsx reads this from sync.mjs automatically.`);
