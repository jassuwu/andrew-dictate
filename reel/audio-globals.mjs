// Web Audio, in Node.
//
// superdough (Strudel's sound engine) is written for the browser. To run it headless we install
// node-web-audio-api's classes as globals and stub the two browser objects it touches. This file
// MUST be imported BEFORE @strudel/* or superdough — ES modules hoist `import` statements, and
// superdough patches reverb/delay/vowel onto BaseAudioContext.prototype AT LOAD TIME by reading
// these globals. Install them late and those effects silently become no-ops.
//
// See REFERENCE.md → "The headless audio shim" for why each line is here.

import * as na from 'node-web-audio-api';

// OfflineAudioContext, AudioContext, GainNode, BiquadFilterNode, AudioWorkletNode, … as globals.
// Skip `default` (the namespace) and `mediaDevices` (irrelevant offline, and noisy).
for (const k of Object.keys(na)) {
  if (k !== 'default' && k !== 'mediaDevices') globalThis[k] = na[k];
}

// superdough does `window.addEventListener('message', …)` at load and `window.filterNode = …` inside
// its reverb impulse generator; @strudel/core attaches a `document` mouse-listener and dispatches a
// highlight CustomEvent. None of it matters headless — no-op stubs keep every path from throwing.
// (A bare `{}` is NOT enough: it has no addEventListener, so superdough crashes at import.)
const noop = () => {};
const stub = () => ({
  addEventListener: noop, removeEventListener: noop, dispatchEvent: noop, postMessage: noop,
  setAttribute: noop, appendChild: noop, removeChild: noop, style: {}, createElement: () => stub(),
});
if (typeof globalThis.window === 'undefined') globalThis.window = stub();
if (typeof globalThis.document === 'undefined') globalThis.document = stub();
