import { common } from '@kit.AbilityKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { media } from '@kit.MediaKit';
import { image } from '@kit.ImageKit';
import { Track } from '../model/Track';

export function searchTracks(tracks: Track[], query: string): Track[] {
  const needle = query.trim().toLocaleLowerCase();
  if (!needle) {
    return tracks.slice();
  }
  return tracks.filter((track: Track) =>
    [track.title, track.artist, track.album, track.fileName || ''].join('\n').toLocaleLowerCase().includes(needle));
}

function audioFile(name: string): boolean {
  return /\.(mp3|m4a|wav|flac|aac|ogg)$/i.test(name);
}

function stableKey(value: string): string {
  let hash: number = 2166136261;
  for (let index = 0; index < value.length; index++) {
    hash = Math.imul(hash ^ value.charCodeAt(index), 16777619);
  }
  return (hash >>> 0).toString(16);
}

export class LocalLibrary {
  public warnings: string[] = [];
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  async scan(): Promise<Track[]> {
    this.warnings = [];
    return this.scanDirectories();
  }

  private async scanDirectories(): Promise<Track[]> {
    const directories: string[] = [this.context.filesDir + '/music'];
    const appDirectory = this.context.getApplicationContext().filesDir + '/music';
    if (!directories.includes(appDirectory)) {
      directories.push(appDirectory);
    }
    const tracks: Track[] = [];
    for (const directory of directories) {
      try {
        if (!await fs.access(directory)) {
          continue;
        }
        const names = await fs.listFile(directory);
        names.sort();
        for (const name of names) {
          if (!audioFile(name)) {
            continue;
          }
          const path = directory + '/' + name;
          try {
            const stat = await fs.stat(path);
            if (stat.isFile()) {
              tracks.push(await this.readTrack(path, name, stat.size));
            }
          } catch (error) {
            this.warnings.push('无法读取 ' + name);
          }
        }
      } catch (error) {
        this.warnings.push('无法访问音乐目录：' + directory);
      }
    }
    return tracks;
  }

  async importFiles(): Promise<Track[]> {
    this.warnings = [];
    let uris: string[] = [];
    try {
      const viewPicker = new picker.DocumentViewPicker(this.context);
      uris = await viewPicker.select({
        maxSelectNumber: 50,
        fileSuffixFilters: ['音频|.mp3,.m4a,.wav,.flac,.aac,.ogg']
      });
    } catch (error) {
      // Cancellation normally returns an empty selection; surface other picker failures.
      this.warnings.push('文件选择未完成，请重试');
      return this.scanDirectories();
    }
    const directory = this.context.filesDir + '/music';
    if (!await fs.access(directory)) {
      await fs.mkdir(directory);
    }
    for (const uri of uris) {
      let source: fs.File | undefined = undefined;
      let temporary: string = '';
      try {
        const decoded = decodeURIComponent(uri.split('?')[0]);
        const name = decoded.substring(decoded.lastIndexOf('/') + 1).replace(/[\\/:\u0000-\u001f]/g, '_');
        if (!audioFile(name)) {
          this.warnings.push('跳过不支持的文件：' + name);
          continue;
        }
        // A stable source prefix makes selecting the same URI again idempotent.
        const destination = directory + '/import_' + stableKey(uri) + '_' + name;
        if (await fs.access(destination)) {
          continue;
        }
        temporary = destination + '.partial';
        source = await fs.open(uri, fs.OpenMode.READ_ONLY);
        await fs.copyFile(source.fd, temporary);
        await fs.rename(temporary, destination);
        temporary = '';
      } catch (error) {
        this.warnings.push('有音频导入失败，请重新选择该文件');
      } finally {
        if (source) {
          try { await fs.close(source); } catch (error) {}
        }
        if (temporary) {
          try { await fs.unlink(temporary); } catch (error) {}
        }
      }
    }
    return this.scanDirectories();
  }

  private async readTrack(path: string, name: string, size: number): Promise<Track> {
    const displayName = name.replace(/^import_[0-9a-f]+_/, '');
    const track: Track = {
      id: path,
      path: path,
      fileName: displayName,
      resource: '',
      title: displayName.replace(/\.[^.]+$/, ''),
      artist: '未知歌手',
      album: '未知专辑',
      duration: 0,
      cover: $r('app.media.cover_default')
    };
    let file: fs.File | undefined = undefined;
    let extractor: media.AVMetadataExtractor | undefined = undefined;
    try {
      file = await fs.open(path, fs.OpenMode.READ_ONLY);
      extractor = await media.createAVMetadataExtractor();
      extractor.fdSrc = { fd: file.fd, offset: 0, length: size };
      const metadata = await extractor.fetchMetadata();
      track.title = metadata.title?.trim() || track.title;
      track.artist = metadata.artist?.trim() || metadata.albumArtist?.trim() || track.artist;
      track.album = metadata.album?.trim() || track.album;
      const duration = Number(metadata.duration || '0');
      track.duration = Number.isFinite(duration) && duration > 0 ? duration : 0;
      const cover = await this.readCover(extractor, path);
      if (cover) {
        track.cover = cover;
      }
    } catch (error) {
      this.warnings.push(displayName + '：标签读取失败，已使用文件名');
    } finally {
      if (extractor) {
        try { await extractor.release(); } catch (error) {}
      }
      if (file) {
        try { await fs.close(file); } catch (error) {}
      }
    }
    return track;
  }

  private async readCover(extractor: media.AVMetadataExtractor, path: string): Promise<string> {
    let pixels: image.PixelMap | undefined = undefined;
    let packer: image.ImagePacker | undefined = undefined;
    let file: fs.File | undefined = undefined;
    try {
      pixels = await extractor.fetchAlbumCover();
      packer = image.createImagePacker();
      const bytes = await packer.packing(pixels, { format: 'image/jpeg', quality: 85 });
      const coverPath = this.context.cacheDir + '/music_cover_' + stableKey(path) + '.jpg';
      file = await fs.open(coverPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      await fs.write(file.fd, bytes);
      return 'file://' + coverPath;
    } catch (error) {
      // Tracks without an embedded image use the packaged default cover.
      return '';
    } finally {
      if (file) {
        try { await fs.close(file); } catch (error) {}
      }
      if (packer) {
        try { await packer.release(); } catch (error) {}
      }
      if (pixels) {
        try { await pixels.release(); } catch (error) {}
      }
    }
  }
}
