import {
  AbsoluteFill, Html5Audio, Img, staticFile, useCurrentFrame, useVideoConfig,
  spring, interpolate, Easing,
} from 'remotion';
import { useAudioData, visualizeAudio } from '@remotion/media-utils';
import { FRAMES_PER_BEAT, FRAMES_PER_BAR, barFrame, beatFrame } from '../sync.mjs';

// ANDREW DICTATE — launch film. 38s, 120 BPM, bar = 60 frames.
// Arc: cold open on a hit (bar 0) → bridge setup copy (bars 1–7) → DROP: badge reveal (bar 8)
// → chorus feature flexes (bars 9–15, gold inversion payoff) → piano-outro end card (bars 16–18).
// Brand: black #0B0B0D, gold #F9E9A8 → #E5BE62 → #9E7527 (from HUDGold in the app).

const INK = '#0B0B0D';
const PALE = '#F9E9A8';
const MID = '#E5BE62';
const DEEP = '#9E7527';

const SERIF = "'Didot', 'Bodoni 72', Georgia, serif";
const SANS = "'Helvetica Neue', -apple-system, sans-serif";

const goldText: React.CSSProperties = {
  background: `linear-gradient(180deg, ${PALE} 0%, ${MID} 55%, ${DEEP} 100%)`,
  WebkitBackgroundClip: 'text',
  backgroundClip: 'text',
  color: 'transparent',
};

// ---------- timeline (frames) ----------
const DROP = barFrame(8);        // 480 — the final-chorus downbeat
const END_CARD = barFrame(16);   // 960 — solo piano begins
const FADE_OUT = barFrame(18);   // 1080 — last bar: fade to black

// ---------- shared bits ----------

/** Eased entrance + exit for a timed line. Returns null outside its window. */
const useWindow = (from: number, to: number) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  if (frame < from || frame >= to) return null;
  const enter = spring({
    frame: frame - from, fps,
    config: { damping: 16, stiffness: 130, mass: 0.8 },
  });
  const exit = interpolate(frame, [to - 8, to], [1, 0], {
    extrapolateLeft: 'clamp', extrapolateRight: 'clamp',
    easing: Easing.in(Easing.cubic),
  });
  return { enter, exit, local: frame - from };
};

/** Luxury-ad copy line: caps serif, wide tracking that tightens as it lands. */
const CopyLine: React.FC<{
  from: number; to: number; size?: number; children: React.ReactNode;
  italic?: boolean; tracking?: [number, number];
}> = ({ from, to, size = 84, children, italic, tracking = [0.42, 0.16] }) => {
  const w = useWindow(from, to);
  if (!w) return null;
  const ls = interpolate(w.enter, [0, 1], tracking);
  return (
    <AbsoluteFill style={{ justifyContent: 'center', alignItems: 'center' }}>
      <div style={{
        ...goldText,
        fontFamily: SERIF, fontStyle: italic ? 'italic' : 'normal',
        fontSize: size, fontWeight: 400, textAlign: 'center',
        letterSpacing: `${ls}em`, paddingLeft: `${ls}em`, // recenter tracked type
        opacity: w.enter * w.exit,
        transform: `translateY(${(1 - w.enter) * 34}px)`,
        textShadow: `0 0 60px rgba(229,190,98,${0.28 * w.enter * w.exit})`,
        maxWidth: 1600, lineHeight: 1.25,
      }}>
        {children}
      </div>
    </AbsoluteFill>
  );
};

