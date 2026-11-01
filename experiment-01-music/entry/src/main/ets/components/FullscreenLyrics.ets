import { Track } from '../model/Track';
import { LyricLine } from '../model/Lyrics';
import { LyricsView } from './LyricsView';

const SAFE_TOP_VP: number = 44;
const SAFE_BOTTOM_VP: number = 24;

@Component
export struct FullscreenLyrics {
  @Prop track: Track | undefined = undefined;
  @Prop currentMs: number = 0;
  @Prop totalMs: number = 0;
  @Prop lines: LyricLine[] = [];
  @Prop label: string = '';
  @Prop loading: boolean = false;
  @Prop coverFailed: boolean = false;
  // Tapping the lyrics body toggles play/pause. Wired by Index.ets to service.toggle().
  onLyricsTap: () => void = () => {};
  @Link visible: boolean;

  private static pad(value: number): string {
    if (!Number.isFinite(value)) { return '00'; }
    const number: number = Math.max(0, Math.floor(value));
    return number < 10 ? '0' + number : '' + number;
  }

  private formatClock(ms: number): string {
    const total: number = Math.max(0, Math.floor((Number.isFinite(ms) ? ms : 0) / 1000));
    const minutes: number = Math.floor(total / 60);
    const seconds: number = total % 60;
    return `${FullscreenLyrics.pad(minutes)}:${FullscreenLyrics.pad(seconds)}`;
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (!this.visible) {
        Blank().width(0).height(0)
      } else {
        this.coverLayer()
        this.gradientLayer()
        this.contentLayer()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#101523')
    .expandSafeArea([SafeAreaType.SYSTEM])
  }

  @Builder
  private coverLayer() {
    if (this.coverFailed || !this.track) {
      Column().width('100%').height('100%').backgroundColor('#7B1416')
    } else {
      Image(this.track.cover)
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
        .blur(48)
        .scale({ x: 1.18, y: 1.18 })
        .zIndex(0)
    }
  }

  @Builder
  private gradientLayer() {
    Column()
      .width('100%')
      .height('100%')
      .linearGradient({
        angle: 180,
        colors: [
          ['rgba(16,21,35,0.55)', 0.0],
          ['rgba(16,21,35,0.78)', 0.55],
          ['rgba(16,21,35,0.92)', 1.0]
        ]
      })
      .zIndex(1)
  }

  @Builder
  private contentLayer() {
    Column() {
      this.headerBar()
      // Lyrics body is its own Column so taps here don't bubble into the header.
      Column() {
        LyricsView({
          currentMs: this.currentMs,
          lines: this.lines,
          label: this.label,
          loading: this.loading,
          activeColor: '#FFFFFF',
          inactiveColor: 'rgba(255,255,255,0.55)',
          activeSize: 38,
          inactiveSize: 17,
          showContext: true
        })
          .layoutWeight(1)
          .width('100%')
          .padding({ left: 28, right: 28 })
      }
      .layoutWeight(1)
      .width('100%')
      .onClick(() => { this.onLyricsTap(); })
    }
    .width('100%')
    .height('100%')
    .padding({ top: SAFE_TOP_VP, bottom: SAFE_BOTTOM_VP })
    .zIndex(2)
  }

  @Builder
  private headerBar() {
    Row() {
      Button('← 退出歌词')
        .fontSize(15).height(40)
        .backgroundColor('rgba(255,255,255,0.22)')
        .fontColor('#FFFFFF')
        .borderRadius(20)
        .padding({ left: 16, right: 16 })
        .onClick(() => { this.visible = false; })
      Blank().layoutWeight(1)
      Text(`${this.formatClock(this.currentMs)} / ${this.formatClock(this.totalMs)}`)
        .fontSize(20)
        .fontColor('#FFFFFF')
        .fontWeight(FontWeight.Bold)
        .maxLines(1)
      Blank().layoutWeight(1)
      Text(this.label.length > 0 ? this.label : '歌词')
        .fontSize(13)
        .fontColor('rgba(255,255,255,0.85)')
        .padding({ left: 12, right: 12 })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .zIndex(2)
  }
}
