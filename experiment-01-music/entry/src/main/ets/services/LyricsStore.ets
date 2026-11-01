import { common } from '@kit.AbilityKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { Track } from '../model/Track';
import { parseLrc } from '../model/Lyrics';

export interface LyricsSource {
  text: string;
  label: string;
}

const MAX_LYRIC_BYTES: number = 1024 * 1024;

function stableKey(value: string): string {
  let first: number = 2166136261;
  let second: number = 5381;
  for (let index = 0; index < value.length; index++) {
    first = Math.imul(first ^ value.charCodeAt(index), 16777619);
    second = Math.imul(second, 33) ^ value.charCodeAt(index);
  }
  return (first >>> 0).toString(16) + '_' + (second >>> 0).toString(16);
}

function decodeLyrics(bytes: Uint8Array): string {
  if (bytes.length >= 2 && bytes[0] === 255 && bytes[1] === 254) {
    return util.TextDecoder.create('utf-16le').decodeToString(bytes).replace(/^\uFEFF/, '');
  }
  if (bytes.length >= 2 && bytes[0] === 254 && bytes[1] === 255) {
    return util.TextDecoder.create('utf-16be').decodeToString(bytes).replace(/^\uFEFF/, '');
  }
  try {
    return util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(bytes).replace(/^\uFEFF/, '');
  } catch (error) {
    return util.TextDecoder.create('gb18030', { fatal: true }).decodeToString(bytes);
  }
}

export class LyricsStore {
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  private storedPath(track: Track): string {
    return this.context.filesDir + '/lyrics/' + stableKey(track.id) + '.lrc';
  }

  async load(track: Track): Promise<LyricsSource> {
    const paths: string[] = [this.storedPath(track)];
    if (track.path) {
      paths.push(track.path.replace(/\.[^/.]+$/, '') + '.lrc');
    }
    for (const path of paths) {
      try {
        const text = await this.readText(path);
        if (parseLrc(text, track.duration || 0).length > 0) {
          return { text: text, label: '本地歌词' };
        }
      } catch (error) {
        // Missing or unreadable sidecar lyrics must never interrupt playback.
      }
    }
    if (track.resource) {
      try {
        const name = track.resource.replace(/\.[^.]+$/, '') + '.lrc';
        const bytes = await this.context.resourceManager.getRawFileContent(name);
        if (bytes.length <= MAX_LYRIC_BYTES) {
          const text = decodeLyrics(bytes);
          if (parseLrc(text, track.duration || 0).length > 0) {
            return { text: text, label: '示例歌词' };
          }
        }
      } catch (error) {}
    }
    // Bundled LRC lookup by artist + title (rawfile/lyrics/<artist>_<title>.lrc)
    const bundled: string | undefined = await this.loadBundledLyrics(track);
    if (bundled) {
      return { text: bundled, label: '网络歌词' };
    }
    return { text: '', label: '暂无歌词' };
  }

  private async loadBundledLyrics(track: Track): Promise<string | undefined> {
    const candidates: string[] = [];
    if (track.artist.length > 0 && track.title.length > 0) {
      candidates.push(this.sanitizeLrcName(track.artist, track.title));
    }
    if (track.title.length > 0) {
      candidates.push(this.sanitizeLrcName('', track.title));
    }
    for (const stem of candidates) {
      try {
        const bytes = await this.context.resourceManager.getRawFileContent('lyrics/' + stem + '.lrc');
        if (bytes.length > 0 && bytes.length <= MAX_LYRIC_BYTES) {
          const text = decodeLyrics(bytes);
          if (parseLrc(text, track.duration || 0).length > 0) {
            return text;
          }
        }
      } catch (error) {}
    }
    return undefined;
  }

  private sanitizeLrcName(artist: string, title: string): string {
    const raw = (artist.length > 0 ? artist + '_' : '') + title;
    return raw.replace(/[\\/:*?"<>|\s+]/g, '_').replace(/_+/g, '_');
  }

  async importForTrack(track: Track): Promise<LyricsSource | undefined> {
    const viewPicker = new picker.DocumentViewPicker(this.context);
    const uris = await viewPicker.select({
      maxSelectNumber: 1,
      fileSuffixFilters: ['歌词|.lrc']
    });
    if (uris.length === 0) return undefined;
    const text = await this.readText(uris[0]);
    if (parseLrc(text, track.duration || 0).length === 0) {
      throw new Error('歌词文件中没有有效的 LRC 时间戳');
    }
    const directory = this.context.filesDir + '/lyrics';
    if (!await fs.access(directory)) await fs.mkdir(directory);
    const destination = this.storedPath(track);
    const temporary = destination + '.partial';
    let file: fs.File | undefined = undefined;
    try {
      file = await fs.open(temporary, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      const bytes = new util.TextEncoder().encodeInto(text);
      let written: number = 0;
      while (written < bytes.length) {
        const count = await fs.write(file.fd, bytes.slice(written).buffer);
        if (count <= 0) throw new Error('歌词保存失败');
        written += count;
      }
      await fs.close(file);
      file = undefined;
      await fs.rename(temporary, destination);
    } finally {
      if (file) { try { await fs.close(file); } catch (error) {} }
      try { await fs.unlink(temporary); } catch (error) {}
    }
    return { text: text, label: '本地歌词' };
  }

  private async readText(path: string): Promise<string> {
    let file: fs.File | undefined = undefined;
    try {
      file = await fs.open(path, fs.OpenMode.READ_ONLY);
      const stat = await fs.stat(file.fd);
      if (stat.size <= 0 || stat.size > MAX_LYRIC_BYTES) {
        throw new Error('请选择 1 MB 以内的有效歌词文件');
      }
      const bytes = new Uint8Array(stat.size);
      let position: number = 0;
      while (position < bytes.length) {
        const buffer = new ArrayBuffer(bytes.length - position);
        const count = await fs.read(file.fd, buffer, { offset: position });
        if (count <= 0) throw new Error('歌词文件读取不完整');
        bytes.set(new Uint8Array(buffer, 0, count), position);
        position += count;
      }
      return decodeLyrics(bytes);
    } finally {
      if (file) { try { await fs.close(file); } catch (error) {} }
    }
  }
}