/** The app's HUD soundwave: 7 gold capsules, each breathing with its own frequency band. */
const SoundWave: React.FC<{ levels: number[]; barW: number; maxH: number; gap: number; opacity?: number }> =
  ({ levels, barW, maxH, gap, opacity = 1 }) => {
    const envelope = [0.48, 0.68, 0.86, 1, 0.86, 0.68, 0.48];
    return (
      <div style={{ display: 'flex', alignItems: 'center', gap, height: maxH, opacity }}>
        {envelope.map((env, i) => {
          const h = Math.max(barW, env * maxH * (0.22 + 0.78 * (levels[i] ?? 0)));
          return (
            <div key={i} style={{
              width: barW, height: h, borderRadius: barW / 2,
              background: `linear-gradient(180deg, ${PALE}, ${DEEP})`,
              boxShadow: `0 0 ${barW * 2.2}px rgba(229,190,98,0.45)`,
            }} />
          );
        })}
      </div>
    );
  };

// ---------- the film ----------

export const Video: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const audio = useAudioData(staticFile('audio.wav'));

  // Per-band energy for the soundwave; bass for the backdrop breathing.
  let bass = 0;
  let bands: number[] = [0, 0, 0, 0, 0, 0, 0];
  if (audio) {
    const bins = visualizeAudio({ audioData: audio, frame, fps, numberOfSamples: 32, smoothing: false });
    bass = Math.min(1, (bins[0] + bins[1]) * 1.5);
    bands = [2, 4, 6, 8, 10, 13, 16].map((b) =>
      Math.min(1, (bins[b] + bins[b + 1]) * 3.2));
  }

  // Beat pulse (small, everywhere) — the accent that keeps stillness alive.
  const sinceBeat = frame - beatFrame(Math.floor(frame / FRAMES_PER_BEAT));
  const settle = spring({ frame: sinceBeat, fps, config: { damping: 13, stiffness: 190, mass: 0.6 } });
  const punch = 1 - settle;

  const inChorus = frame >= DROP && frame < END_CARD;
  const goldInvert = frame >= beatFrame(62) && frame < END_CARD; // f930 — "AND GOLD."

  // Cold open: the hit at frame 0 — a gold flash that decays through bar 0.
  const openFlash = interpolate(frame, [0, 26], [0.85, 0], {
    extrapolateRight: 'clamp', easing: Easing.out(Easing.quad),
  });

  // Wind-up bar 7: a ring contracting to a point; the room dims.
  const windup = frame >= barFrame(7) && frame < DROP
    ? interpolate(frame, [barFrame(7), DROP], [0, 1], { easing: Easing.in(Easing.cubic) })
    : null;

  // Drop: flash + shockwave + badge spring.
  const dropFlash = frame >= DROP
    ? interpolate(frame, [DROP, DROP + 18], [1, 0], { extrapolateRight: 'clamp', easing: Easing.out(Easing.quad) })
    : 0;
  const shock = frame >= DROP
    ? interpolate(frame, [DROP, DROP + 34], [0, 1], { extrapolateRight: 'clamp', easing: Easing.out(Easing.cubic) })
    : 0;
  const badgeIn = frame >= DROP
    ? spring({ frame: frame - DROP, fps, config: { damping: 12, stiffness: 160, mass: 0.9 } })
    : 0;

  // End card + final fade.
  const endIn = frame >= END_CARD
    ? interpolate(frame, [END_CARD, END_CARD + 40], [0, 1], { extrapolateRight: 'clamp', easing: Easing.out(Easing.cubic) })
    : 0;
  const blackout = frame >= FADE_OUT
    ? interpolate(frame, [FADE_OUT, FADE_OUT + FRAMES_PER_BAR - 4], [0, 1], { extrapolateRight: 'clamp', easing: Easing.inOut(Easing.quad) })
    : 0;

  const bg = goldInvert
    ? `linear-gradient(180deg, ${PALE} 0%, ${MID} 60%, ${DEEP} 130%)`
    : INK;

  return (
    <AbsoluteFill style={{ background: bg, justifyContent: 'center', alignItems: 'center' }}>
      <Html5Audio src={staticFile('audio.wav')} />

      {/* breathing gold hearth behind everything (hidden during the gold inversion) */}
      {!goldInvert && (
        <AbsoluteFill style={{
          background: `radial-gradient(ellipse 62% 55% at 50% 46%, rgba(158,117,39,${0.10 + 0.16 * bass + 0.10 * punch}), transparent 70%)`,
        }} />
      )}

      {/* ============ bar 0 — cold open: the wave, mid-scream ============ */}
      {frame < barFrame(1) && (
        <AbsoluteFill style={{ justifyContent: 'center', alignItems: 'center' }}>
          <SoundWave levels={bands} barW={26} maxH={340} gap={30}
            opacity={interpolate(frame, [barFrame(1) - 10, barFrame(1)], [1, 0], { extrapolateLeft: 'clamp' })} />
        </AbsoluteFill>
      )}

      {/* ============ bars 1–6 — the setup (never says the name) ============ */}
      <CopyLine from={barFrame(1)} to={barFrame(3)} size={78}>THEY LAUGHED AT THE NAME.</CopyLine>
      <CopyLine from={barFrame(3)} to={barFrame(5)} size={88}>THE NAME IS A JOKE.</CopyLine>
      <CopyLine from={barFrame(5)} to={barFrame(7)} size={104}>THE APP IS NOT.</CopyLine>

      {/* ============ bar 7 — wind-up: the room holds its breath ============ */}
      {windup !== null && (
        <AbsoluteFill style={{ justifyContent: 'center', alignItems: 'center' }}>
          <div style={{
            width: 520, height: 520, borderRadius: '50%',
            border: `2px solid rgba(229,190,98,${0.5 + 0.5 * windup})`,
            transform: `scale(${1.35 - 1.3 * windup})`,
            boxShadow: `0 0 90px rgba(229,190,98,${0.35 * windup})`,
          }} />
        </AbsoluteFill>
      )}

      {/* ============ bar 8 — THE DROP: the badge ============ */}
      {frame >= DROP && frame < barFrame(9) && (
        <AbsoluteFill style={{ justifyContent: 'center', alignItems: 'center', gap: 34 }}>
          <Img src={staticFile('badge.png')} style={{
            width: 460, height: 460,
            transform: `scale(${1.5 - 0.5 * badgeIn})`,
            opacity: badgeIn,
            filter: `drop-shadow(0 0 ${50 + 90 * punch}px rgba(229,190,98,0.55))`,
          }} />
          <div style={{
            ...goldText, fontFamily: SERIF, fontSize: 96, fontWeight: 400,
            letterSpacing: '0.08em', opacity: badgeIn,
            transform: `translateY(${(1 - badgeIn) * 30}px)`,
          }}>
            andrew dictate
          </div>
        </AbsoluteFill>
      )}

      {/* shockwave ring riding out of the drop */}
      {frame >= DROP && shock < 1 && (
        <AbsoluteFill style={{ justifyContent: 'center', alignItems: 'center' }}>
          <div style={{
            width: 520, height: 520, borderRadius: '50%',
            border: '3px solid rgba(249,233,168,0.9)',
            transform: `scale(${0.1 + shock * 3.2})`,
            opacity: 1 - shock,
          }} />
        </AbsoluteFill>
      )}

      {/* ============ bars 9–15 — the flex (beat-cut feature cards) ============ */}
      <CopyLine from={beatFrame(36)} to={beatFrame(38)} size={110}>HOLD A KEY.</CopyLine>
      <CopyLine from={beatFrame(38)} to={beatFrame(40)} size={110}>TALK.</CopyLine>
      <CopyLine from={beatFrame(40)} to={barFrame(11)} size={110}>GET TEXT.</CopyLine>
      <CopyLine from={barFrame(11)} to={barFrame(12)} size={92}>FULLY LOCAL. ZERO CLOUD.</CopyLine>
      <CopyLine from={barFrame(12)} to={barFrame(13)} size={92}>FREE. OPEN SOURCE.</CopyLine>
      <CopyLine from={barFrame(13)} to={barFrame(14)} size={120}>UNDEFEATED.</CopyLine>
      <CopyLine from={barFrame(14)} to={barFrame(15)} size={64} italic tracking={[0.3, 0.12]}>
        What color is your dictation app?
      </CopyLine>
      <CopyLine from={beatFrame(60)} to={beatFrame(62)} size={170}>BLACK.</CopyLine>

      {/* "AND GOLD." — the inversion: gold room, ink type */}
      {goldInvert && (
        <AbsoluteFill style={{ justifyContent: 'center', alignItems: 'center' }}>
          <div style={{
            fontFamily: SERIF, fontSize: 170, fontWeight: 400, color: INK,
            letterSpacing: '0.14em', paddingLeft: '0.14em',
            transform: `scale(${1 + 0.05 * punch})`,
          }}>
            AND GOLD.
          </div>
        </AbsoluteFill>
      )}

      {/* the HUD wave keeps time under the chorus copy */}
      {inChorus && !goldInvert && (
        <div style={{ position: 'absolute', bottom: 90, left: 0, right: 0, display: 'flex', justifyContent: 'center' }}>
          <SoundWave levels={bands} barW={9} maxH={92} gap={11} opacity={0.85} />
        </div>
      )}

      {/* ============ bars 16–18 — piano outro: the quiet end card ============ */}
      {frame >= END_CARD && (
        <AbsoluteFill style={{
          background: INK, justifyContent: 'center', alignItems: 'center',
          opacity: endIn,
        }}>
          <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 26 }}>
            <Img src={staticFile('badge.png')} style={{
              width: 250, height: 250,
              filter: 'drop-shadow(0 0 40px rgba(229,190,98,0.35))',
            }} />
            <div style={{ ...goldText, fontFamily: SERIF, fontSize: 86, letterSpacing: '0.08em' }}>
              andrew dictate
            </div>
            <div style={{
              fontFamily: SERIF, fontStyle: 'italic', fontSize: 40, color: MID,
              opacity: interpolate(frame, [END_CARD + 30, END_CARD + 60], [0, 1], { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' }),
            }}>
              escape the keyboard.
            </div>
            <div style={{
              fontFamily: SANS, fontSize: 25, fontWeight: 500, color: MID,
              letterSpacing: '0.32em', paddingLeft: '0.32em', marginTop: 16,
              opacity: 0.8 * interpolate(frame, [END_CARD + 55, END_CARD + 85], [0, 1], { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' }),
            }}>
              FREE · OPEN SOURCE · FULLY LOCAL
            </div>
            <div style={{
              fontFamily: SANS, fontSize: 22, fontWeight: 400, color: DEEP,
              letterSpacing: '0.12em', paddingLeft: '0.12em',
              opacity: 0.9 * interpolate(frame, [END_CARD + 70, END_CARD + 100], [0, 1], { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' }),
            }}>
              github.com/jassuwu/andrew-dictate&ensp;·&ensp;made by jass — jass.gg
            </div>
          </div>
        </AbsoluteFill>
      )}

      {/* film vignette */}
      <AbsoluteFill style={{
        background: 'radial-gradient(ellipse 75% 70% at 50% 50%, transparent 55%, rgba(0,0,0,0.5) 100%)',
        pointerEvents: 'none',
      }} />

      {/* flashes above everything */}
      {openFlash > 0 && (
        <AbsoluteFill style={{ background: `radial-gradient(circle at 50% 50%, rgba(249,233,168,${openFlash}), rgba(158,117,39,${openFlash * 0.4}) 65%)` }} />
      )}
      {dropFlash > 0 && (
        <AbsoluteFill style={{ background: `radial-gradient(circle at 50% 50%, rgba(255,246,201,${dropFlash}), transparent 70%)` }} />
      )}

      {/* final fade to black */}
      {blackout > 0 && <AbsoluteFill style={{ background: '#000', opacity: blackout }} />}
    </AbsoluteFill>
  );
};
