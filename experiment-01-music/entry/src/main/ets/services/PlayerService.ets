import { fileIo as fs } from '@kit.CoreFileKit';
import { media } from '@kit.MediaKit';
import { audio } from '@kit.AudioKit';
import { resourceManager } from '@kit.LocalizationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Track } from '../model/Track';
import { PlayMode, nextTrackIndex, previousTrackIndex } from '../model/PlaybackPolicy';

export class PlayerSnapshot {
  track: Track | undefined = undefined;
  index: number = 0;
  position: number = 0;
  duration: number = 0;
  volume: number = 0.6;
  mode: PlayMode = PlayMode.Sequential;
  playing: boolean = false;
  ready: boolean = false;
  busy: boolean = false;
  error: string = '';
  status: string = '准备就绪';
}

// All player commands share one queue. A resource descriptor stays open until release.
export class PlayerService {
  private player: media.AVPlayer | undefined = undefined;
  private openedResource: string = '';
  private openedFile: fs.File | undefined = undefined;
  private state: PlayerSnapshot = new PlayerSnapshot();
  private commands: Promise<void> = Promise.resolve();
  private pending: number = 0;
  private disposed: boolean = false;
  private ducked: boolean = false;

  private resources: resourceManager.ResourceManager;
  private tracks: Track[];
  private listener: (snapshot: PlayerSnapshot) => void;

  constructor(resources: resourceManager.ResourceManager,
    tracks: Track[], listener: (snapshot: PlayerSnapshot) => void) {
    this.resources = resources;
    this.tracks = tracks;
    this.listener = listener;
  }

  private emit(): void {
    if (this.disposed) { return; }
    const snapshot = new PlayerSnapshot();
    snapshot.index = this.state.index;
    snapshot.track = this.tracks[this.state.index];
    snapshot.position = this.state.position;
    snapshot.duration = this.state.duration;
    snapshot.volume = this.state.volume;
    snapshot.mode = this.state.mode;
    snapshot.playing = this.state.playing;
    snapshot.ready = this.state.ready;
    snapshot.busy = this.pending > 0;
    snapshot.error = this.state.error;
    snapshot.status = this.state.status;
    this.listener(snapshot);
  }

  private report(error: BusinessError): void {
    this.state.error = `播放失败（${error.code ?? 0}）：${error.message}`;
    this.state.status = '请点击重试或选择其他曲目';
    this.state.playing = false;
    this.state.ready = false;
    hilog.error(0x0000, 'MusicApp', '%{public}s', this.state.error);
    this.emit();
  }

  private enqueue(operation: () => Promise<void>): void {
    if (this.disposed) { return; }
    this.pending++;
    this.emit();
    this.commands = this.commands.then(async () => {
      if (!this.disposed) { await operation(); }
    }).catch((error: BusinessError) => {
      this.report(error);
    }).finally(() => {
      this.pending--;
      this.emit();
    });
  }

  initialize(): void {
    this.enqueue(async () => { await this.load(0, false); });
  }

  setQueue(tracks: Track[], index: number = 0, autoplay: boolean = true): void {
    const queue = tracks.slice();
    this.enqueue(async () => {
      if (queue.length === 0 || index < 0 || index >= queue.length) { return; }
      this.tracks = queue;
      this.state.index = index;
      await this.load(index, autoplay);
    });
  }

  select(index: number): void {
    this.enqueue(async () => { await this.load(index, true); });
  }

  toggle(): void {
    this.enqueue(async () => {
      const player = this.player;
      if (!player || this.state.error.length > 0) {
        await this.load(this.state.index, true);
      } else if (player.state === 'playing') {
        await player.pause();
      } else if (player.state === 'prepared' || player.state === 'paused' || player.state === 'completed') {
        await player.play();
      }
    });
  }

  pause(): void {
    this.enqueue(async () => {
      if (this.player?.state === 'playing') { await this.player.pause(); }
    });
  }

  next(manual: boolean = true): void {
    this.enqueue(async () => {
      const index = nextTrackIndex(this.state.index, this.tracks.length, this.state.mode, manual);
      if (index >= 0) { await this.load(index, true); }
    });
  }

  previous(): void {
    this.enqueue(async () => {
      const index = previousTrackIndex(this.state.index, this.tracks.length);
      if (index >= 0) { await this.load(index, true); }
    });
  }

  seek(position: number): void {
    this.enqueue(async () => {
      const player = this.player;
      if (!player || !this.state.ready) { return; }
      // seekDone, rather than an estimated timer, confirms the visible position.
      player.seek(Math.max(0, Math.min(Math.round(position), this.state.duration)));
    });
  }

