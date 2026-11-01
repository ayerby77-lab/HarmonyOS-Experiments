export interface Track {
  id: string;
  title: string;
  artist: string;
  album: string;
  cover: Resource | string;
  path?: string;
  fileName?: string;
  duration?: number;
  resource: string;
}

// Demonstration metadata for the original synthesized audio packaged with the app.
export const DEMO_TRACKS: Track[] = [
  { id: 'morning', title: '晨光', artist: 'MusicApp 合成音乐', album: '晨间来信',
    cover: $r('app.media.cover_morning'), resource: 'morning.wav' },
  { id: 'breeze', title: '微风', artist: 'MusicApp 合成音乐', album: '风的旅行',
    cover: $r('app.media.cover_breeze'), resource: 'breeze.wav' },
  { id: 'night', title: '夜色', artist: 'MusicApp 合成音乐', album: '晚安电台',
    cover: $r('app.media.cover_night'), resource: 'night.wav' }
];
