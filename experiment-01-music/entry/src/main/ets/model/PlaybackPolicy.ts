export enum PlayMode {
  Sequential,
  Random,
  SingleRepeat
}

export function nextTrackIndex(current: number, count: number, mode: PlayMode,
  manual: boolean, randomValue: number = Math.random()): number {
  if (count <= 0) {
    return -1;
  }
  if (current < 0 || current >= count) {
    return 0;
  }
  if (mode === PlayMode.SingleRepeat && !manual) {
    return current;
  }
  if (mode === PlayMode.Random && count > 1) {
    const boundedRandom = Number.isFinite(randomValue) ? Math.max(0, Math.min(randomValue, 1)) : 0;
    const candidate = Math.min(Math.floor(boundedRandom * (count - 1)), count - 2);
    return candidate >= current ? candidate + 1 : candidate;
  }
  if (current + 1 < count) {
    return current + 1;
  }
  return manual || mode !== PlayMode.Sequential ? 0 : -1;
}

export function previousTrackIndex(current: number, count: number): number {
  if (count <= 0) {
    return -1;
  }
  if (current < 0 || current >= count) {
    return 0;
  }
  return (current + count - 1) % count;
}

export function formatTime(ms: number): string {
  const seconds = Number.isFinite(ms) ? Math.floor(Math.max(0, ms) / 1000) : 0;
  const minutes = Math.floor(seconds / 60);
  const remainder = seconds % 60;
  return `${minutes}:${remainder < 10 ? '0' : ''}${remainder}`;
}
