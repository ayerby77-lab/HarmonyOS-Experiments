/**
 * 本地识别记录服务（第二阶段，Agent 4），实现 Agent 0 冻结的 RecordServiceApi
 *（models/RecordTypes.ets）。依据 docs/phase-2-contract.md 第 2、4、5 节。
 *
 * 职责边界：
 * - 只负责 RDB 行与查询；图像文件由 Agent 1 的 ImageAssetStore 生成与删除，
 *   本服务在保存失败回滚、删除记录、启动孤儿清理时调用其接口（协调约定见
 *   docs/phase-2-agent-1-report.md 第 4 节）。
 * - 所有 SQL 均通过 executeSql/querySql 的 bindArgs 参数化，不拼接用户输入。
 * - 初始化：建议 EntryAbility 在 loadContent 前调用 initialize(context)；
 *   未显式初始化时各公开方法懒初始化（getContext 兜底取应用上下文），
 *   初始化失败返回 initialized=false 或以 DB_INIT_FAILED 拒绝，不崩溃。
 */
import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DetectionBox, DetectionResult, InferenceExecutionMode } from '../../models/DetectionTypes';
import { ImageOrigin } from '../../models/ImageTypes';
import {
  RecordDeleteResult,
  RecordDetail,
  RecordErrorCode,
  RecordInitResult,
  RecordPage,
  RecordSaveInput,
  RecordServiceApi,
  RecordSummary
} from '../../models/RecordTypes';
import { ImageAssetStore } from '../imaging/ImageAssetStore';
import { RecordDatabase, TABLE_RECORDS } from './RecordDatabase';

const TAG: string = 'RecordService';

/**
 * 将推理服务返回的 DetectionResult 映射为 save 输入，供页面直接调用：
 *   save(toRecordSaveInput(result), source, originalPath, thumbnailPath)
 * 只提取存储所需字段；requestId/imageId/阈值/recognizedAtMs 属上传阶段字段，
 * 本阶段 RDB 不落库（见 phase-2-agent-4-report 客户端协调项）。
 */
export function toRecordSaveInput(result: DetectionResult): RecordSaveInput {
  const input: RecordSaveInput = {
    boxes: result.boxes,
    modelId: result.modelId,
    modelSha256: result.modelSha256,
    imageWidth: result.imageWidth,
    imageHeight: result.imageHeight,
    coldStart: result.timing.coldStart,
    totalMs: result.timing.totalMs,
    executionMode: result.executionMode
  };
  return input;
}

const DOMAIN: number = 0x0000;

/** list 默认与最大页大小（契约 4.1）。 */
const DEFAULT_PAGE_SIZE: number = 20;
const MAX_PAGE_SIZE: number = 50;
/** listByClass 默认上限。 */
const DEFAULT_CLASS_LIMIT: number = 50;
/** 主键冲突时重新生成 recordId 的重试次数（仅自生成 id 路径）。 */
const SAVE_ID_RETRY: number = 3;
/** Agent 1 图像文件名后缀（ImageAssetStore 布局：records/{assetId}_original.jpg）。 */
const ORIGINAL_FILE_SUFFIX: string = '_original.jpg';

/** 存储层错误，携带 RecordErrorCode，供页面按契约第 7 节映射提示。 */
export class RecordFailure extends Error {
  code: RecordErrorCode;
  detail: string;

  constructor(code: RecordErrorCode, message: string, detail: string = '') {
    super(message);
    this.code = code;
    this.detail = detail;
  }
}

/** topOf 返回：编辑后框中置信度最高者的类别名与置信度。 */
interface TopBoxInfo {
  label: string;
  confidence: number;
}

/** 记录行原始结构（querySql 结果的一行）。 */
interface RecordRow {
  recordId: string;
  createdAtMs: number;
  source: string;
  modelId: string;
  modelSha256: string;
  imagePath: string;
  thumbnailPath: string;
  imageWidth: number;
  imageHeight: number;
  coldStart: number;
  totalMs: number;
  executionMode: string;
  rawBoxesJson: string;
  editedBoxesJson: string;
}

const ROW_COLUMNS: string =
  'record_id, created_at_ms, source, model_id, model_sha256, image_path, thumbnail_path, ' +
  'image_width, image_height, cold_start, total_ms, execution_mode, raw_boxes_json, edited_boxes_json';

