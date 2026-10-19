import { AbsoluteFill, Easing, Img, interpolate, staticFile, useCurrentFrame } from 'remotion';
import { Bar } from './Bar';
import { bar, color, FPS, S, sentence, t } from './theme';

const sans = '"SF Pro", system-ui, -apple-system, sans-serif';
const serif = '"New York", ui-serif, Georgia, serif';

const easeOut = Easing.out(Easing.cubic);

const fade = (frame: number, from: number, seconds: number) =>
  interpolate(frame, [from, from + seconds * FPS], [0, 1], {
    easing: easeOut,
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });

// Where the Dock's top edge sits; the rest of it is below the frame.
const DOCK_TOP = 1288;

// The macOS insertion point fades in and out rather than snapping, and stays
// solid for a moment after text changes.
const caretOpacity = (frame: number) => {
  const restart = frame >= t.paste ? t.paste : 0;
  const since = (frame - restart) / FPS;
  if (restart && since < 0.5) return 1;
  const period = 1.06;
  const p = ((since - (restart ? 0.5 : 0)) % period) / period;
  const on = 0.5;
  const ramp = 0.08;
  if (p < on) return 1;
  if (p < on + ramp) return 1 - (p - on) / ramp;
  if (p < 1 - ramp) return 0;
  return (p - (1 - ramp)) / ramp;
};

const TrafficLights = () => (
  <div style={{ display: 'flex', gap: 8 * S }}>
    {['#FF5F57', '#FEBC2E', '#28C840'].map((c) => (
      <div
        key={c}
        style={{
          width: 12 * S,
          height: 12 * S,
          borderRadius: '50%',
          background: c,
          boxShadow: `inset 0 0 0 ${0.5 * S}px rgba(0,0,0,0.12)`,
        }}
      />
    ))}
  </div>
);

const Send = () => (
  <svg width={17 * S} height={17 * S} viewBox="0 0 24 24" style={{ display: 'block' }}>
    <path
      d="M4 11.6 20 4.4l-5.6 15.4-3-6.6L4 11.6Zm7.4 1.6L20 4.4"
      fill="none"
      stroke={color.mute}
      strokeWidth={1.5}
      strokeLinejoin="round"
      strokeLinecap="round"
    />
  </svg>
);

const Field: React.FC<{ label: string; value: string }> = ({ label, value }) => (
  <div
    style={{
      display: 'flex',
      gap: 6 * S,
      padding: `${9 * S}px ${20 * S}px`,
      borderBottom: `${0.5 * S}px solid rgba(0,0,0,0.08)`,
      fontSize: 13 * S,
    }}
  >
    <span style={{ color: color.mute }}>{label}</span>
    <span style={{ color: color.ink }}>{value}</span>
  </div>
);

const MailWindow: React.FC<{ frame: number }> = ({ frame }) => {
  const typed = frame >= t.paste;
  return (
    <div
      style={{
        position: 'absolute',
        left: 64,
        right: 64,
        top: 92,
        height: 640,
        borderRadius: 16 * S,
        background: color.canvas,
        boxShadow: `0 ${20 * S}px ${48 * S}px rgba(0,0,0,0.5), 0 0 0 ${0.5 * S}px rgba(0,0,0,0.35)`,
        overflow: 'hidden',
        color: color.ink,
      }}
    >
      <div
        style={{
          height: 52 * S,
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
          padding: `0 ${20 * S}px`,
          borderBottom: `${0.5 * S}px solid rgba(0,0,0,0.08)`,
        }}
      >
        <TrafficLights />
        <span style={{ fontSize: 13 * S, fontWeight: 600 }}>Review</span>
        <Send />
      </div>
      <Field label="To:" value="Maya Chen" />
      <Field label="Subject:" value="Review" />
      <div
        style={{
          padding: `${14 * S}px ${20 * S}px`,
          fontSize: 14 * S,
          lineHeight: 1.45,
          letterSpacing: '-0.01em',
        }}
      >
        {typed ? sentence : null}
        <span
          style={{
            display: 'inline-block',
            width: 2 * S,
            height: 17 * S,
            marginLeft: typed ? 1 * S : 0,
            borderRadius: 1 * S,
            background: '#F7821B',
            verticalAlign: -3.5 * S,
            opacity: caretOpacity(frame),
          }}
        />
      </div>
    </div>
  );
};