  setVolume(percent: number): void {
    this.state.volume = Math.max(0, Math.min(1, percent / 100));
    try {
      if (this.player && this.state.ready) {
        this.player.setVolume(this.state.volume * (this.ducked ? 0.2 : 1));
      }
    } catch (error) { this.report(error as BusinessError); }
    this.emit();
  }

  cycleMode(): void {
    this.state.mode = (this.state.mode + 1) % 3;
    this.emit();
  }

  private async releaseCurrent(): Promise<void> {
    const player = this.player;
    this.player = undefined;
    if (player) {
      player.off('stateChange');
      player.off('timeUpdate');
      player.off('durationUpdate');
      player.off('seekDone');
      player.off('error');
      player.off('audioInterrupt');
      await player.release();
    }
    if (this.openedFile) {
      await fs.close(this.openedFile);
      this.openedFile = undefined;
    }
    if (this.openedResource.length > 0) {
      await this.resources.closeRawFd(this.openedResource);
      this.openedResource = '';
    }
  }

  private async load(index: number, autoplay: boolean): Promise<void> {
    if (index < 0 || index >= this.tracks.length) { return; }
    this.state.ready = false;
    this.state.playing = false;
    this.state.error = '';
    this.state.status = '正在加载';
    this.state.position = 0;
    this.state.duration = 0;
    this.emit();
    await this.releaseCurrent();
    if (this.disposed) { return; }
    this.state.index = index;
    this.ducked = false;
    const player = await media.createAVPlayer();
    this.player = player;
    const track = this.tracks[index];
    let descriptor: media.AVFileDescriptor;
    if (track.path) {
      this.openedFile = await fs.open(track.path, fs.OpenMode.READ_ONLY);
      const stat = await fs.stat(this.openedFile.fd);
      descriptor = { fd: this.openedFile.fd, offset: 0, length: stat.size };
    } else {
      descriptor = await this.resources.getRawFd(track.resource);
      this.openedResource = track.resource;
    }
    player.on('timeUpdate', (time: number) => {
      this.state.position = Math.max(0, time);
      this.emit();
    });
    player.on('durationUpdate', (duration: number) => {
      this.state.duration = Math.max(0, duration);
      this.emit();
    });
    player.on('seekDone', (position: number) => {
      this.state.position = Math.max(0, position);
      this.emit();
    });
    player.on('audioInterrupt', (event: audio.InterruptEvent) => {
      if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_PAUSE ||
        event.hintType === audio.InterruptHint.INTERRUPT_HINT_STOP) {
        this.pause();
      } else if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_DUCK ||
        event.hintType === audio.InterruptHint.INTERRUPT_HINT_UNDUCK) {
        this.ducked = event.hintType === audio.InterruptHint.INTERRUPT_HINT_DUCK;
        this.setVolume(this.state.volume * 100);
      }
    });
    await new Promise<void>((resolve, reject) => {
      const timeout = setTimeout(() => { reject(new Error('音频加载超时，请重试')); }, 10000);
      player.on('error', (error: BusinessError) => {
        clearTimeout(timeout);
        this.report(error);
        reject(error);
      });
      player.on('stateChange', (state: media.AVPlayerState) => {
        if (state === 'initialized') {
          clearTimeout(timeout);
          resolve();
        }
        this.state.playing = state === 'playing';
        this.state.ready = state === 'prepared' || state === 'playing' || state === 'paused' || state === 'completed';
        if (state === 'playing') { this.state.status = '正在播放'; }
        if (state === 'paused') { this.state.status = '已暂停'; }
        if (state === 'prepared') { this.state.status = '准备就绪'; }
        if (state === 'completed') {
          this.state.status = '播放结束';
          this.state.position = this.state.duration;
          this.next(false);
        }
        this.emit();
      });
      player.fdSrc = { fd: descriptor.fd, offset: descriptor.offset, length: descriptor.length };
    });
    if (this.disposed) { return; }
    await player.prepare();
    this.state.duration = Math.max(0, player.duration);
    player.setVolume(this.state.volume);
    if (autoplay && !this.disposed) { await player.play(); }
    this.emit();
  }

  dispose(): void {
    this.disposed = true;
    this.commands = this.commands.then(async () => {
      await this.releaseCurrent();
    }).catch((error: BusinessError) => {
      hilog.error(0x0000, 'MusicApp', 'Release failed: %{public}s', error.message);
    });
  }
}
