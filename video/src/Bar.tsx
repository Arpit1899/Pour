import { useLayoutEffect, useRef } from 'react';
import { useCurrentFrame } from 'remotion';
import { auroraAt, barShapeAt, contentOpacity } from './motion';
import { color, glow, S, t } from './theme';

// PourAurora.fields
const fields = [
  { color: color.ember, speed: 0.33, phase: 0 },
  { color: color.rose, speed: 0.27, phase: 2.1 },
  { color: color.honey, speed: 0.41, phase: 4.2 },
  { color: color.accent, speed: 0.22, phase: 1 },
];

const withAlpha = (hex: string, a: number) => {
  const n = parseInt(hex.slice(1), 16);
  return `rgba(${n >> 16}, ${(n >> 8) & 255}, ${n & 255}, ${a})`;
};

const capsule = (ctx: CanvasRenderingContext2D, x: number, y: number, w: number, h: number) => {
  ctx.beginPath();
  ctx.roundRect(x, y, w, h, Math.min(w, h) / 2);
};

// The capsule, its fill and hairline, and the aurora clipped inside it, in one
// canvas. CSS overflow clipping of a blended child dropped the rounded
// corners in full renders.
const Body: React.FC<{
  w: number;
  h: number;
  fill: number;
  stroke: number;
  live: number;
  level: number;
  clock: number;
}> = ({ w, h, fill, stroke, live, level, clock }) => {
  const ref = useRef<HTMLCanvasElement>(null);
  useLayoutEffect(() => {
    const ctx = ref.current!.getContext('2d')!;
    ctx.clearRect(0, 0, ctx.canvas.width, ctx.canvas.height);
    ctx.save();
    ctx.scale(S, S);
    capsule(ctx, 0, 0, w, h);
    ctx.fillStyle = `rgba(0,0,0,${fill})`;
    ctx.fill();
    if (live > 0) {
      ctx.save();
      capsule(ctx, 0, 0, w, h);
      ctx.clip();
      ctx.globalCompositeOperation = 'lighter';
      ctx.filter = `blur(${6.5 * S}px)`;
      for (const field of fields) {
        const cx = w * (0.5 + 0.48 * Math.sin(clock * field.speed + field.phase));
        const cy = h * (0.5 + 0.25 * Math.sin(clock * field.speed * 1.7 + field.phase));
        const rx = w * 0.32;
        const ry = h * (0.55 + 0.35 * level);
        ctx.fillStyle = withAlpha(field.color, (0.25 + 0.6 * level) * live);
        ctx.beginPath();
        ctx.ellipse(cx, cy, rx, ry, 0, 0, Math.PI * 2);
        ctx.fill();
      }
      ctx.restore();
    }
    capsule(ctx, 0.25, 0.25, w - 0.5, h - 0.5);
    ctx.strokeStyle = `rgba(255,255,255,${stroke})`;
    ctx.lineWidth = 0.5;
    ctx.stroke();
    ctx.restore();
  }, [w, h, fill, stroke, live, level, clock]);
  return (
    <canvas
      ref={ref}
      width={Math.ceil(w * S)}
      height={Math.ceil(h * S)}
      style={{ position: 'absolute', left: 0, top: 0, width: Math.ceil(w * S), height: Math.ceil(h * S) }}
    />
  );
};

// AuroraRim: the glow colors turning at 52° a second, a soft halo outside
// and a fine line on the edge.
const PAD = 16;
const Rim: React.FC<{ w: number; h: number; level: number; seconds: number; opacity: number }> = ({
  w,
  h,
  level,
  seconds,
  opacity,
}) => {
  const ref = useRef<HTMLCanvasElement>(null);
  const W = w + PAD * 2;
  const H = h + PAD * 2;
  useLayoutEffect(() => {
    const ctx = ref.current!.getContext('2d')!;
    ctx.clearRect(0, 0, W * S, H * S);
    ctx.save();
    ctx.scale(S, S);
    const angle = (((200 + seconds * 52) % 360) * Math.PI) / 180;
    const ring = ctx.createConicGradient(angle, PAD + w / 2, PAD + h / 2);
    glow.forEach((c, i) => ring.addColorStop(i / (glow.length - 1), c));
    ctx.globalCompositeOperation = 'lighter';

    ctx.save();
    ctx.globalAlpha = 0.3 + 0.5 * level;
    ctx.filter = `blur(${5 * S}px)`;
    ctx.strokeStyle = ring;
    ctx.lineWidth = 4;
    capsule(ctx, PAD, PAD, w, h);
    ctx.stroke();
    ctx.restore();

    ctx.globalAlpha = 0.55 + 0.4 * level;
    ctx.strokeStyle = ring;
    ctx.lineWidth = 1.2;
    capsule(ctx, PAD + 0.6, PAD + 0.6, w - 1.2, h - 1.2);
    ctx.stroke();
    ctx.restore();
  }, [w, h, W, H, level, seconds]);
  return (
    <canvas
      ref={ref}
      width={Math.ceil(W * S)}
      height={Math.ceil(H * S)}
      style={{
        position: 'absolute',
        left: -PAD * S,
        top: -PAD * S,
        width: W * S,
        height: H * S,
        mixBlendMode: 'plus-lighter',
        opacity,
        pointerEvents: 'none',
      }}
    />
  );
};

const Check: React.FC<{ size: number }> = ({ size }) => (
  <svg width={size} height={size} viewBox="0 0 12 12" style={{ display: 'block' }}>
    <path d="M2 6.4 4.8 9.1 10 2.9" fill="none" stroke="currentColor" strokeWidth={1.7} strokeLinecap="round" strokeLinejoin="round" />
  </svg>
);

export const Bar: React.FC<{ bottom: number }> = ({ bottom }) => {
  const frame = useCurrentFrame();
  const shape = barShapeAt(frame);
  const { level, clock, rim } = auroraAt(frame);
  const live = contentOpacity(frame, t.open, t.paste);
  const pasted = contentOpacity(frame, t.paste, t.collapse);
  const w = shape.w;
  const h = shape.h;

  return (
    <div
      style={{
        position: 'absolute',
        left: '50%',
        bottom,
        width: w * S,
        height: h * S,
        transform: 'translateX(-50%)',
      }}
    >
      <Body w={w} h={h} fill={shape.fill} stroke={shape.stroke} live={live} level={level} clock={clock} />
      {pasted > 0 && (
        <div
          style={{
            position: 'absolute',
            inset: 0,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            gap: 7 * S,
            color: 'rgba(255,255,255,0.9)',
            fontSize: 13 * S,
            opacity: pasted,
            whiteSpace: 'nowrap',
            clipPath: `inset(0 round ${(Math.min(w, h) / 2) * S}px)`,
          }}
        >
          <Check size={11 * S} />
          <span>Pasted</span>
        </div>
      )}
      {live > 0 && <Rim w={w} h={h} level={rim} seconds={frame / 60} opacity={live} />}
    </div>
  );
};
