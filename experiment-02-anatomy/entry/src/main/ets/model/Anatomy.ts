// 解剖学习数据约定：收藏、浏览历史、学习笔记与结构快照。
// 这些类型是收藏/历史/详情页、RDB 存储层与人体浏览模块共用的公共契约。
// 本文件只包含类型与时间格式化，不依赖 HarmonyOS 运行时，便于自动化测试。

/** 收藏的解剖结构 */
export interface Favorite {
  id: string;           // 结构 partId / conceptId
  name: string;         // 结构名称
  systemId: string;     // 所属系统标识
  systemName: string;   // 所属系统名称
  createdAt: number;    // 收藏时间（毫秒）
}

/** 浏览历史条目（同一结构仅保留最新一次访问） */
export interface HistoryItem {
  id: string;           // 结构 partId
  name: string;         // 结构名称
  systemId: string;     // 所属系统标识
  visitedAt: number;    // 最近访问时间（毫秒）
}

/** 学习笔记，按结构关联 */
export interface Note {
  id: string;           // 笔记 ID
  structureId: string;  // 关联的结构 ID
  structureName: string;// 结构名称
  content: string;      // 笔记正文
  createdAt: number;
  updatedAt: number;
}

/** 当前选中结构快照（人体浏览 Web 侧回传、页面间传递） */
export interface SelectedStructure {
  id: string;
  name: string;
  systemId: string;
}

/** 人体系统预设（与 Web 侧一致） */
export interface SystemInfo {
  id: string;
  name: string;
  color: string;
}

// 导航参数键名约定：
//   pages/AnatomyBrowser 读取 locateId / locateName / locateSystemId，
//   模型就绪后据此定位并高亮对应结构；pages/StructureDetail 复用同一组键。
export interface AnatomyRouteParams {
  locateId?: string;
  locateName?: string;
  locateSystemId?: string;
}

function pad2(value: number): string {
  return value < 10 ? '0' + value : '' + value;
}

/** 毫秒时间戳 → yyyy-MM-dd HH:mm */
export function formatTime(ts: number): string {
  const d: Date = new Date(ts);
  return d.getFullYear() + '-' + pad2(d.getMonth() + 1) + '-' + pad2(d.getDate()) +
    ' ' + pad2(d.getHours()) + ':' + pad2(d.getMinutes());
}

/** 毫秒时间戳 → yyyy-MM-dd */
export function formatDate(ts: number): string {
  const d: Date = new Date(ts);
  return d.getFullYear() + '-' + pad2(d.getMonth() + 1) + '-' + pad2(d.getDate());
}
