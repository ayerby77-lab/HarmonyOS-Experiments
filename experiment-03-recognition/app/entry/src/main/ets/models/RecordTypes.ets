/**
 * 第二阶段本地识别记录 共享类型。由 Agent 0 冻结。
 *
 * 实际实现参照：services/imaging/ImageAssetStore.ets（Agent 1 已交付）。
 * 关联 DetectionTypes.ets / ImageTypes.ets（第一阶段共享契约）。
 */
import { DetectionBox, InferenceExecutionMode } from './DetectionTypes';
import { ImageOrigin } from './ImageTypes';

/**
 * ImageAssetStore 导出常量（Agent 1）。这里的镜像值必须与 ImageAssetStore 保持同步。
 *
 * 文件布局：`filesDir/records/{assetId}_original.jpg` + `{assetId}_thumb.jpg`（扁平，无子目录）。
 */
export const IMAGES_ROOT: string = 'records';
export const THUMBNAIL_MAX_EDGE: number = 480;
export const THUMBNAIL_JPEG_QUALITY: number = 80;
export const ORIGINAL_JPEG_QUALITY: number = 90;

/** 记录摘要：用于列表页展示。 */
export interface RecordSummary {
  recordId: string;
  createdAtMs: number;
  source: ImageOrigin;
  /** 相对 filesDir 的路径，如 records/{assetId}_thumb.jpg。 */
  thumbnailPath: string;
  imageWidth: number;
  imageHeight: number;
  /** 编辑后的检测框数量；未编辑时与原始框数相同。 */
  editedBoxCount: number;
  /** 编辑后置信度最高的类别名（用于列表副标题）。 */
  editedTopClassLabel: string;
  /** 编辑后置信度最高的框的置信度值。 */
  editedTopConfidence: number;
  executionMode: InferenceExecutionMode;
  totalMs: number;
}

/** 记录详情：含原始检测框和编辑后检测框。 */
export interface RecordDetail {
  recordId: string;
  createdAtMs: number;
  source: ImageOrigin;
  modelId: string;
  modelSha256: string;
  /** 原图相对路径：records/{assetId}_original.jpg。 */
  imagePath: string;
  thumbnailPath: string;
  imageWidth: number;
  imageHeight: number;
  /** 原始检测框：模型直接输出 + NMS + 坐标还原后的状态，永不改变。 */
  rawBoxes: DetectionBox[];
  /** 编辑后检测框：用户可能改类别、删框、加标注。未编辑时与 rawBoxes 相同。 */
  editedBoxes: DetectionBox[];
  coldStart: boolean;
  totalMs: number;
  executionMode: InferenceExecutionMode;
}

/** 分页结果。按 created_at_ms 降序排列。 */
export interface RecordPage {
  items: RecordSummary[];
  page: number;       // 1-based
  pageSize: number;
  /** 数据层是否还有下一页。false 表示最后一页。 */
  hasMore: boolean;
}

/** 存储相关错误码。与 ImageAssetError（Agent 1）映射关系：
 *  - io-failed     → IMAGE_COPY_FAILED
 *  - encode-failed → THUMBNAIL_FAILED
 *  - invalid-input → UNKNOWN（调用方入参问题）
 */
export enum RecordErrorCode {
  RECORD_NOT_FOUND = 'RECORD_NOT_FOUND',
  DB_INIT_FAILED = 'DB_INIT_FAILED',
  DB_WRITE_FAILED = 'DB_WRITE_FAILED',
  IMAGE_COPY_FAILED = 'IMAGE_COPY_FAILED',
  THUMBNAIL_FAILED = 'THUMBNAIL_FAILED',
  UNKNOWN = 'RECORD_UNKNOWN'
}

/** initialize() 返回值。 */
export interface RecordInitResult {
  initialized: boolean;
  error?: string;
}

/** save() 的 modelResult 参数。 */
export interface RecordSaveInput {
  boxes: DetectionBox[];
  modelId: string;
  modelSha256: string;
  imageWidth: number;
  imageHeight: number;
  coldStart: boolean;
  totalMs: number;
  executionMode: InferenceExecutionMode;
}

/** delete() 返回值。 */
export interface RecordDeleteResult {
  deleted: boolean;
}

/** 本地记录存储服务接口。Agent 4 实现。 */
export interface RecordServiceApi {
  /**
   * 初始化 RDB。必须在 EntryAbility.onWindowStageCreate 的 loadContent 之前调用。
   * 失败时返回 initialized=false，页面以空列表启动。
   * 成功后执行一次孤儿图像目录清理（最多 200 个目录）。
   */
  initialize(): Promise<RecordInitResult>;

  /**
   * 保存一条识别结果。
   *
   * 调用约定：调用方先调用 ImageAssetStore.persistCapturedImage 生成
   * originalPath / thumbnailPath（相对路径），再传给本方法。
   * RDB 写入失败时调用方有责任调用 ImageAssetStore.deleteImages 回滚文件。
   *
   * @param modelResult 识别结果关键信息
   * @param source 图像来源 'camera' 或 'gallery'
   * @param originalPath ImageAssetStore 返回的原图相对路径
   * @param thumbnailPath ImageAssetStore 返回的缩略图相对路径
   * @returns 生成的 recordId
   */
  save(
    modelResult: RecordSaveInput,
    source: ImageOrigin,
    originalPath: string,
    thumbnailPath: string
  ): Promise<string>;

  /**
   * 更新编辑后的检测框。只改 edited_boxes_json，不动 raw_boxes_json。
   * @returns 更新后的完整详情（供 UI 刷新）
   * @throws RecordErrorCode.RECORD_NOT_FOUND
   */
  updateEdited(recordId: string, editedBoxes: DetectionBox[]): Promise<RecordDetail>;

  /**
   * 分页列表。按 created_at_ms 降序。
   *
   * @param page 从 1 开始
   * @param pageSize 每页条数，默认 20，最大 50；超出范围 clamp 到 [1,50]
   * @param sourceFilter 可选：只返回 camera 或 gallery
   */
  list(
    page: number,
    pageSize: number,
    sourceFilter?: ImageOrigin
  ): Promise<RecordPage>;

  /** 详情查询；找不到返回 null。 */
  getDetail(recordId: string): Promise<RecordDetail | null>;

  /**
   * 删除记录。级联删除 RDB 行；返回调用方负责删图片（幂等）。
   * 幂等：recordId 不存在时返回 deleted=false，不抛异常。
   */
  delete(recordId: string): Promise<RecordDeleteResult>;

  /**
   * 按类别查询（editedBoxes 包含该 classId 的记录）。
   * 未编辑时 editedBoxes == rawBoxes，逻辑覆盖全部。
   * @param limit 默认 50，最大 200；超出 clamp 到 [1,200]
   */
  listByClass(classId: number, limit?: number): Promise<RecordSummary[]>;

  /** 时间范围内的记录数。用于"本周识别 N 次"统计。 */
  countByTimeRange(fromMs: number, toMs: number): Promise<number>;

  /** 释放 RDB 连接。EntryAbility.onDestroy 中调用。 */
  dispose(): Promise<void>;
}
