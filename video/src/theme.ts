// Values from Pour/PourTheme.swift, Pour/PourHUD.swift and Pour/PourSession.swift.

export const color = {
  accent: '#E8A33D',
  foam: '#F6D39C',
  ember: '#E46A3A',
  rose: '#EC8B78',
  honey: '#F4C44E',
  espresso: '#1B1613',
  cream: '#F4EEE4',
  canvas: '#FCFBF9',
  ink: '#1D1D1F',
  mute: '#6E6B66',
};

export const glow = [color.accent, color.ember, color.rose, color.honey, color.foam, color.accent];

export const FPS = 60;
export const WIDTH = 1080;
export const HEIGHT = 1350;
export const DURATION = 600;

// Pixels per point. The frame is a close crop of a Retina screen.
export const S = 2.8;

export const bar = {
  rest: { w: 40, h: 8 },
  live: { w: 150, h: 34 },
  pasted: { w: 96, h: 34 },
  lift: 10,
};

// SwiftUI .spring(response: 0.38, dampingFraction: 0.78) as mass, stiffness, damping.
const response = 0.38;
const dampingFraction = 0.78;
const omega = (2 * Math.PI) / response;
export const barSpring = { mass: 1, stiffness: omega * omega, damping: 2 * dampingFraction * omega };

const f = (seconds: number) => Math.round(seconds * FPS);

export const t = {
  keysIn: f(0.75),
  press: f(1.15),
  open: f(1.15) + 1,
  speech: f(1.45),
  release: f(5.25),
  polish: f(5.25),
  paste: f(5.85),
  collapse: f(5.85 + 0.22),
  keysOut: f(6.3),
  end: f(6.9),
};

export const sentence = "Can we move the review to Thursday? I'd like the team to see the new numbers first.";
