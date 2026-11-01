import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Track } from '../model/Track';

export interface Playlist {
  id: number;
  name: string;
  count: number;
}

export class PlaylistStore {
  private store?: relationalStore.RdbStore;

  async initialize(context: common.UIAbilityContext): Promise<void> {
    if (this.store) {
      return;
    }
    const store = await relationalStore.getRdbStore(context, {
      name: 'music_playlists.db', securityLevel: relationalStore.SecurityLevel.S1
    });
    try {
      // A single playlist DELETE atomically removes its membership rows.
      await store.executeSql('PRAGMA foreign_keys = ON');
      await store.executeSql('CREATE TABLE IF NOT EXISTS playlists (' +
        'id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL UNIQUE)');
      await store.executeSql('CREATE TABLE IF NOT EXISTS playlist_tracks (' +
        'playlist_id INTEGER NOT NULL REFERENCES playlists(id) ON DELETE CASCADE, ' +
        'track_id TEXT NOT NULL, title TEXT NOT NULL, artist TEXT NOT NULL, album TEXT NOT NULL, ' +
        'cover TEXT NOT NULL, resource TEXT NOT NULL, path TEXT NOT NULL, file_name TEXT NOT NULL, ' +
        'duration INTEGER NOT NULL, PRIMARY KEY (playlist_id, track_id))');
      this.store = store;
    } catch (error) {
      await store.close();
      throw new Error((error as Error).message);
    }
  }

  private database(): relationalStore.RdbStore {
    if (!this.store) {
      throw new Error('歌单数据库尚未就绪');
    }
    return this.store;
  }

  async list(): Promise<Playlist[]> {
    const result = await this.database().querySql('SELECT p.id, p.name, COUNT(t.track_id) AS count ' +
      'FROM playlists p LEFT JOIN playlist_tracks t ON t.playlist_id = p.id ' +
      'GROUP BY p.id, p.name ORDER BY p.id');
    const playlists: Playlist[] = [];
    try {
      while (result.goToNextRow()) {
        playlists.push({ id: result.getLong(0), name: result.getString(1), count: result.getLong(2) });
      }
    } finally {
      result.close();
    }
    return playlists;
  }

  async create(name: string): Promise<void> {
    const trimmed = name.trim();
    if (trimmed.length === 0 || trimmed.length > 40) {
      throw new Error('歌单名称需为1至40个字符');
    }
    const existing = await this.database().querySql('SELECT id FROM playlists WHERE name = ?', [trimmed]);
    let duplicate = false;
    try {
      duplicate = existing.goToNextRow();
    } finally {
      existing.close();
    }
    if (duplicate) {
      throw new Error('该歌单名称已存在');
    }
    await this.database().executeSql('INSERT INTO playlists (name) VALUES (?)', [trimmed]);
  }

  async remove(id: number): Promise<void> {
    await this.database().executeSql('DELETE FROM playlists WHERE id = ?', [id]);
  }

  async addTrack(playlistId: number, track: Track): Promise<void> {
    const cover: string = typeof track.cover === 'string' ? track.cover : '';
    await this.database().executeSql('INSERT OR IGNORE INTO playlist_tracks ' +
      '(playlist_id, track_id, title, artist, album, cover, resource, path, file_name, duration) ' +
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)', [playlistId, track.id, track.title, track.artist,
      track.album, cover, track.resource, track.path ?? '', track.fileName ?? '', track.duration ?? 0]);
  }

  async removeTrack(playlistId: number, trackId: string): Promise<void> {
    await this.database().executeSql('DELETE FROM playlist_tracks WHERE playlist_id = ? AND track_id = ?',
      [playlistId, trackId]);
  }

  async tracks(playlistId: number): Promise<Track[]> {
    const result = await this.database().querySql('SELECT track_id, title, artist, album, cover, resource, ' +
      'path, file_name, duration FROM playlist_tracks WHERE playlist_id = ? ORDER BY rowid', [playlistId]);
    const tracks: Track[] = [];
    try {
      while (result.goToNextRow()) {
        const cover = result.getString(4);
        const filePath = result.getString(6);
        tracks.push({
          id: result.getString(0), title: result.getString(1), artist: result.getString(2),
          album: result.getString(3), cover: cover.length > 0 ? cover : $r('app.media.cover_default'),
          resource: result.getString(5), path: filePath.length > 0 ? filePath : undefined,
          fileName: result.getString(7), duration: result.getLong(8)
        });
      }
    } finally {
      result.close();
    }
    return tracks;
  }

  async close(): Promise<void> {
    if (this.store) {
      await this.store.close();
      this.store = undefined;
    }
  }
}
