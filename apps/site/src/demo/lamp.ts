// the lamp, drawn the way the app draws it. this is a port of the glass tube
// in apps/mac (HUDView: LampPose, wavePath, drawGlassTube, drawOffDot), with
// the same numbers, so the page's lamp is the app's lamp and not a likeness.
// the one thing left out is the smoke under it, which is only there so the
// lamp survives a white page, and this page is black.

export type LampPhase = "off" | "ember" | "burn" | "cool" | "pilot";

export type LampFrame = {
  phase: LampPhase;
  /** ms since the phase began */
  elapsed: number;
  /** ms on any steady clock: it moves the wave and breathes the ember */
  now: number;
  /** how loud the voice is, 0 to 1 */
  loudness: number;
  reduceMotion: boolean;
};

// HUDWaveMotion and LampLine, in the app's points
const ignite = 0.14;
const cool = 0.3;
const length = 112;
const thickness = 6;
const amplitude = 7.5;
const emberHeat = 0.2;
const meetingGlow = 0.2;
const meetingRise = 0.8;

// LampPalette.gold: the brand's pale, gold and deep
const pale = [249, 233, 168];
const mid = [229, 190, 98];
const deep = [158, 117, 39];

/** css px to one of the app's points. the page's lamp is drawn half as big
    again as the app's, because it is the one thing on the page that moves. */
export const lampScale = 1.5;

type Pose = {
  heat: number;
  presence: number;
  extent: number;
  dotFlash: number;
  damp: number;
  glow: number;
};

const lerp = (a: number, b: number, t: number) => a + (b - a) * t;
const clamp = (x: number) => Math.min(Math.max(x, 0), 1);
const smoothstep = (t: number) => {
  const c = clamp(t);
  return c * c * (3 - 2 * c);
};

/** where the lamp is in its life, as numbers (LampPose.at). */
function pose(phase: LampPhase, elapsed: number, time: number): Pose {
  const p: Pose = { heat: 0, presence: 0, extent: 1, dotFlash: 0, damp: 1, glow: 0 };
  switch (phase) {
    case "ember":
      p.heat = emberHeat + 0.08 * Math.sin((time * Math.PI * 2) / 2.8);
      p.presence = 1;
      p.damp = 0;
      break;
    case "pilot": {
      const t = smoothstep(Math.min(elapsed / meetingRise, 1));
      p.heat = lerp(emberHeat, 1, t);
      p.glow = meetingGlow * t;
      p.presence = 1;
      p.damp = 0;
      break;
    }
    case "burn": {
      const t = Math.min(elapsed / ignite, 1);
      p.presence = 1;
      // the app's ignite grows the line out from the middle. here the ember
      // is already full length when the mic is heard, so the line stays and
      // only the heat comes up.
      p.heat = t < 0.75 ? lerp(emberHeat, 1.12, smoothstep(t / 0.75)) : lerp(1.12, 1, (t - 0.75) / 0.25);
      break;
    }
    case "cool": {
      const t = Math.min(elapsed / cool, 1);
      p.presence = 1 - smoothstep(t);
      p.heat = Math.pow(1 - t, 1.6);
      p.extent = Math.pow(1 - Math.min(t / 0.6, 1), 2);
      p.dotFlash = Math.max(0, (t - 0.35) / 0.65);
      p.damp = Math.exp(-elapsed / 0.12);
      break;
    }
    case "off":
      break;
  }
  return p;
}

const rgba = (rgb: number[], alpha: number) =>
  `rgba(${rgb[0]}, ${rgb[1]}, ${rgb[2]}, ${clamp(alpha)})`;

/** deep when dim, pale when hot. */
const mix = (b: number) => {
  const t = clamp(b);
  return [lerp(deep[0], pale[0], t), lerp(deep[1], pale[1], t), lerp(deep[2], pale[2], t)];
};

