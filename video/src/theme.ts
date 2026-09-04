export const COLORS = {
  ink: '#071312',
  inkSoft: '#102422',
  emerald: '#2bd9a3',
  aqua: '#65e7ff',
  violet: '#9b7cff',
  gold: '#f2c96d',
  cream: '#f5f1e8',
  muted: '#9db5b0',
  danger: '#ff7b86',
};

export const FPS = 30;
export const WIDTH = 1920;
export const HEIGHT = 1080;

export const DURATIONS = {
  intro: 8 * FPS,
  problem: 24 * FPS,
  architecture: 30 * FPS,
  console: 133 * FPS,
  evidence: 25 * FPS,
  impact: 22 * FPS,
  closing: 23 * FPS,
} as const;

export const TOTAL_FRAMES = Object.values(DURATIONS).reduce((sum, value) => sum + value, 0);
