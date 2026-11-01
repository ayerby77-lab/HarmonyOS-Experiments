/**
 * 记录上传服务（第三阶段，Agent 4）。依据 docs/phase-3-contract.md 第 3 节。
 *
 * - 串行上传：单次 flush 内逐条处理，并发调用去重（flushing 标志）；
 * - 幂等：每条记录带 recordId，后端按 (deviceId, recordId) 去重；
 *   created / duplicate 均视为成功（契约 §3.2）；
 * - 断网重传：网络/5xx 失败保留队列并退避，网络恢复后由 SyncManager 触发重试；
 * - conflict / invalid 不再自动重试。
 *
 * RDB v1 缺 requestId / imageId / recognizedAtMs / isMirrored / 阈值 / 分段耗时，
 * 组装上传体时使用文档化默认值（见 assemble 注释与 phase-3-agent-4-report 协调项）。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DetectionBox } from '../../models/DetectionTypes';
import { RecordDetail } from '../../models/RecordTypes';
import { RecordService } from '../storage/RecordService';
import { HttpClient, NetworkErrorCode, NetworkFailure } from '../network/HttpClient';
import { SyncQueue, SyncStatus } from './SyncQueue';

const TAG: string = 'UploadService';
const DOMAIN: number = 0x0000;

const SCHEMA_VERSION: number = 1;
const UPLOAD_PATH: string = '/api/records';

/** 阈值默认值：RDB v1 未落库，与推理默认一致（协调项：v2 增列后替换）。 */
const DEFAULT_CONFIDENCE_THRESHOLD: number = 0.25;
const DEFAULT_IOU_THRESHOLD: number = 0.45;
const DEFAULT_MAX_DETECTIONS: number = 100;

interface ModelRefBody {
  modelId: string;
  sha256: string;
}

interface InferenceOptionsBody {
  confidenceThreshold: number;
  iouThreshold: number;
  maxDetections: number;
  executionMode: string;
}

interface InferenceTimingBody {
  preprocessMs: number;
  inferenceMs: number;
  postprocessMs: number;
  totalMs: number;
  coldStart: boolean;
  modelLoadMs: number;
}

interface DetectionItemBody {
  detectionId: string;
  rawIndex: number;
  rawClassId: number;
  rawLabel: string;
  classId: number;
  label: string;
  confidence: number;
  left: number;
  top: number;
  right: number;
  bottom: number;
  deleted: boolean;
  classCorrected: boolean;
  editedAtMs: number | null;
}

interface CountItemBody {
  classId: number;
  label: string;
  count: number;
}

/** 与后端 RecordUploadItem 对齐（backend/app/schemas/records.py）。 */
interface RecordUploadItemBody {
  schemaVersion: number;
  recordId: string;
  requestId: string;
  imageId: string;
  capturedAtMs: number;
  recognizedAtMs: number;
  savedAtMs: number;
  editedAtMs: number | null;
  imageWidth: number;
  imageHeight: number;
  isMirrored: boolean;
  imageOrigin: string;
  model: ModelRefBody;
  options: InferenceOptionsBody;
  timing: InferenceTimingBody;
  rawDetectionCount: number;
  edited: boolean;
  detections: DetectionItemBody[];
  counts: CountItemBody[];
}

interface RecordBatchRequestBody {
  schemaVersion: number;
  records: RecordUploadItemBody[];
}

interface RecordUploadResultBody {
  recordId: string;
  status: string;
  serverRevision: string | null;
  code: string | null;
  message: string | null;
}

interface RecordBatchResponseBody {
  results: RecordUploadResultBody[];
}

export class UploadService {
  private static instance: UploadService | null = null;

  static getInstance(): UploadService {
    if (UploadService.instance === null) {
      UploadService.instance = new UploadService();
    }
    return UploadService.instance;
  }

  private flushing: boolean = false;

  private constructor() {
  }

  isFlushing(): boolean {
    return this.flushing;
  }

  /**
   * 串行上传队列中到期的记录。并发调用去重：进行中直接返回空。
   * 遇到网络级失败（断网 / 5xx / 鉴权失败）中止本轮，保留其余条目待下次触发。
   * @returns 本次成功上传（created/duplicate）的 recordId 列表。
   */
  async flush(): Promise<string[]> {
    if (this.flushing) {
      return [];
    }
    this.flushing = true;
    const uploaded: string[] = [];
    try {
      const queue: SyncQueue = SyncQueue.getInstance();
      const due = queue.dueEntries();
      for (const entry of due) {
        const ok: boolean = await this.uploadOne(entry.recordId);
        if (!ok) {
          // 网络级失败：中断本轮，避免把队列全部烧完重试次数。
          break;
        }
        if (queue.getStatus(entry.recordId) === SyncStatus.UPLOADED) {
          uploaded.push(entry.recordId);
        }
      }
    } finally {
      this.flushing = false;
    }
    return uploaded;
  }