export class RecordService implements RecordServiceApi {
  private static instance: RecordService | null = null;

  static getInstance(): RecordService {
    if (RecordService.instance === null) {
      RecordService.instance = new RecordService();
    }
    return RecordService.instance;
  }

  private store: relationalStore.RdbStore | null = null;
  private context: common.Context | null = null;
  private initPromise: Promise<boolean> | null = null;

  private constructor() {
  }

  /**
   * 初始化 RDB 并执行启动孤儿清理。幂等；并发调用共享同一 Promise。
   * 可选传入 UIAbility 上下文；缺省时用全局 getContext() 取应用上下文。
   */
  async initialize(context?: common.Context): Promise<RecordInitResult> {
    if (context !== undefined) {
      this.context = context;
    }
    if (this.store !== null) {
      const ready: RecordInitResult = { initialized: true };
      return ready;
    }
    if (this.initPromise === null) {
      this.initPromise = this.doInitialize();
    }
    const ok: boolean = await this.initPromise;
    if (!ok) {
      // 失败后允许下次调用重试。
      this.initPromise = null;
      const failed: RecordInitResult = {
        initialized: false,
        error: 'RDB 初始化失败，详见日志'
      };
      return failed;
    }
    const ready: RecordInitResult = { initialized: true };
    return ready;
  }