/** the wave a voice puts in the line (GoldRippleLine.wavePath). */
function wave(
  ctx: CanvasRenderingContext2D,
  cx: number,
  cy: number,
  half: number,
  amp: number,
  time: number,
  dy = 0,
) {
  const segments = 48;
  ctx.beginPath();
  for (let i = 0; i <= segments; i++) {
    const u = i / segments;
    const x = cx - half + u * half * 2;
    const envelope = Math.pow(Math.sin(Math.PI * u), 1.4);
    const y =
      amp *
      envelope *
      (0.68 * Math.sin(u * Math.PI * 4.4 - time * 8.2) +
        0.32 * Math.sin(u * Math.PI * 8.2 + time * 5.1 + 1.3));
    if (i === 0) ctx.moveTo(x, cy + y + dy);
    else ctx.lineTo(x, cy + y + dy);
  }
}

function stroke(ctx: CanvasRenderingContext2D, color: string, width: number) {
  ctx.strokeStyle = color;
  ctx.lineWidth = width;
  ctx.lineCap = "round";
  ctx.lineJoin = "round";
  ctx.stroke();
}

/** a soft stroke with nothing sharp in it: the path is drawn far off the
    canvas and only its shadow lands. canvas blur filters are not everywhere,
    and shadows are. */
function glow(
  ctx: CanvasRenderingContext2D,
  path: () => void,
  color: string,
  width: number,
  radius: number,
  unit: number,
) {
  // shadows ignore the canvas transform, so they are given in device pixels
  const away = 4_000;
  ctx.save();
  ctx.shadowColor = color;
  ctx.shadowBlur = radius * 2 * unit;
  ctx.shadowOffsetX = away * unit;
  ctx.translate(-away, 0);
  path();
  // the stroke itself is never seen, so it is solid: the shadow carries the
  // colour's alpha once, not twice
  stroke(ctx, "#000", width);
  ctx.restore();
}

