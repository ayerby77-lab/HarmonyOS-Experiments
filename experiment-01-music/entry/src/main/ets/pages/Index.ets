import { BusinessError } from '@kit.BasicServicesKit';
import { LocalLibrary, searchTracks } from '../services/LocalLibrary';
import { PlaylistStore, Playlist } from '../services/PlaylistStore';
import { LyricsStore, LyricsSource } from '../services/LyricsStore';
import { common } from '@kit.AbilityKit';
import { DEMO_TRACKS, Track } from '../model/Track';
import { formatTime } from '../model/PlaybackPolicy';
import { LyricLine, parseLrc } from '../model/Lyrics';
import { PlayerService, PlayerSnapshot } from '../services/PlayerService';
import { VoiceService } from '../services/VoiceService';
import { parseCommand, VoiceCommand } from '../model/CommandParser';
import { FullscreenLyrics } from '../components/FullscreenLyrics';

@Entry
@Component
struct Index {
  @State private playback: PlayerSnapshot = new PlayerSnapshot();
  @State private coverFailed: boolean = false;
  @State private dragging: boolean = false;
  @State private dragPosition: number = 0;
  @State private tab: number = 0;
  @State private libraryTracks: Track[] = [];
  @State private queue: Track[] = DEMO_TRACKS;
  @State private search: string = '';
  @State private playlists: Playlist[] = [];
  @State private selectedPlaylist: number = -1;
  @State private playlistTracks: Track[] = [];
  @State private playlistName: string = '';
  @State private pendingTrack: Track | undefined = undefined;
  @State private working: boolean = true;
  @State private storeReady: boolean = false;
  @State private message: string = '正在读取本地音乐…';
  @State private lyricsLines: LyricLine[] = [];
  @State private lyricsLabel: string = '';
  @State private lyricsLoading: boolean = false;
  @Watch('onLyricsVisibleChange') @State private lyricsVisible: boolean = false;
  @State private lyricsTrackId: string = '';
  @State private voiceListening: boolean = false;
  @State private voiceHint: string = '';
  private library: LocalLibrary | undefined = undefined;
  private store: PlaylistStore = new PlaylistStore();
  private lyricsStore: LyricsStore | undefined = undefined;
  private alive: boolean = true;
  private service: PlayerService | undefined = undefined;
  private voice: VoiceService | undefined = undefined;
  private lyricsRequestToken: number = 0;
  private modeLabels: string[] = ['顺序播放', '随机播放', '单曲循环'];

  aboutToAppear(): void {
    this.alive = true;
    this.initialize();
  }

  private async initialize(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.library = new LocalLibrary(context);
    try {
      await this.store.initialize(context);
      this.storeReady = true;
      this.playlists = await this.store.list();
    } catch (error) {
      this.message = `歌单数据库打开失败：${(error as BusinessError).message}`;
    }
    try {
      this.libraryTracks = await this.library.scan();
      if (this.storeReady) {
        this.message = this.library.warnings.length > 0 ? this.library.warnings.join('；') : `已读取 ${this.libraryTracks.length} 首本地音乐`;
      }
    } catch (error) {
      this.message = `音乐库读取失败：${(error as BusinessError).message}`;
    }
    if (!this.alive) { await this.store.close(); return; }
    this.queue = this.libraryTracks.length > 0 ? this.libraryTracks : DEMO_TRACKS;
    this.lyricsStore = new LyricsStore(context);
    this.voice = new VoiceService(context);
    this.service = new PlayerService(context.resourceManager, this.queue, (snapshot: PlayerSnapshot) => {
      if (snapshot.track?.id !== this.playback.track?.id) { this.coverFailed = false; }
      this.playback = snapshot;
      if (snapshot.busy) { this.dragging = false; }
      this.refreshLyrics(snapshot.track);
    });
    this.service.initialize();
    this.working = false;
  }