  /**
   * 上传单条记录。
   * @returns true=本条已处理（成功或业务终态），可继续下一条；false=网络级失败，中止本轮。
   */
  private async uploadOne(recordId: string): Promise<boolean> {
    const queue: SyncQueue = SyncQueue.getInstance();
    try {
      const detail: RecordDetail | null = await RecordService.getInstance().getDetail(recordId);
      if (detail === null) {
        // 本地已删除：移出队列，无需上传。
        queue.remove(recordId);
        return true;
      }
      const body: RecordBatchRequestBody = {
        schemaVersion: SCHEMA_VERSION,
        records: [assembleUploadItem(detail)]
      };
      const resp: RecordBatchResponseBody =
        await HttpClient.getInstance().post<RecordBatchResponseBody>(UPLOAD_PATH, body);
      const result: RecordUploadResultBody | undefined =
        resp.results.find((r: RecordUploadResultBody) => r.recordId === recordId);
      if (result === undefined) {
        queue.scheduleRetry(recordId, '响应缺少该 recordId 的结果');
        return false;
      }
      switch (result.status) {
        case 'created':
        case 'duplicate':
          queue.markUploaded(recordId);
          hilog.info(DOMAIN, TAG, '%{public}s uploaded (%{public}s)', recordId, result.status);
          return true;
        case 'conflict':
          queue.markConflict(recordId, result.message ?? '载荷与服务端不一致');
          hilog.warn(DOMAIN, TAG, '%{public}s conflict: %{public}s', recordId, result.message ?? '');
          return true;
        default:
          queue.markFailed(recordId, result.message ?? `invalid: ${result.code ?? ''}`);
          hilog.warn(DOMAIN, TAG, '%{public}s invalid: %{public}s', recordId, result.message ?? '');
          return true;
      }
    } catch (e) {
      if (e instanceof NetworkFailure) {
        queue.scheduleRetry(recordId, `${e.code}: ${e.message}`);
        hilog.warn(DOMAIN, TAG, '%{public}s upload failed (%{public}s: %{public}s), retry scheduled',
          recordId, e.code, e.message);
        if (e.code === NetworkErrorCode.UNAUTHORIZED || e.code === NetworkErrorCode.FORBIDDEN) {
          hilog.warn(DOMAIN, TAG, 'auth rejected, abort flush: %{public}s', e.message);
        }
        return false;
      }
      hilog.warn(DOMAIN, TAG, '%{public}s upload unknown error: %{public}s', recordId, JSON.stringify(e));
      queue.scheduleRetry(recordId, `未知错误: ${JSON.stringify(e)}`);
      return false;
    }
  }
}

/**
 * 由本地 RecordDetail 组装后端 RecordUploadItem。
 * RDB v1 未落库的字段使用默认值：requestId/imageId 取 recordId，
 * capturedAtMs/recognizedAtMs/savedAtMs 取 createdAtMs，isMirrored=false，
 * 阈值用推理默认值，分段耗时仅 totalMs 可信、其余为 0。
 */
export function assembleUploadItem(detail: RecordDetail): RecordUploadItemBody {
  const edited: boolean = JSON.stringify(detail.rawBoxes) !== JSON.stringify(detail.editedBoxes);
  const detections: DetectionItemBody[] = detail.editedBoxes.map((box: DetectionBox, index: number) => {
    const raw: DetectionBox | undefined = detail.rawBoxes[index];
    const item: DetectionItemBody = {
      detectionId: `${detail.recordId}_d${index}`,
      rawIndex: index,
      rawClassId: raw !== undefined ? raw.classId : box.classId,
      rawLabel: raw !== undefined ? raw.label : box.label,
      classId: box.classId,
      label: box.label,
      confidence: box.confidence,
      left: box.left,
      top: box.top,
      right: box.right,
      bottom: box.bottom,
      deleted: false,
      classCorrected: raw !== undefined ? raw.classId !== box.classId : false,
      editedAtMs: null
    };
    return item;
  });
  const counts: CountItemBody[] = computeCounts(detail.editedBoxes);
  const item: RecordUploadItemBody = {
    schemaVersion: SCHEMA_VERSION,
    recordId: detail.recordId,
    requestId: detail.recordId,
    imageId: detail.recordId,
    capturedAtMs: detail.createdAtMs,
    recognizedAtMs: detail.createdAtMs,
    savedAtMs: detail.createdAtMs,
    editedAtMs: edited ? detail.createdAtMs : null,
    imageWidth: detail.imageWidth,
    imageHeight: detail.imageHeight,
    isMirrored: false,
    imageOrigin: detail.source as string,
    model: { modelId: detail.modelId, sha256: detail.modelSha256 },
    options: {
      confidenceThreshold: DEFAULT_CONFIDENCE_THRESHOLD,
      iouThreshold: DEFAULT_IOU_THRESHOLD,
      maxDetections: DEFAULT_MAX_DETECTIONS,
      executionMode: detail.executionMode as string
    },
    timing: {
      preprocessMs: 0,
      inferenceMs: 0,
      postprocessMs: 0,
      totalMs: detail.totalMs,
      coldStart: detail.coldStart,
      modelLoadMs: 0
    },
    rawDetectionCount: detail.rawBoxes.length,
    edited: edited,
    detections: detections,
    counts: counts
  };
  return item;
}

/** 按最终类别（编辑后框）分组计数：count 降序、classId 升序，与服务端重算规则一致。 */
function computeCounts(boxes: DetectionBox[]): CountItemBody[] {
  const groups: Map<number, CountItemBody> = new Map();
  boxes.forEach((box: DetectionBox) => {
    const existing: CountItemBody | undefined = groups.get(box.classId);
    if (existing !== undefined) {
      existing.count += 1;
    } else {
      groups.set(box.classId, { classId: box.classId, label: box.label, count: 1 });
    }
  });
  const list: CountItemBody[] = [];
  groups.forEach((item: CountItemBody) => {
    list.push(item);
  });
  list.sort((a: CountItemBody, b: CountItemBody) => {
    if (b.count !== a.count) {
      return b.count - a.count;
    }
    return a.classId - b.classId;
  });
  return list;
}
