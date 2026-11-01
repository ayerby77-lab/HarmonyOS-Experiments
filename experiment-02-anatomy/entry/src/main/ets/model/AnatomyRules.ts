// 收藏/历史/笔记的数据操作规则（纯函数）。
// 存储层调用这些规则，边界行为可脱离 HarmonyOS 运行时单独测试。
import { AnatomyRouteParams, HistoryItem, Note, SelectedStructure } from './Anatomy';

/** 浏览历史上限，超出后按时间淘汰最旧记录 */
export const HISTORY_LIMIT: number = 200;
/** 单条笔记正文长度上限 */
export const NOTE_MAX_LENGTH: number = 2000;

function clean(value?: string): string {
  if (value === undefined || value === null) return '';
  return value.trim();
}

/** 校验并规范化结构快照；id 或 name 为空时返回 null。 */
export function normalizeStructure(id?: string, name?: string, systemId?: string): SelectedStructure | null {
  const sid: string = clean(id);
  const sname: string = clean(name);
  if (sid.length === 0 || sname.length === 0) return null;
  return { id: sid, name: sname, systemId: clean(systemId) };
}

/** 读取人体浏览页的定位参数；仅要求 locateId，名称可缺省。 */
export function readLocateParams(params?: AnatomyRouteParams | null): SelectedStructure | null {
  if (params === undefined || params === null) return null;
  const sid: string = clean(params.locateId);
  if (sid.length === 0) return null;
  return { id: sid, name: clean(params.locateName), systemId: clean(params.locateSystemId) };
}

/** 由结构快照构造导航定位参数。 */
export function buildLocateParams(structure?: SelectedStructure | null): AnatomyRouteParams {
  if (structure === undefined || structure === null) return {};
  return { locateId: structure.id, locateName: structure.name, locateSystemId: structure.systemId };
}

/** 笔记正文是否有效（去除首尾空白后 1~NOTE_MAX_LENGTH 字）。 */
export function isValidNoteContent(content: string): boolean {
  const body: string = clean(content);
  return body.length > 0 && body.length <= NOTE_MAX_LENGTH;
}

export enum FavoriteAction {
  Add = 'add',
  Remove = 'remove'
}

/** 依据当前收藏状态决定动作，保证重复收藏/重复取消的结果可预期。 */
export function favoriteAction(isFavorite: boolean): FavoriteAction {
  return isFavorite ? FavoriteAction.Remove : FavoriteAction.Add;
}

/** 历史写入计划：已存在则更新时间，否则新增。 */
export interface HistoryWrite {
  row: HistoryItem;
  isNew: boolean;
}

export function planHistoryWrite(existing: HistoryItem | null, structure: SelectedStructure, now: number): HistoryWrite {
  if (existing !== null) {
    return {
      row: { id: existing.id, name: structure.name, systemId: structure.systemId, visitedAt: now },
      isNew: false
    };
  }
  return {
    row: { id: structure.id, name: structure.name, systemId: structure.systemId, visitedAt: now },
    isNew: true
  };
}

/** 返回需要淘汰的历史 id；rows 需已按 visitedAt 降序排列。 */
export function overflowHistoryIds(rows: HistoryItem[], limit: number = HISTORY_LIMIT): string[] {
  if (limit <= 0) {
    const all: string[] = [];
    for (let i: number = 0; i < rows.length; i++) all.push(rows[i].id);
    return all;
  }
  const ids: string[] = [];
  for (let i: number = limit; i < rows.length; i++) ids.push(rows[i].id);
  return ids;
}

/** 笔记写入计划：existing 非空为编辑，否则用 newId 新建。 */
export interface NoteWrite {
  note: Note;
  isNew: boolean;
}

export function planNoteWrite(
  existing: Note | null, newId: string, structureId: string, structureName: string,
  content: string, now: number
): NoteWrite {
  const body: string = content.trim();
  if (existing !== null) {
    return {
      note: {
        id: existing.id, structureId: structureId, structureName: structureName,
        content: body, createdAt: existing.createdAt, updatedAt: now
      },
      isNew: false
    };
  }
  return {
    note: {
      id: newId, structureId: structureId, structureName: structureName,
      content: body, createdAt: now, updatedAt: now
    },
    isNew: true
  };
}