  private async refreshLyrics(track: Track | undefined): Promise<void> {
    if (!this.lyricsStore || !track) {
      this.lyricsLines = [];
      this.lyricsLabel = '暂无歌词';
      this.lyricsLoading = false;
      return;
    }
    if (track.id === this.lyricsTrackId) { return; }
    const token: number = ++this.lyricsRequestToken;
    this.lyricsTrackId = track.id;
    this.lyricsLoading = true;
    this.lyricsLines = [];
    try {
      const source: LyricsSource = await this.lyricsStore.load(track);
      if (token !== this.lyricsRequestToken) { return; }
      this.lyricsLines = parseLrc(source.text, track.duration || 0);
      this.lyricsLabel = this.lyricsLines.length > 0 ? source.label : '暂无歌词';
    } catch (error) {
      if (token !== this.lyricsRequestToken) { return; }
      this.lyricsLines = [];
      this.lyricsLabel = '暂无歌词';
    } finally {
      if (token === this.lyricsRequestToken) { this.lyricsLoading = false; }
    }
  }

  private toggleLyrics(): void {
    if (this.playback.busy) { return; }
    this.lyricsVisible = !this.lyricsVisible;
  }

  private currentTrack(): Track {
    return this.playback.track ?? this.queue[0] ?? DEMO_TRACKS[0];
  }

  private async refreshLibrary(importFiles: boolean): Promise<void> {
    if (!this.library || this.working) { return; }
    this.working = true;
    try {
      this.libraryTracks = importFiles ? await this.library.importFiles() : await this.library.scan();
      this.message = this.library.warnings.length > 0 ? this.library.warnings.join('；') : `已读取 ${this.libraryTracks.length} 首本地音乐`;
    } catch (error) { this.message = `读取失败：${(error as BusinessError).message}`; }
    finally { this.working = false; }
  }

  private playTracks(tracks: Track[], track: Track): void {
    if (this.playback.busy || this.working || tracks.length === 0) { return; }
    this.queue = tracks.slice();
    this.service?.setQueue(this.queue, this.queue.findIndex((item: Track) => item.id === track.id));
    this.tab = 0;
  }

  // Voice-driven dispatch: ask Speech Kit for recognized text, then map it to
  // a PlayerService method. playSong searches the local library + current queue.
  private async startVoice(): Promise<void> {
    if (!this.voice || this.voiceListening) { return; }
    this.voiceListening = true;
    this.voiceHint = '正在聆听…';
    try {
      const text: string = await this.voice.listen();
      const command: VoiceCommand = parseCommand(text);
      let message: string;
      switch (command.type) {
        case 'pause':
          this.service?.pause();
          message = `已暂停（${text}）`;
          break;
        case 'resume':
          if (!this.playback.playing) { this.service?.toggle(); }
          message = `继续播放（${text}）`;
          break;
        case 'next':
          this.service?.next();
          message = `下一首（${text}）`;
          break;
        case 'previous':
          this.service?.previous();
          message = `上一首（${text}）`;
          break;
        case 'playSong': {
          const pool: Track[] = this.libraryTracks.length > 0 ? this.libraryTracks : this.queue;
          const matches: Track[] = searchTracks(pool, command.query);
          if (matches.length === 0) {
            message = `没有找到「${command.query}」`;
          } else {
            this.playTracks(matches, matches[0]);
            message = `正在播放「${matches[0].title}」`;
          }
          break;
        }
        default:
          message = text.length > 0 ? `未识别指令：${text}` : '没有听到声音';
          break;
      }
      this.voiceHint = message;
      this.message = message;
    } catch (error) {
      this.voiceHint = `语音识别失败：${(error as BusinessError).message}`;
    } finally {
      this.voiceListening = false;
    }
  }

  private async updatePlaylists(): Promise<void> {
    this.playlists = await this.store.list();
    if (this.selectedPlaylist >= 0) { this.playlistTracks = await this.store.tracks(this.selectedPlaylist); }
  }

  private async createPlaylist(): Promise<void> {
    if (this.working || !this.storeReady) { return; }
    this.working = true;
    try {
      await this.store.create(this.playlistName);
      this.playlistName = '';
      await this.updatePlaylists();
      this.message = '歌单已创建';
    } catch (error) { this.message = (error as BusinessError).message; }
    finally { this.working = false; }
  }

  private async openPlaylist(id: number): Promise<void> {
    if (this.working) { return; }
    this.working = true;
    try {
      const tracks = await this.store.tracks(id);
      this.selectedPlaylist = id;
      this.playlistTracks = tracks;
      this.message = `歌单共 ${tracks.length} 首歌曲`;
    } catch (error) { this.message = (error as BusinessError).message; }
    finally { this.working = false; }
  }