  private async doInitialize(): Promise<boolean> {
    try {
      const context: common.Context = this.resolveContext();
      const store: relationalStore.RdbStore = await RecordDatabase.open(context);
      this.store = store;
      hilog.info(DOMAIN, TAG, 'RDB opened, version=%{public}d', store.version);
      await this.cleanupOrphans(context, store);
      return true;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'RDB init failed: %{public}s', JSON.stringify(e));
      this.store = null;
      return false;
    }
  }

  private resolveContext(): common.Context {
    if (this.context !== null) {
      return this.context;
    }
    const context: common.Context = getContext() as common.Context;
    this.context = context;
    return context;
  }

  /** 未初始化时懒初始化；仍失败抛 DB_INIT_FAILED。 */
  private async ensureStore(): Promise<relationalStore.RdbStore> {
    if (this.store !== null) {
      return this.store;
    }
    const result: RecordInitResult = await this.initialize();
    if (!result.initialized || this.store === null) {
      throw new RecordFailure(RecordErrorCode.DB_INIT_FAILED, '识别历史不可用', result.error ?? 'init failed');
    }
    return this.store;
  }

  /**
   * 保存一条识别结果，返回 recordId。
   * raw_boxes_json 与 edited_boxes_json 首次写入相同（契约 3.1）。
   *
   * recordId 策略（与 Agent 1 协调，phase-2-agent-1-report 协调节）：
   * 优先取 originalPath 文件名中的 assetId（rec_{ms}_{hex4}），与图像文件同名，
   * 使记录行与文件生命周期一致、孤儿清理可按 record_id 集合判定；
   * 路径不含标准 assetId 时退化为存储层自生成 id。
   *
   * 重复保存（契约 5.1 不做同图去重，但同一持久化产物可能被重复提交）：
   * 主键冲突时若 id 来自文件路径，说明该批文件对应的记录已存在，幂等返回原
   * recordId 而不产生重复行；自生成 id 冲突时换 id 重试。
   * 写入失败时回滚已生成的图片文件（契约 5.2）。
   */
  async save(modelResult: RecordSaveInput, source: ImageOrigin, originalPath: string,
    thumbnailPath: string): Promise<string> {
    const store: relationalStore.RdbStore = await this.ensureStoreForSave(originalPath, thumbnailPath);
    const context: common.Context = this.resolveContext();
    const relOriginal: string = toRelativePath(context, originalPath);
    const relThumbnail: string = toRelativePath(context, thumbnailPath);
    const pathId: string = extractAssetId(relOriginal);
    const createdAtMs: number = Date.now();
    const rawJson: string = JSON.stringify(modelResult.boxes);
    let lastError: string = '';
    // pathId 存在但冲突且幂等查询为空时，后续次数回退到自生成 id，避免死循环。
    let usePathId: boolean = pathId.length > 0;
    for (let attempt: number = 0; attempt <= SAVE_ID_RETRY; attempt++) {
      const recordId: string = usePathId ? pathId : RecordDatabase.generateRecordId(createdAtMs);
      try {
        await RecordDatabase.runInTransaction(store, async (): Promise<void> => {
          await store.executeSql(
            `INSERT INTO ${TABLE_RECORDS} (${ROW_COLUMNS}) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
            [
              recordId, createdAtMs, source as string, modelResult.modelId, modelResult.modelSha256,
              relOriginal, relThumbnail, modelResult.imageWidth, modelResult.imageHeight,
              modelResult.coldStart ? 1 : 0, Math.round(modelResult.totalMs),
              modelResult.executionMode as string, rawJson, rawJson
            ]
          );
        });
        hilog.info(DOMAIN, TAG, 'Saved record %{public}s, boxes=%{public}d', recordId, modelResult.boxes.length);
        return recordId;
      } catch (e) {
        lastError = JSON.stringify(e);
        hilog.warn(DOMAIN, TAG, 'save attempt %{public}d failed: %{public}s', attempt, lastError);
        if (usePathId) {
          const existing: RecordDetail | null = await this.getDetail(pathId);
          if (existing !== null) {
            hilog.info(DOMAIN, TAG, 'Duplicate save for %{public}s, idempotent return', pathId);
            return pathId;
          }
          // 冲突但记录查不到：放弃路径派生 id，后续回退自生成。
          usePathId = false;
        }
      }
    }
    await this.rollbackImages(originalPath, thumbnailPath);
    throw new RecordFailure(RecordErrorCode.DB_WRITE_FAILED, '保存失败，请重试', lastError);
  }

  /** ensureStore 的 save 变体：初始化失败时同样回滚图片（契约 5.2）。 */
  private async ensureStoreForSave(originalPath: string, thumbnailPath: string): Promise<relationalStore.RdbStore> {
    try {
      return await this.ensureStore();
    } catch (e) {
      await this.rollbackImages(originalPath, thumbnailPath);
      if (e instanceof Error) {
        throw e;
      }
      throw new Error(String(e));
    }
  }

  /** 保存失败回滚：删除已持久化的原图与缩略图；尽力而为不抛错。 */
  private async rollbackImages(originalPath: string, thumbnailPath: string): Promise<void> {
    try {
      const context: common.Context = this.resolveContext();
      await ImageAssetStore.getInstance().deleteImages(context, originalPath, thumbnailPath);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'rollback images failed: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * 更新编辑后的检测框。只改 edited_boxes_json，raw_boxes_json 不变（契约 3.2）。
   * @throws RecordFailure(RECORD_NOT_FOUND) 记录不存在时。
   */
  async updateEdited(recordId: string, editedBoxes: DetectionBox[]): Promise<RecordDetail> {
    const store: relationalStore.RdbStore = await this.ensureStore();
    const json: string = JSON.stringify(editedBoxes);
    await RecordDatabase.runInTransaction(store, async (): Promise<void> => {
      const existing: relationalStore.ResultSet = await store.querySql(
        `SELECT record_id FROM ${TABLE_RECORDS} WHERE record_id = ?`, [recordId]);
      try {
        if (!existing.goToNextRow()) {
          throw new RecordFailure(RecordErrorCode.RECORD_NOT_FOUND, '记录已删除', recordId);
        }
      } finally {
        existing.close();
      }
      await store.executeSql(
        `UPDATE ${TABLE_RECORDS} SET edited_boxes_json = ? WHERE record_id = ?`,
        [json, recordId]);
    });
    const detail: RecordDetail | null = await this.getDetail(recordId);
    if (detail === null) {
      throw new RecordFailure(RecordErrorCode.RECORD_NOT_FOUND, '记录已删除', recordId);
    }
    return detail;
  }

  /** 分页查询，created_at_ms 降序 + record_id 降序保证同毫秒翻页稳定。 */
  async list(page: number, pageSize: number, sourceFilter?: ImageOrigin): Promise<RecordPage> {
    const store: relationalStore.RdbStore = await this.ensureStore();
    const safePage: number = page < 1 ? 1 : Math.floor(page);
    const safeSize: number = clampPageSize(pageSize);
    const offset: number = (safePage - 1) * safeSize;
    const args: relationalStore.ValueType[] = [];
    let where: string = '';
    if (sourceFilter !== undefined) {
      where = ' WHERE source = ?';
      args.push(sourceFilter as string);
    }
    // 多取一行判断是否还有下一页，避免额外 COUNT 查询。
    args.push(safeSize + 1);
    args.push(offset);
    const resultSet: relationalStore.ResultSet = await store.querySql(
      `SELECT ${ROW_COLUMNS} FROM ${TABLE_RECORDS}${where}` +
      ' ORDER BY created_at_ms DESC, record_id DESC LIMIT ? OFFSET ?', args);
    const items: RecordSummary[] = [];
    let sawExtra: boolean = false;
    try {
      while (resultSet.goToNextRow()) {
        if (items.length >= safeSize) {
          sawExtra = true;
          break;
        }
        const summary: RecordSummary | null = readSummaryRow(resultSet);
        if (summary !== null) {
          items.push(summary);
        }
      }
    } finally {
      resultSet.close();
    }
    const result: RecordPage = {
      items: items,
      page: safePage,
      pageSize: safeSize,
      hasMore: sawExtra
    };
    return result;
  }

  /** 详情查询；不存在返回 null。 */
  async getDetail(recordId: string): Promise<RecordDetail | null> {
    const store: relationalStore.RdbStore = await this.ensureStore();
    const resultSet: relationalStore.ResultSet = await store.querySql(
      `SELECT ${ROW_COLUMNS} FROM ${TABLE_RECORDS} WHERE record_id = ?`, [recordId]);
    try {
      if (!resultSet.goToNextRow()) {
        return null;
      }
      const row: RecordRow | null = readRow(resultSet);
      if (row === null) {
        return null;
      }
      return toDetail(row);
    } finally {
      resultSet.close();
    }
  }

  /**
   * 删除记录：事务内删 RDB 行，随后删除图像文件（契约 5.2/5.3）。
   * 幂等：不存在返回 deleted=false。文件删除失败不阻塞（留待启动孤儿清理）。
   */
  async delete(recordId: string): Promise<RecordDeleteResult> {
    const store: relationalStore.RdbStore = await this.ensureStore();
    let imagePath: string = '';
    let thumbnailPath: string = '';
    let found: boolean = false;
    await RecordDatabase.runInTransaction(store, async (): Promise<void> => {
      const resultSet: relationalStore.ResultSet = await store.querySql(
        `SELECT image_path, thumbnail_path FROM ${TABLE_RECORDS} WHERE record_id = ?`, [recordId]);
      try {
        found = resultSet.goToNextRow();
        if (found) {
          imagePath = resultSet.getString(0);
          thumbnailPath = resultSet.getString(1);
        }
      } finally {
        resultSet.close();
      }
      if (found) {
        await store.executeSql(`DELETE FROM ${TABLE_RECORDS} WHERE record_id = ?`, [recordId]);
      }
    });
    if (!found) {
      const result: RecordDeleteResult = { deleted: false };
      return result;
    }
    try {
      const context: common.Context = this.resolveContext();
      await ImageAssetStore.getInstance().deleteImages(context, imagePath, thumbnailPath);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'delete images for %{public}s failed: %{public}s', recordId, JSON.stringify(e));
    }
    hilog.info(DOMAIN, TAG, 'Deleted record %{public}s', recordId);
    const result: RecordDeleteResult = { deleted: true };
    return result;
  }

  /**
   * 按类别查询：原始或编辑后任一框含该类即匹配（契约 4.1）。
   * 框存于 JSON 列，本阶段不拆表，故读取行后内存过滤；按 created_at_ms 降序。
   */
  async listByClass(classId: number, limit?: number): Promise<RecordSummary[]> {
    const store: relationalStore.RdbStore = await this.ensureStore();
    const maxItems: number = limit === undefined ? DEFAULT_CLASS_LIMIT : Math.max(1, Math.floor(limit));
    const resultSet: relationalStore.ResultSet = await store.querySql(
      `SELECT ${ROW_COLUMNS} FROM ${TABLE_RECORDS} ORDER BY created_at_ms DESC, record_id DESC`, []);
    const items: RecordSummary[] = [];
    try {
      while (resultSet.goToNextRow() && items.length < maxItems) {
        const row: RecordRow | null = readRow(resultSet);
        if (row === null) {
          continue;
        }
        const rawBoxes: DetectionBox[] = parseBoxes(row.rawBoxesJson);
        const editedBoxes: DetectionBox[] = parseBoxes(row.editedBoxesJson);
        if (!containsClass(rawBoxes, classId) && !containsClass(editedBoxes, classId)) {
          continue;
        }
        items.push(toSummary(row, editedBoxes));
      }
    } finally {
      resultSet.close();
    }
    return items;
  }

  /** 时间范围内记录数，闭区间 [fromMs, toMs]（"本周识别 N 次"统计）。 */
  async countByTimeRange(fromMs: number, toMs: number): Promise<number> {
    const store: relationalStore.RdbStore = await this.ensureStore();
    const resultSet: relationalStore.ResultSet = await store.querySql(
      `SELECT COUNT(*) FROM ${TABLE_RECORDS} WHERE created_at_ms >= ? AND created_at_ms <= ?`,
      [fromMs, toMs]);
    try {
      if (!resultSet.goToNextRow()) {
        return 0;
      }
      return resultSet.getLong(0);
    } finally {
      resultSet.close();
    }
  }

  /** 释放 RDB 连接；之后调用会触发重新初始化。 */
  async dispose(): Promise<void> {
    const store: relationalStore.RdbStore | null = this.store;
    this.store = null;
    this.initPromise = null;
    if (store !== null) {
      try {
        await store.close();
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'close store failed: %{public}s', JSON.stringify(e));
      }
    }
  }

  /**
   * 启动孤儿清理（契约 5.3）：RDB 打开成功后执行；把全部 record_id 交给
   * ImageAssetStore 判定文件名 id 不在集合中的图像文件并删除。
   * 上限（200）与 mtime 宽限（10 分钟）由 ImageAssetStore 常量保证，
   * 避免误删正在保存流程中的新文件。失败不阻塞初始化。
   */
  private async cleanupOrphans(context: common.Context, store: relationalStore.RdbStore): Promise<void> {
    try {
      const recordIds: Array<string> = [];
      const resultSet: relationalStore.ResultSet = await store.querySql(
        `SELECT record_id FROM ${TABLE_RECORDS}`, []);
      try {
        while (resultSet.goToNextRow()) {
          recordIds.push(resultSet.getString(0));
        }
      } finally {
        resultSet.close();
      }
      const removed: number =
        await ImageAssetStore.getInstance().cleanupOrphanRecordImages(context, recordIds);
      if (removed > 0) {
        hilog.info(DOMAIN, TAG, 'Orphan cleanup: %{public}d files removed', removed);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'orphan cleanup failed: %{public}s', JSON.stringify(e));
    }
  }
}

// ---------------- 行解析与类型映射 ----------------

function clampPageSize(pageSize: number): number {
  if (!Number.isFinite(pageSize) || pageSize < 1) {
    return DEFAULT_PAGE_SIZE;
  }
  const size: number = Math.floor(pageSize);
  return size > MAX_PAGE_SIZE ? MAX_PAGE_SIZE : size;
}

/** 读取当前行全部列；数值/字符串类型不符时返回 null（视为损坏行）。 */
function readRow(resultSet: relationalStore.ResultSet): RecordRow | null {
  try {
    const row: RecordRow = {
      recordId: resultSet.getString(0),
      createdAtMs: resultSet.getLong(1),
      source: resultSet.getString(2),
      modelId: resultSet.getString(3),
      modelSha256: resultSet.getString(4),
      imagePath: resultSet.getString(5),
      thumbnailPath: resultSet.getString(6),
      imageWidth: resultSet.getLong(7),
      imageHeight: resultSet.getLong(8),
      coldStart: resultSet.getLong(9),
      totalMs: resultSet.getLong(10),
      executionMode: resultSet.getString(11),
      rawBoxesJson: resultSet.getString(12),
      editedBoxesJson: resultSet.getString(13)
    };
    return row;
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'read row failed: %{public}s', JSON.stringify(e));
    return null;
  }
}

/** 解析检测框 JSON；解析失败按空数组处理并记日志（损坏行不拖垮查询）。 */
function parseBoxes(json: string): DetectionBox[] {
  try {
    const parsed: DetectionBox[] = JSON.parse(json) as DetectionBox[];
    if (Array.isArray(parsed)) {
      return parsed;
    }
    return [];
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'parse boxes failed: %{public}s', JSON.stringify(e));
    return [];
  }
}

function parseSource(value: string): ImageOrigin {
  return value === ImageOrigin.CAMERA ? ImageOrigin.CAMERA : ImageOrigin.GALLERY;
}

function parseExecutionMode(value: string): InferenceExecutionMode {
  return value === InferenceExecutionMode.SYNC ? InferenceExecutionMode.SYNC : InferenceExecutionMode.TASK_POOL;
}

/** 编辑后框中置信度最高者的类别名与置信度；空结果给空串与 0。 */
function topOf(boxes: DetectionBox[]): TopBoxInfo {
  let label: string = '';
  let confidence: number = 0;
  for (const box of boxes) {
    if (box.confidence > confidence || label.length === 0) {
      label = box.label;
      confidence = box.confidence;
    }
  }
  const top: TopBoxInfo = { label: label, confidence: confidence };
  return top;
}

function toSummary(row: RecordRow, editedBoxes: DetectionBox[]): RecordSummary {
  const top: TopBoxInfo = topOf(editedBoxes);
  const summary: RecordSummary = {
    recordId: row.recordId,
    createdAtMs: row.createdAtMs,
    source: parseSource(row.source),
    thumbnailPath: row.thumbnailPath,
    imageWidth: row.imageWidth,
    imageHeight: row.imageHeight,
    editedBoxCount: editedBoxes.length,
    editedTopClassLabel: top.label,
    editedTopConfidence: top.confidence,
    executionMode: parseExecutionMode(row.executionMode),
    totalMs: row.totalMs
  };
  return summary;
}

function toDetail(row: RecordRow): RecordDetail {
  const detail: RecordDetail = {
    recordId: row.recordId,
    createdAtMs: row.createdAtMs,
    source: parseSource(row.source),
    modelId: row.modelId,
    modelSha256: row.modelSha256,
    imagePath: row.imagePath,
    thumbnailPath: row.thumbnailPath,
    imageWidth: row.imageWidth,
    imageHeight: row.imageHeight,
    rawBoxes: parseBoxes(row.rawBoxesJson),
    editedBoxes: parseBoxes(row.editedBoxesJson),
    coldStart: row.coldStart !== 0,
    totalMs: row.totalMs,
    executionMode: parseExecutionMode(row.executionMode)
  };
  return detail;
}

/** list 行 → 摘要；JSON 损坏时返回 null 跳过该行。 */
function readSummaryRow(resultSet: relationalStore.ResultSet): RecordSummary | null {
  const row: RecordRow | null = readRow(resultSet);
  if (row === null) {
    return null;
  }
  return toSummary(row, parseBoxes(row.editedBoxesJson));
}

function containsClass(boxes: DetectionBox[], classId: number): boolean {
  for (const box of boxes) {
    if (box.classId === classId) {
      return true;
    }
  }
  return false;
}

/** 绝对路径归一化为相对 filesDir 路径入库（重启后可移植）；不在 filesDir 下时原样保留。 */
function toRelativePath(context: common.Context, path: string): string {
  const prefix: string = `${context.filesDir}/`;
  if (path.startsWith(prefix)) {
    return path.substring(prefix.length);
  }
  return path;
}

/**
 * 从 originalPath（相对或绝对）文件名提取 assetId：rec_xxx_original.jpg → rec_xxx。
 * 不匹配 Agent 1 命名约定时返回空串，调用方退化为自生成 id。
 */
function extractAssetId(originalPath: string): string {
  const slash: number = originalPath.lastIndexOf('/');
  const base: string = slash >= 0 ? originalPath.substring(slash + 1) : originalPath;
  if (base.startsWith('rec_') && base.endsWith(ORIGINAL_FILE_SUFFIX)) {
    return base.substring(0, base.length - ORIGINAL_FILE_SUFFIX.length);
  }
  return '';
}
