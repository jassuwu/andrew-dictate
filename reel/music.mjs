// The music. This is the file you rewrite for each piece.
//
// Return ONE pattern (usually a `stack(...)` of layers). `c` is @strudel/core, so every control —
// note, n, s, stack, sequence, … — is on it, and mini-notation strings work inside controls.
// Read SOUND.md before writing here: it is the difference between "a beep" and something composed.
// Reach for whatever sounds best — sampled drums for punch, synthesis for clean/offline. Just be
// aware of what each sample bank costs you if you distribute the result (REFERENCE.md → "Licensing").
//
// Quick mini-notation reminder (full guide in SOUND.md):
//   "a b c"   three events inside ONE cycle (sequence)      "<a b c>"  one per cycle (slowcat — melody over bars)
//   "a,b,c"   all at once (stack — a chord)                 "[a b]"    a subdivision group
//   "a*2"     twice as fast    "a/2" half    "~" rest        "a(3,8)"  euclidean rhythm

export function getPattern(c) {
  const { note, s, stack } = c;

  // Drums (sampled, for punch). Broken kick + backbeat snare + grooved hats (gain pattern = feel, not a metronome).
  const drums = stack(
    s("bd ~ ~ bd ~ ~ bd ~").gain(0.9),
    s("~ sd ~ sd").gain(0.5),
    s("hh*8").gain("[.3 .55]*4"),
  );

  // Moving bassline — one root per bar via slowcat, lowpassed so it sits under everything.
  const bass = note("<c2 c2 ab1 g1>").s("sawtooth").cutoff(520).decay(0.2).sustain(0.4).gain(0.42);

  // Wide pad: a supersaw chord progression, slow attack, reverb for space. The harmonic bed.
  const pad = note("<[c3,eb3,g3] [c3,eb3,g3] [ab2,c3,eb3] [g2,b2,d3]>")
    .s("supersaw").attack(0.06).release(0.7).cutoff(1700).gain(0.13).room(0.5);

  // Glittering arp on top — delayed, bright, the line your eye/ear follows.
  const arp = note("eb4 g4 bb4 c5 bb4 g4 eb4 g4")
    .s("triangle").gain(0.12).cutoff(2600).delay(0.3).delaytime(0.1875).delayfeedback(0.35);

  return stack(drums, bass, pad, arp);
}

// Sample banks to preload (anything you reference with s('bd'), s('piano'), …). Fetched once over
// the network. The default dirt-samples drums sound great and are fine for personal/most use — but
// most of its banks have NO declared license, so for COMMERCIAL/DISTRIBUTED work prefer CC0 'VCSL'
// or go fully synthesized: set SAMPLES = [] and use the synth-drum recipes in SOUND.md → "Drums".
export const SAMPLES = ['github:tidalcycles/dirt-samples'];

// Load superdough's AudioWorklet DSP (supersaw, wavetable, crush, coarse, shape). Verified to work in
// Node; set false to stay on the native-only subset (sine/saw/square/triangle + filters/delay/reverb).
export const USE_WORKLETS = true;