  private async addToPlaylist(id: number): Promise<void> {
    if (!this.pendingTrack || this.working) { return; }
    this.working = true;
    try {
      await this.store.addTrack(id, this.pendingTrack);
      await this.updatePlaylists();
      this.pendingTrack = undefined;
      this.message = '已加入歌单，重复歌曲会自动合并';
    } catch (error) { this.message = (error as BusinessError).message; }
    finally { this.working = false; }
  }

  private async removeFromPlaylist(track: Track): Promise<void> {
    if (this.working) { return; }
    this.working = true;
    try {
      await this.store.removeTrack(this.selectedPlaylist, track.id);
      await this.updatePlaylists();
      this.message = '已从歌单移除，原音频保留';
    } catch (error) { this.message = (error as BusinessError).message; }
    finally { this.working = false; }
  }

  private confirmRemovePlaylist(playlist: Playlist): void {
    this.getUIContext().showAlertDialog({ title: '删除歌单',
      message: `删除“${playlist.name}”？原音频文件会保留。`,
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '删除', action: () => { this.removePlaylist(playlist.id); } } });
  }

  private async removePlaylist(id: number): Promise<void> {
    if (this.working) { return; }
    this.working = true;
    try {
      await this.store.remove(id);
      if (this.selectedPlaylist === id) { this.selectedPlaylist = -1; this.playlistTracks = []; }
      await this.updatePlaylists();
      this.message = '歌单已删除';
    } catch (error) { this.message = (error as BusinessError).message; }
    finally { this.working = false; }
  }

  onPageHide(): void {
    this.service?.pause();
  }

  private onLyricsVisibleChange(): void {
    if (!this.lyricsVisible) {
      this.dragging = false;
    }
  }

  onBackPress(): boolean {
    if (this.lyricsVisible) {
      this.lyricsVisible = false;
      this.dragging = false;
      return true;
    }
    return false;
  }

  aboutToDisappear(): void {
    this.alive = false;
    this.store.close().catch(() => {});
    this.voice?.dispose();
    this.voice = undefined;
    this.service?.dispose();
    this.service = undefined;
  }

  @Builder
  playerView() {
    Scroll() {
      Column({ space: 22 }) {
        Column({ space: 6 }) {
          Text('音乐播放器').fontSize(26).fontWeight(FontWeight.Bold).fontColor('#182333')
          Text('随时播放，享受此刻').fontSize(14).fontColor('#737E90')
        }.width('100%').alignItems(HorizontalAlign.Start)

        Image(this.coverFailed ? $r('app.media.cover_default') : this.currentTrack().cover)
          .width(220).height(220).objectFit(ImageFit.Cover).borderRadius(24)
          .accessibilityText(`${this.currentTrack().album}专辑封面，点击打开全屏歌词`)
          .onError(() => { this.coverFailed = true; })
          .onClick(() => { this.toggleLyrics(); })

        Row({ space: 8 }) {
          Button(this.lyricsVisible ? '收起歌词' : '查看歌词')
            .fontSize(13).height(34)
            .backgroundColor(this.lyricsVisible ? '#3867D6' : '#E8EEF9')
            .fontColor(this.lyricsVisible ? '#FFFFFF' : '#254681')
            .enabled(!this.playback.busy)
            .accessibilityText('切换全屏歌词视图')
            .onClick(() => { this.toggleLyrics(); })
          if (this.lyricsLines.length > 0) {
            Text('含逐字弹跳').fontSize(11).fontColor('#737E90')
          } else if (!this.lyricsLoading) {
            Text(this.lyricsLabel).fontSize(11).fontColor('#737E90')
          }
        }

        Column({ space: 8 }) {
          Text(this.currentTrack().title || '未知歌曲')
            .fontSize(26).fontWeight(FontWeight.Bold).fontColor('#182333')
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).textAlign(TextAlign.Center)
          Text(`歌手 · ${this.currentTrack().artist || '未知歌手'}`)
            .fontSize(14).fontColor('#526078').maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).textAlign(TextAlign.Center)
          Text(`专辑 · ${this.currentTrack().album || '未知专辑'}`)
            .fontSize(14).fontColor('#737E90').maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).textAlign(TextAlign.Center)
          Text(this.playback.busy ? '正在加载…' : this.playback.status)
            .fontSize(12).fontColor('#3867D6')
        }.width('100%')

        Column({ space: 4 }) {
          Slider({ value: this.dragging ? this.dragPosition : this.playback.position,
            min: 0, max: Math.max(1, this.playback.duration), step: 1 })
            .selectedColor('#3867D6').trackColor('#DCE3EF')
            .enabled(this.playback.ready && !this.playback.busy)
            .accessibilityText('播放进度')
            .onChange((value: number, mode: SliderChangeMode) => {
              this.dragPosition = value;
              this.dragging = mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving;
              if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                this.service?.seek(value);
              }
            })
          Row() {
            Text(`已播放 ${formatTime(this.dragging ? this.dragPosition : this.playback.position)}`).fontSize(12).fontColor('#737E90')
            Blank()
            Text(this.playback.duration > 0 ? `总时长 ${formatTime(this.playback.duration)}` : '总时长 --:--').fontSize(12).fontColor('#737E90')
          }.width('100%')
        }.width('100%')

        Row({ space: 14 }) {
          Button('上一首').fontSize(14).height(44).layoutWeight(1)
            .backgroundColor('#E8EEF9').fontColor('#254681')
            .enabled(!this.playback.busy).onClick(() => { this.service?.previous(); })
          Button(this.playback.error.length > 0 ? '重试' : (this.playback.playing ? '暂停' : '播放'))
            .fontSize(18).fontWeight(FontWeight.Bold).height(54).layoutWeight(1)
            .backgroundColor('#3867D6').enabled(!this.playback.busy)
            .onClick(() => { this.service?.toggle(); })
          Button('下一首').fontSize(14).height(44).layoutWeight(1)
            .backgroundColor('#E8EEF9').fontColor('#254681')
            .enabled(!this.playback.busy).onClick(() => { this.service?.next(); })
        }.width('100%')

        Row({ space: 10 }) {
          Button(this.voiceListening ? '正在聆听…' : '语音')
            .fontSize(14).height(40).layoutWeight(1)
            .backgroundColor(this.voiceListening ? '#526078' : '#E8EEF9')
            .fontColor(this.voiceListening ? '#FFFFFF' : '#254681')
            .enabled(!this.voiceListening && !this.playback.busy)
            .accessibilityText('语音点歌与控制')
            .onClick(() => { this.startVoice(); })
          if (this.voiceHint.length > 0) {
            Text(this.voiceHint).fontSize(12).fontColor('#3867D6').layoutWeight(2)
              .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }.width('100%')

        Button(this.modeLabels[this.playback.mode])
          .fontSize(14).height(38).backgroundColor('#E8EEF9').fontColor('#254681')
          .accessibilityText('播放模式，点击切换')
          .onClick(() => { this.service?.cycleMode(); })

        Row({ space: 10 }) {
          Text('音量').fontSize(14).fontColor('#526078')
          Slider({ value: Math.round(this.playback.volume * 100), min: 0, max: 100, step: 1 })
            .layoutWeight(1).selectedColor('#3867D6').accessibilityText('播放音量')
            .onChange((value: number) => { this.service?.setVolume(value); })
          Text(`${Math.round(this.playback.volume * 100)}%`).fontSize(13).width(40).fontColor('#526078')
        }.width('100%')

        if (this.playback.error.length > 0) {
          Text(this.playback.error).fontSize(13).fontColor('#B42318').width('100%')
        }

        Column({ space: 10 }) {
          Text('当前播放列表').fontSize(18).fontWeight(FontWeight.Bold).fontColor('#182333')
            .width('100%')
          Text(`${this.queue.length} 首歌曲`).fontSize(12).fontColor('#737E90')
          ForEach(this.queue, (track: Track, index: number) => {
            Row({ space: 12 }) {
              Image(track.cover).width(48).height(48).objectFit(ImageFit.Cover).borderRadius(8)
                .accessibilityText(`${track.album}专辑封面`)
              Column({ space: 5 }) {
                Text(track.title || '未知歌曲').fontSize(16).fontColor('#182333')
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(`${track.artist || '未知歌手'} · ${track.album || '未知专辑'}`)
                  .fontSize(12).fontColor('#737E90').maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              Text(index === this.playback.index ? '当前' : '播放')
                .fontSize(12).fontColor('#3867D6')
            }.padding(14).width('100%').borderRadius(12)
            .backgroundColor(index === this.playback.index ? '#E8EEF9' : '#FFFFFF')
            .enabled(!this.playback.busy)
            .accessibilityText(`播放${track.title}`)
            .onClick(() => { this.service?.select(index); })
          }, (track: Track) => track.id)
        }.width('100%').alignItems(HorizontalAlign.Start)
      }.width('100%').constraintSize({ maxWidth: 520 }).padding({ left: 24, right: 24, top: 24, bottom: 36 })
    }.width('100%').height('100%').backgroundColor('#F5F7FB')
  }

  @Builder
  songRow(track: Track, fromPlaylist: boolean) {
    Row({ space: 10 }) {
      Image(track.cover).width(44).height(44).borderRadius(8).objectFit(ImageFit.Cover)
      Column({ space: 5 }) {
        Text(track.title).fontSize(16).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(`${track.artist} · ${track.album}`).fontSize(12).fontColor('#737E90')
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(formatTime(track.duration ?? 0)).fontSize(12).fontColor('#737E90')
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        .onClick(() => { this.playTracks(fromPlaylist ? this.playlistTracks : searchTracks(this.libraryTracks, this.search), track); })
      Button('播放').fontSize(12).height(32).backgroundColor('#3867D6')
        .enabled(!this.working && !this.playback.busy)
        .onClick(() => { this.playTracks(fromPlaylist ? this.playlistTracks : searchTracks(this.libraryTracks, this.search), track); })
      Button(fromPlaylist ? '移除' : '加歌单').fontSize(12).height(32)
        .backgroundColor('#E8EEF9').fontColor('#254681').enabled(this.storeReady && !this.working)
        .onClick(() => {
          if (fromPlaylist) { this.removeFromPlaylist(track); }
          else { this.pendingTrack = track; }
        })
    }.width('100%').padding(12).borderRadius(12).backgroundColor('#FFFFFF')
  }

  @Builder
  libraryView() {
    Column({ space: 12 }) {
      Text('本地音乐库').fontSize(24).fontWeight(FontWeight.Bold).width('100%')
      Text(`共 ${this.libraryTracks.length} 首 · 点击歌曲即可播放`).fontSize(13).fontColor('#737E90').width('100%')
      Row({ space: 10 }) {
        Button('导入音乐').onClick(() => { this.refreshLibrary(true); }).enabled(!this.working)
        Button('刷新音乐库').onClick(() => { this.refreshLibrary(false); }).enabled(!this.working)
      }
      Search({ value: this.search, placeholder: '搜索歌名、歌手、专辑或文件名' })
        .onChange((value: string) => { this.search = value; })
      if (this.pendingTrack) {
        Column({ space: 8 }) {
          Text(`将“${this.pendingTrack.title}”加入歌单`).fontSize(16)
          if (this.playlists.length === 0) {
            Text('请先到“我的歌单”创建一个歌单').fontSize(13)
          }
          ForEach(this.playlists, (playlist: Playlist) => {
            Button(playlist.name).width('100%').enabled(!this.working)
              .onClick(() => { this.addToPlaylist(playlist.id); })
          }, (playlist: Playlist) => `${playlist.id}:${playlist.count}`)
          Button('取消添加').onClick(() => { this.pendingTrack = undefined; })
        }.padding(14).width('100%').backgroundColor('#E8EEF9').borderRadius(12)
      }
      List({ space: 10 }) {
        ForEach(searchTracks(this.libraryTracks, this.search), (track: Track) => {
          ListItem() { this.songRow(track, false) }
        }, (track: Track) => track.id)
        if (searchTracks(this.libraryTracks, this.search).length === 0) {
          ListItem() {
            Text(this.working ? '正在读取音乐…' : (this.search.length > 0 ? '没有找到匹配的歌曲' : '点击“导入音乐”添加本地音频'))
              .padding(24).fontColor('#737E90')
          }
        }
      }.layoutWeight(1).width('100%')
    }.padding(16).width('100%').height('100%')
  }

  @Builder
  playlistsView() {
    Column({ space: 12 }) {
      Text('我的歌单').fontSize(24).fontWeight(FontWeight.Bold).width('100%')
      Row({ space: 8 }) {
        TextInput({ text: this.playlistName, placeholder: '输入新歌单名称' }).maxLength(40)
          .layoutWeight(1).onChange((value: string) => { this.playlistName = value; })
        Button('创建').enabled(this.storeReady && !this.working)
          .onClick(() => { this.createPlaylist(); })
      }
      List({ space: 10 }) {
        ForEach(this.playlists, (playlist: Playlist) => {
          ListItem() {
            Row({ space: 10 }) {
              Text(`${playlist.name}（${playlist.count}首）`).layoutWeight(1).fontSize(16)
                .fontColor(this.selectedPlaylist === playlist.id ? '#3867D6' : '#182333')
                .onClick(() => { this.openPlaylist(playlist.id); })
              Button('打开').fontSize(12).height(32).enabled(!this.working)
                .onClick(() => { this.openPlaylist(playlist.id); })
              Button('删除').fontSize(12).height(32).backgroundColor('#FCE8E6').fontColor('#B42318')
                .enabled(!this.working).onClick(() => { this.confirmRemovePlaylist(playlist); })
            }.padding(12).backgroundColor('#FFFFFF').borderRadius(10)
          }
        }, (playlist: Playlist) => `${playlist.id}:${playlist.count}`)
        if (this.playlists.length === 0) {
          ListItem() { Text('创建歌单后，在音乐库点击“加歌单”添加歌曲').fontColor('#737E90').padding(12) }
        }
        if (this.selectedPlaylist >= 0) {
          ListItem() {
            Row() {
              Text('歌单歌曲').fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
              Button('播放全部').fontSize(13).enabled(this.playlistTracks.length > 0 && !this.working && !this.playback.busy)
                .onClick(() => { this.playTracks(this.playlistTracks, this.playlistTracks[0]); })
            }.padding({ top: 16, bottom: 8 })
          }
          ForEach(this.playlistTracks, (track: Track) => {
            ListItem() { this.songRow(track, true) }
          }, (track: Track) => track.id)
          if (this.playlistTracks.length === 0) {
            ListItem() { Text('歌单为空，请到音乐库添加歌曲').fontColor('#737E90').padding(12) }
          }
        }
      }.width('100%').layoutWeight(1)
    }.padding(16).width('100%').height('100%')
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        Row({ space: 8 }) {
          Button('播放主页').layoutWeight(1).fontSize(14)
            .backgroundColor(this.tab === 0 ? '#3867D6' : '#737E90').onClick(() => { this.tab = 0; })
          Button('音乐库').layoutWeight(1).fontSize(14)
            .backgroundColor(this.tab === 1 ? '#3867D6' : '#737E90').onClick(() => { this.tab = 1; })
          Button('我的歌单').layoutWeight(1).fontSize(14)
            .backgroundColor(this.tab === 2 ? '#3867D6' : '#737E90').onClick(() => { this.tab = 2; })
        }.padding(12).width('100%')
        if (this.message.length > 0) {
          Text(this.message).fontSize(12).fontColor('#526078').padding({ left: 16, right: 16, bottom: 8 })
            .width('100%').maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        Column() {
          if (this.tab === 0) { this.playerView() }
          else if (this.tab === 1) { this.libraryView() }
          else { this.playlistsView() }
        }.layoutWeight(1).width('100%')
      }.width('100%').height('100%').backgroundColor('#F5F7FB')

      if (this.lyricsVisible) {
        FullscreenLyrics({
          track: this.playback.track ?? this.currentTrack(),
          currentMs: this.dragging ? this.dragPosition : this.playback.position,
          totalMs: this.playback.duration,
          lines: this.lyricsLines,
          label: this.lyricsLabel,
          loading: this.lyricsLoading,
          coverFailed: this.coverFailed,
          onLyricsTap: () => { this.service?.toggle(); },
          visible: $lyricsVisible
        })
          .width('100%')
          .height('100%')
          .zIndex(99)
      }
    }
    .width('100%')
    .height('100%')
  }
}