export function createLamp(canvas: HTMLCanvasElement) {
  const ctx = canvas.getContext("2d")!;
  // the tube is drawn apart, so its shade, rim and core can be kept inside it
  const tube = document.createElement("canvas");
  const tubeCtx = tube.getContext("2d")!;

  function resize() {
    const ratio = window.devicePixelRatio || 1;
    const { width, height } = canvas.getBoundingClientRect();
    for (const c of [canvas, tube]) {
      c.width = Math.round(width * ratio);
      c.height = Math.round(height * ratio);
    }
    return { width, height, ratio };
  }

  let box = resize();
  window.addEventListener("resize", () => (box = resize()));

  function draw(frame: LampFrame) {
    const { width, height, ratio } = box;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    if (frame.phase === "off") return;

    // everything below is in the app's points
    const unit = ratio * lampScale;
    const cx = width / lampScale / 2;
    const cy = height / lampScale / 2;
    const time = frame.now / 1000;

    let p = pose(frame.phase, frame.elapsed / 1000, time);
    let loudness = frame.loudness;
    if (frame.reduceMotion) {
      // drawStatic: no wave, no breath, no cool-out. a state, not a motion.
      if (frame.phase === "cool") return;
      p = {
        heat: frame.phase === "ember" ? 0.24 : 1,
        presence: 1,
        extent: 1,
        dotFlash: 0,
        damp: frame.phase === "burn" ? 1 : 0,
        glow: frame.phase === "pilot" ? meetingGlow : 0,
      };
      loudness = frame.phase === "burn" ? 0.5 : 0;
    }

    const voice = loudness * p.damp;
    const level = voice + p.glow;
    const b = p.heat * (0.24 + 0.76 * level);
    const alpha = Math.max(p.presence, p.heat);
    const half = (length / 2) * p.extent;
    const amp = frame.reduceMotion ? 0 : amplitude * voice * p.heat;
    const lit = clamp(b);
    const t = thickness;

    ctx.setTransform(unit, 0, 0, unit, 0, 0);

    if (half > 1.2) {
      const path = (target: CanvasRenderingContext2D, dy = 0) =>
        wave(target, cx, cy, half, amp, time, dy);

      // halo: the light the glass spills
      glow(ctx, () => path(ctx), rgba(mix(b), 0.55 * lit * alpha), t + 8, 6 + 6 * lit, unit);

      // outline: barely there on black
      path(ctx);
      stroke(ctx, `rgba(0, 0, 0, ${0.14 * alpha})`, t + 1.4);

      // the tube: body, then shade, rim and core kept inside the body
      tubeCtx.setTransform(1, 0, 0, 1, 0, 0);
      tubeCtx.clearRect(0, 0, tube.width, tube.height);
      tubeCtx.setTransform(unit, 0, 0, unit, 0, 0);
      tubeCtx.globalCompositeOperation = "source-over";
      path(tubeCtx);
      stroke(tubeCtx, rgba(mix(0.4 + 0.4 * lit), (0.42 + 0.28 * lit) * alpha), t);
      tubeCtx.globalCompositeOperation = "source-atop";
      path(tubeCtx, t * 0.28);
      stroke(tubeCtx, rgba(deep, 0.34 * alpha), t * 0.62);
      path(tubeCtx, -(t / 2 - 1));
      stroke(tubeCtx, rgba(pale, (0.5 + 0.4 * lit) * alpha), 1.1);
      path(tubeCtx, t / 2 - 0.7);
      stroke(tubeCtx, `rgba(255, 255, 255, ${0.16 * alpha})`, 0.8);
      path(tubeCtx);
      stroke(tubeCtx, rgba(pale, (0.1 + 0.55 * Math.min(level, 1)) * lit * alpha), t * 0.5);

      ctx.setTransform(1, 0, 0, 1, 0, 0);
      ctx.drawImage(tube, 0, 0);
      ctx.setTransform(unit, 0, 0, unit, 0, 0);
    }

    if (p.dotFlash > 0) {
      // the goodbye: the line collapses to a hot dot, and the dot fades
      const strength = Math.sin(Math.PI * Math.min(p.dotFlash, 1)) * p.heat;
      const halo = 10 + 18 * strength;
      const gradient = ctx.createRadialGradient(cx, cy, 0, cx, cy, halo);
      gradient.addColorStop(0, rgba(mid, 0.35 * strength));
      gradient.addColorStop(1, rgba(mid, 0));
      ctx.fillStyle = gradient;
      ctx.beginPath();
      ctx.arc(cx, cy, halo, 0, Math.PI * 2);
      ctx.fill();

      const core = 1.8 + 0.8 * strength;
      ctx.save();
      ctx.shadowColor = rgba(pale, 0.9 * strength);
      ctx.shadowBlur = 10 * unit;
      ctx.fillStyle = rgba(pale, 0.95 * strength);
      ctx.beginPath();
      ctx.arc(cx, cy, core, 0, Math.PI * 2);
      ctx.fill();
      ctx.restore();
    }
  }

  return { draw };
}

/** a voice for the lamp, since nobody is really talking: one swell a word,
    each a little different, the same every time. 0 once the words run out. */
export function scriptedLoudness(sinceLit: number, wordMs: number, words: number): number {
  if (sinceLit < 0) return 0;
  const index = Math.floor(sinceLit / wordMs);
  if (index >= words) return 0;
  const phase = (sinceLit % wordMs) / wordMs;
  // a cheap hash, so word 3 is always as loud as word 3 was
  const seed = Math.sin((index + 1) * 12.9898) * 43758.5453;
  const strength = 0.55 + 0.4 * (seed - Math.floor(seed));
  const swell = Math.pow(Math.sin(Math.PI * phase), 0.7);
  const flutter = 0.12 * Math.sin(sinceLit / 23) * swell;
  return clamp(strength * swell + flutter);
}
