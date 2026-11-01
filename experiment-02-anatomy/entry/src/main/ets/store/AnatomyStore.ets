import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { Favorite, HistoryItem, Note, SelectedStructure } from '../model/Anatomy';
import {
  FavoriteAction, HistoryWrite, NoteWrite, favoriteAction, isValidNoteContent,
  normalizeStructure, overflowHistoryIds, planHistoryWrite, planNoteWrite, HISTORY_LIMIT, NOTE_MAX_LENGTH
} from '../model/AnatomyRules';

const DB_NAME: string = 'anatomy.db';
const DB_VERSION: number = 1;

const STORE_CONFIG: relationalStore.StoreConfig = {
  name: DB_NAME,
  securityLevel: relationalStore.SecurityLevel.S1
};

const DDL_FAVORITES: string = 'CREATE TABLE IF NOT EXISTS favorites (' +
  'id TEXT PRIMARY KEY NOT NULL, ' +
  'name TEXT NOT NULL, ' +
  'systemId TEXT NOT NULL, ' +
  'systemName TEXT NOT NULL, ' +
  'createdAt INTEGER NOT NULL)';

const DDL_HISTORY: string = 'CREATE TABLE IF NOT EXISTS history (' +
  'id TEXT PRIMARY KEY NOT NULL, ' +
  'name TEXT NOT NULL, ' +
  'systemId TEXT NOT NULL, ' +
  'visitedAt INTEGER NOT NULL)';

const DDL_NOTES: string = 'CREATE TABLE IF NOT EXISTS notes (' +
  'id TEXT PRIMARY KEY NOT NULL, ' +
  'structureId TEXT NOT NULL, ' +
  'structureName TEXT NOT NULL, ' +
  'content TEXT NOT NULL, ' +
  'createdAt INTEGER NOT NULL, ' +
  'updatedAt INTEGER NOT NULL)';

function favBucket(f: Favorite): relationalStore.ValuesBucket {
  return {
    'id': f.id, 'name': f.name, 'systemId': f.systemId,
    'systemName': f.systemName, 'createdAt': f.createdAt
  };
}

function histBucket(h: HistoryItem): relationalStore.ValuesBucket {
  return { 'id': h.id, 'name': h.name, 'systemId': h.systemId, 'visitedAt': h.visitedAt };
}

function noteBucket(n: Note): relationalStore.ValuesBucket {
  return {
    'id': n.id, 'structureId': n.structureId, 'structureName': n.structureName,
    'content': n.content, 'createdAt': n.createdAt, 'updatedAt': n.updatedAt
  };
}

function favoriteFromRow(rs: relationalStore.ResultSet): Favorite {
  return {
    id: rs.getString(rs.getColumnIndex('id')),
    name: rs.getString(rs.getColumnIndex('name')),
    systemId: rs.getString(rs.getColumnIndex('systemId')),
    systemName: rs.getString(rs.getColumnIndex('systemName')),
    createdAt: rs.getLong(rs.getColumnIndex('createdAt'))
  };
}

function historyFromRow(rs: relationalStore.ResultSet): HistoryItem {
  return {
    id: rs.getString(rs.getColumnIndex('id')),
    name: rs.getString(rs.getColumnIndex('name')),
    systemId: rs.getString(rs.getColumnIndex('systemId')),
    visitedAt: rs.getLong(rs.getColumnIndex('visitedAt'))
  };
}

function noteFromRow(rs: relationalStore.ResultSet): Note {
  return {
    id: rs.getString(rs.getColumnIndex('id')),
    structureId: rs.getString(rs.getColumnIndex('structureId')),
    structureName: rs.getString(rs.getColumnIndex('structureName')),
    content: rs.getString(rs.getColumnIndex('content')),
    createdAt: rs.getLong(rs.getColumnIndex('createdAt')),
    updatedAt: rs.getLong(rs.getColumnIndex('updatedAt'))
  };
}

/** 收藏、浏览历史与学习笔记的本地 RDB 存储。 */
export class AnatomyStore {
  private rdb: relationalStore.RdbStore;

  private constructor(rdb: relationalStore.RdbStore) {
    this.rdb = rdb;
  }

  static async open(context: common.Context): Promise<AnatomyStore> {
    const rdb: relationalStore.RdbStore = await relationalStore.getRdbStore(context, STORE_CONFIG);
    // 建表幂等；后续版本迁移在此处按 rdb.version 分支处理。
    await rdb.executeSql(DDL_FAVORITES);
    await rdb.executeSql(DDL_HISTORY);
    await rdb.executeSql(DDL_NOTES);
    if (rdb.version !== DB_VERSION) rdb.version = DB_VERSION;
    const store: AnatomyStore = new AnatomyStore(rdb);
    await store.pruneHistory();
    return store;
  }

  // ===== 收藏 =====
  async listFavorites(): Promise<Favorite[]> {
    const p = new relationalStore.RdbPredicates('favorites');
    p.orderByDesc('createdAt');
    const rs = await this.rdb.query(p);
    const rows: Favorite[] = [];
    try {
      if (rs.goToFirstRow()) {
        do { rows.push(favoriteFromRow(rs)); } while (rs.goToNextRow());
      }
    } finally { rs.close(); }
    return rows;
  }

  async isFavorite(id: string): Promise<boolean> {
    if (id.trim().length === 0) return false;
    const p = new relationalStore.RdbPredicates('favorites');
    p.equalTo('id', id);
    const rs = await this.rdb.query(p, ['id']);
    try { return rs.goToFirstRow(); } finally { rs.close(); }
  }

