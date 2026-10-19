import { spring } from 'remotion';
import envelope from './envelope.json';
import { bar, barSpring, DURATION, FPS, t } from './theme';

export type Mode = 'rest' | 'wave' | 'thinking' | 'pasted';

export const modeAt = (frame: number): Mode => {
  if (frame < t.open) return 'rest';
  if (frame < t.polish) return 'wave';
  if (frame < t.paste) return 'thinking';
  if (frame < t.collapse) return 'pasted';
  return 'rest';
};

// The envelope is the mean absolute sample per frame of the sentence read by
// `say`, louder than a laptop mic hears a voice, so it is turned down to a
// level a real dictation reaches.
const GAIN = 0.7;

// What VoiceRecorderService reports: mean absolute sample, zero once the
// recorder stops at release.
const audioLevel = (frame: number) => {
  if (frame >= t.release) return 0;
  const i = frame - t.speech;
  if (i < 0 || i >= envelope.length) return 0;
  return envelope[i] * GAIN;
};

// PourBar.level: louder speech reads as a bigger change than the raw level.
const barLevel = (frame: number) => Math.sqrt(Math.min(1, audioLevel(frame)));

// PourAurora and AuroraRim, stepped once per frame from the moment the bar
// opens, the same way their TimelineView would step them.
const steps = (() => {
  const level: number[] = new Array(DURATION).fill(0);
  const clock: number[] = new Array(DURATION).fill(0);
  const rim: number[] = new Array(DURATION).fill(0);
  let l = 0;
  let c = 0;
  let r = 0;
  const dt = 1 / FPS;
  for (let frame = t.open; frame < DURATION; frame++) {
    const thinking = modeAt(frame) === 'thinking';
    const first = frame === t.open;
    const target = thinking ? 0.2 : Math.max(0.12, barLevel(frame));
    if (!first) {
      l += (target - l) * (1 - Math.exp(-dt * 10));
      c += dt * (thinking ? 3 : 1);
    }
    // .animation(.easeOut(duration: 0.18), value: level) on the rim.
    const rimTarget = thinking ? 0.2 : barLevel(frame);
    r += (rimTarget - r) * (1 - Math.exp(-dt / 0.06));
    level[frame] = l;
    clock[frame] = c;
    rim[frame] = r;
  }
  return { level, clock, rim };
})();

export const auroraAt = (frame: number) => ({
  level: steps.level[frame] ?? 0,
  clock: steps.clock[frame] ?? 0,
  rim: steps.rim[frame] ?? 0,
});

type BarShape = { w: number; h: number; fill: number; stroke: number };

const shapeFor = (mode: Mode): BarShape => {
  switch (mode) {
    case 'rest':
      return { ...bar.rest, fill: 0.4, stroke: 0.3 };
    case 'pasted':
      return { ...bar.pasted, fill: 0.9, stroke: 0.1 };
    default:
      return { ...bar.live, fill: 0.9, stroke: 0.1 };
  }
};

const changes = [0, t.open, t.paste, t.collapse];

const progress = (frame: number, since: number) =>
  spring({ frame: frame - since, fps: FPS, config: barSpring });

const lerp = (a: BarShape, b: BarShape, p: number): BarShape => ({
  w: a.w + (b.w - a.w) * p,
  h: a.h + (b.h - a.h) * p,
  fill: a.fill + (b.fill - a.fill) * p,
  stroke: a.stroke + (b.stroke - a.stroke) * p,
});

// Each change springs from wherever the previous one had got to, as SwiftUI
// retargets an animation that is still running.
export const barShapeAt = (frame: number): BarShape => {
  let start = shapeFor('rest');
  let target = start;
  let since = 0;
  for (const at of changes.slice(1)) {
    if (frame < at) break;
    start = lerp(start, target, progress(at, since));
    target = shapeFor(modeAt(at));
    since = at;
  }
  return lerp(start, target, progress(frame, since));
};

// Content inside the bar cross-fades with the same spring.
export const contentOpacity = (frame: number, from: number, to: number) => {
  if (frame < from) return 0;
  const shown = Math.min(1, progress(frame, from));
  if (frame < to) return shown;
  return Math.max(0, shown * (1 - Math.min(1, progress(frame, to))));
};