// HoldableKeys from ContentView.swift, in its dark appearance: grey caps at
// rest, amber while recording, 0.97 scale while pressed.
const Keys: React.FC<{ frame: number }> = ({ frame }) => {
  const shown = fade(frame, t.keysIn, 0.25) * (1 - fade(frame, t.keysOut, 0.3));
  const down = frame >= t.press && frame < t.release;
  const pressAt = down ? t.press : t.release;
  const pressP = fade(frame, pressAt, 0.12);
  const scale = down ? 1 - 0.03 * pressP : 0.97 + 0.03 * (frame >= t.release ? pressP : 1);
  const recP = fade(frame, pressAt, 0.18);
  const rec = down ? recP : frame >= t.release ? 1 - recP : 0;
  const mix = (a: number, b: number) => a + (b - a) * rec;
  return (
    <div
      style={{
        position: 'absolute',
        left: 64,
        top: 812,
        display: 'flex',
        gap: 7 * S,
        opacity: shown,
        transform: `scale(${scale})`,
        transformOrigin: 'left center',
      }}
    >
      {['⌃', 'Space'].map((cap) => (
        <div
          key={cap}
          style={{
            minWidth: 42 * S,
            height: 36 * S,
            padding: `0 ${13 * S}px`,
            borderRadius: 9 * S,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            fontSize: 15 * S,
            fontWeight: 500,
            color: `rgb(${mix(242, 232)}, ${mix(241, 163)}, ${mix(238, 61)})`,
            background: `rgba(${mix(65, 232)}, ${mix(65, 163)}, ${mix(67, 61)}, ${mix(1, 0.16)})`,
            boxShadow: `inset 0 0 0 ${0.5 * S}px rgba(${mix(255, 232)}, ${mix(255, 163)}, ${mix(255, 61)}, ${mix(0.08, 0.5)}), 0 ${S}px 0 rgba(0,0,0,${0.06 * (1 - rec)})`,
          }}
        >
          {cap}
        </div>
      ))}
    </div>
  );
};

const Mark: React.FC<{ size: number }> = ({ size }) => (
  <Img src={staticFile('mark.svg')} style={{ width: size, height: size, display: 'block' }} />
);

const End: React.FC<{ frame: number }> = ({ frame }) => {
  const shown = fade(frame, t.end, 0.4);
  return (
    <div style={{ position: 'absolute', left: 64, top: 800, opacity: shown, color: color.cream }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 4 * S, marginLeft: -6 * S }}>
        <Mark size={36 * S} />
        <div style={{ fontSize: 28 * S, letterSpacing: '-0.013em', lineHeight: 1 }}>
          pour<span style={{ color: color.accent }}>.</span>
        </div>
      </div>
      <div
        style={{
          fontFamily: serif,
          fontSize: 15.5 * S,
          lineHeight: 1.3,
          color: 'rgba(244,238,228,0.75)',
          marginTop: 8 * S,
        }}
      >
        Push-to-talk dictation for the Mac.
        <br />
        Free, open source, on-device.
      </div>
    </div>
  );
};

const Dock = () => (
  <div
    style={{
      position: 'absolute',
      left: 150,
      right: 150,
      top: DOCK_TOP,
      height: 200,
      borderRadius: 26 * S,
      background: 'rgba(255,255,255,0.07)',
      boxShadow: `inset 0 0 0 ${0.5 * S}px rgba(255,255,255,0.16), inset 0 ${S}px 0 rgba(255,255,255,0.08)`,
    }}
  />
);

export const PourVideo: React.FC = () => {
  const frame = useCurrentFrame();
  return (
    <AbsoluteFill
      style={{
        background: `radial-gradient(130% 70% at 50% 108%, #3A2716 0%, ${color.espresso} 62%)`,
        fontFamily: sans,
        WebkitFontSmoothing: 'antialiased',
      }}
    >
      <MailWindow frame={frame} />
      <Keys frame={frame} />
      <End frame={frame} />
      <Dock />
      <Bar bottom={1350 - DOCK_TOP + bar.lift * S} />
    </AbsoluteFill>
  );
};