  /** 新增收藏；已存在或结构非法时返回 false（重复收藏受控）。 */
  async addFavorite(id: string, name: string, systemId: string, systemName: string): Promise<boolean> {
    const structure: SelectedStructure | null = normalizeStructure(id, name, systemId);
    if (structure === null) return false;
    if (await this.isFavorite(structure.id)) return false;
    await this.rdb.insert('favorites', favBucket({
      id: structure.id, name: structure.name, systemId: structure.systemId,
      systemName: systemName.trim(), createdAt: Date.now()
    }));
    return true;
  }

  /** 取消收藏；返回是否存在被删除的记录。 */
  async removeFavorite(id: string): Promise<boolean> {
    if (!await this.isFavorite(id)) return false;
    const p = new relationalStore.RdbPredicates('favorites');
    p.equalTo('id', id);
    await this.rdb.delete(p);
    return true;
  }

  /** 切换收藏；返回切换后的收藏状态。 */
  async toggleFavorite(id: string, name: string, systemId: string, systemName: string): Promise<boolean> {
    const current: boolean = await this.isFavorite(id);
    if (favoriteAction(current) === FavoriteAction.Remove) {
      await this.removeFavorite(id);
      return false;
    }
    return await this.addFavorite(id, name, systemId, systemName);
  }

  // ===== 浏览历史 =====
  private async getHistory(id: string): Promise<HistoryItem | null> {
    const p = new relationalStore.RdbPredicates('history');
    p.equalTo('id', id);
    const rs = await this.rdb.query(p);
    try {
      if (rs.goToFirstRow()) return historyFromRow(rs);
      return null;
    } finally { rs.close(); }
  }

  /** 记录一次浏览；同一结构仅保留最新访问时间。 */
  async addHistory(id: string, name: string, systemId: string): Promise<boolean> {
    const structure: SelectedStructure | null = normalizeStructure(id, name, systemId);
    if (structure === null) return false;
    const now: number = Date.now();
    const existing: HistoryItem | null = await this.getHistory(structure.id);
    const plan: HistoryWrite = planHistoryWrite(existing, structure, now);
    if (plan.isNew) {
      await this.rdb.insert('history', histBucket(plan.row));
    } else {
      const p = new relationalStore.RdbPredicates('history');
      p.equalTo('id', plan.row.id);
      await this.rdb.update(histBucket(plan.row), p);
    }
    await this.pruneHistory();
    return true;
  }

  async listHistory(): Promise<HistoryItem[]> {
    const p = new relationalStore.RdbPredicates('history');
    p.orderByDesc('visitedAt');
    const rs = await this.rdb.query(p);
    const rows: HistoryItem[] = [];
    try {
      if (rs.goToFirstRow()) {
        do { rows.push(historyFromRow(rs)); } while (rs.goToNextRow());
      }
    } finally { rs.close(); }
    return rows;
  }

  /** 超出上限时按时间淘汰最旧记录，返回删除条数。 */
  private async pruneHistory(): Promise<number> {
    const rows: HistoryItem[] = await this.listHistory();
    const ids: string[] = overflowHistoryIds(rows, HISTORY_LIMIT);
    for (const id of ids) {
      const p = new relationalStore.RdbPredicates('history');
      p.equalTo('id', id);
      await this.rdb.delete(p);
    }
    return ids.length;
  }

  async clearHistory(): Promise<void> {
    const p = new relationalStore.RdbPredicates('history');
    await this.rdb.delete(p);
  }

  // ===== 学习笔记 =====
  /** 列出笔记；给定 structureId 时仅返回该结构的笔记。 */
  async listNotes(structureId?: string): Promise<Note[]> {
    const p = new relationalStore.RdbPredicates('notes');
    if (structureId !== undefined && structureId.trim().length > 0) {
      p.equalTo('structureId', structureId.trim());
    }
    p.orderByDesc('updatedAt');
    const rs = await this.rdb.query(p);
    const rows: Note[] = [];
    try {
      if (rs.goToFirstRow()) {
        do { rows.push(noteFromRow(rs)); } while (rs.goToNextRow());
      }
    } finally { rs.close(); }
    return rows;
  }

  private async getNote(id: string): Promise<Note | null> {
    const p = new relationalStore.RdbPredicates('notes');
    p.equalTo('id', id);
    const rs = await this.rdb.query(p);
    try {
      if (rs.goToFirstRow()) return noteFromRow(rs);
      return null;
    } finally { rs.close(); }
  }

  /**
   * 新增或编辑某结构的笔记。id 为空表示新增；内容非法时抛错。
   * 笔记始终与其 structureId 关联。
   */
  async saveNote(id: string | null, structureId: string, structureName: string, content: string): Promise<Note> {
    if (!isValidNoteContent(content)) {
      throw new Error('笔记正文需为 1~' + NOTE_MAX_LENGTH + ' 字');
    }
    const structure: SelectedStructure | null = normalizeStructure(structureId, structureName, '');
    if (structure === null) {
      throw new Error('笔记必须关联有效结构');
    }
    const now: number = Date.now();
    const key: string = id === null ? '' : id.trim();
    const existing: Note | null = key.length > 0 ? await this.getNote(key) : null;
    const newId: string = util.generateRandomUUID(true);
    const plan: NoteWrite = planNoteWrite(existing, newId, structure.id, structure.name, content, now);
    if (plan.isNew) {
      await this.rdb.insert('notes', noteBucket(plan.note));
    } else {
      const p = new relationalStore.RdbPredicates('notes');
      p.equalTo('id', plan.note.id);
      await this.rdb.update(noteBucket(plan.note), p);
    }
    return plan.note;
  }

  async deleteNote(id: string): Promise<boolean> {
    const existing: Note | null = await this.getNote(id);
    if (existing === null) return false;
    const p = new relationalStore.RdbPredicates('notes');
    p.equalTo('id', id);
    await this.rdb.delete(p);
    return true;
  }
}
