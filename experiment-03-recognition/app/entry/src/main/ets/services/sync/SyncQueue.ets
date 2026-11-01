/**
 * 上传队列（第三阶段，Agent 4）。依据 docs/phase-3-contract.md 第 3.3 节。
 *
 * - 队列持久化到 Preferences（`sync_queue`），应用重启后待传记录不丢失；
 *   RDB v1 schema 无同步状态列（契约 §6 列为后续迁移），故以 Preferences 为准。
 * - 幂等：同一 recordId 多次 enqueue 只入队一次；已 UPLOADED 的不重置。
 * - 重试：最多 3 次，指数退避 5s / 30s / 5min；3 次失败转 FAILED 等手动重试。
 *
 * SyncStatus 契约要求由 Agent 0 在 models/RecordTypes.ets 扩展；当前未定稿，
 * 暂在本文件定义，Agent 0 扩展后此处改为 re-export（协调项见 phase-3-agent-4-report）。
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'SyncQueue';
const DOMAIN: number = 0x0000;

const PREF_NAME: string = 'sync_queue';
const KEY_ENTRIES: string = 'entries';

const MAX_ATTEMPTS: number = 3;
/** 退避毫秒：第 1/2/3 次失败后分别等待 5s / 30s / 5min。 */
const BACKOFF_MS: number[] = [5 * 1000, 30 * 1000, 5 * 60 * 1000];

export enum SyncStatus {
  PENDING = 'PENDING',
  UPLOADED = 'UPLOADED',
  CONFLICT = 'CONFLICT',
  FAILED = 'FAILED'
}

export interface SyncEntry {
  recordId: string;
  status: SyncStatus;
  /** 已失败次数（0..3）。 */
  attempts: number;
  /** 下次允许重试的时刻；PENDING 且 now >= nextRetryAtMs 才可上传。 */
  nextRetryAtMs: number;
  /** 最近一次失败原因（网络错误或后端 message）。 */
  lastError: string;
  enqueuedAtMs: number;
}

export class SyncQueue {
  private static instance: SyncQueue | null = null;

  static getInstance(): SyncQueue {
    if (SyncQueue.instance === null) {
      SyncQueue.instance = new SyncQueue();
    }
    return SyncQueue.instance;
  }

  private pref: preferences.Preferences | null = null;
  private context: common.Context | null = null;
  private entries: Map<string, SyncEntry> = new Map();
  private initPromise: Promise<boolean> | null = null;

  private constructor() {
  }

  /** 幂等初始化；加载持久化队列。 */
  async initialize(context?: common.Context): Promise<boolean> {
    if (context !== undefined) {
      this.context = context;
    }
    if (this.pref !== null) {
      return true;
    }
    if (this.initPromise === null) {
      this.initPromise = this.doInitialize();
    }
    const ok: boolean = await this.initPromise;
    if (!ok) {
      this.initPromise = null;
    }
    return ok;
  }

  private async doInitialize(): Promise<boolean> {
    try {
      const context: common.Context = this.resolveContext();
      this.pref = preferences.getPreferencesSync(context, { name: PREF_NAME });
      this.loadFromPref();
      hilog.info(DOMAIN, TAG, 'queue loaded, size=%{public}d', this.entries.size);
      return true;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'init failed: %{public}s', JSON.stringify(e));
      this.pref = null;
      return false;
    }
  }

  /** 从 Preferences 读取数组形式的队列（ArkTS 不支持索引签名，不用 map 持久化）。 */
  private loadFromPref(): void {
    if (this.pref === null) {
      return;
    }
    const text: string = this.pref.getSync(KEY_ENTRIES, '[]') as string;
    const arr: SyncEntry[] = JSON.parse(text) as SyncEntry[];
    this.entries.clear();
    arr.forEach((entry: SyncEntry) => {
      this.entries.set(entry.recordId, entry);
    });
  }

  private resolveContext(): common.Context {
    if (this.context !== null) {
      return this.context;
    }
    const context: common.Context = getContext() as common.Context;
    this.context = context;
    return context;
  }

  private ensureReady(): boolean {
    if (this.pref !== null) {
      return true;
    }
    // 懒初始化兜底：enqueue 可能由 RecordService 在后台触发。
    try {
      this.pref = preferences.getPreferencesSync(this.resolveContext(), { name: PREF_NAME });
      this.loadFromPref();
      return true;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'lazy init failed: %{public}s', JSON.stringify(e));
      this.pref = null;
      return false;
    }
  }

  private persist(): void {
    if (this.pref === null) {
      return;
    }
    const arr: SyncEntry[] = [];
    this.entries.forEach((entry: SyncEntry) => {
      arr.push(entry);
    });
    this.pref.putSync(KEY_ENTRIES, JSON.stringify(arr));
    this.pref.flush();
  }

  /**
   * 入队一条记录。幂等：已存在且非 FAILED 的条目不重置；
   * FAILED 条目重新入队时清零重试计数（手动/自动再尝试）。
   */
  enqueue(recordId: string): void {
    if (!this.ensureReady()) {
      hilog.warn(DOMAIN, TAG, 'enqueue skipped, queue not ready: %{public}s', recordId);
      return;
    }
    const existing: SyncEntry | undefined = this.entries.get(recordId);
    if (existing !== undefined) {
      if (existing.status === SyncStatus.FAILED) {
        existing.status = SyncStatus.PENDING;
        existing.attempts = 0;
        existing.nextRetryAtMs = 0;
        this.persist();
      }
      return;
    }
    const entry: SyncEntry = {
      recordId: recordId,
      status: SyncStatus.PENDING,
      attempts: 0,
      nextRetryAtMs: 0,
      lastError: '',
      enqueuedAtMs: Date.now()
    };
    this.entries.set(recordId, entry);
    this.persist();
    hilog.info(DOMAIN, TAG, 'enqueued %{public}s', recordId);
  }

  /** 当前可上传的条目：PENDING 且到达重试时间，按入队先后排序。 */
  dueEntries(): SyncEntry[] {
    const now: number = Date.now();
    const due: SyncEntry[] = [];
    this.entries.forEach((entry: SyncEntry) => {
      if (entry.status === SyncStatus.PENDING && entry.nextRetryAtMs <= now) {
        due.push(entry);
      }
    });
    due.sort((a: SyncEntry, b: SyncEntry) => a.enqueuedAtMs - b.enqueuedAtMs);
    return due;
  }

  /** 待传数量（PENDING）。 */
  pendingCount(): number {
    let count: number = 0;
    this.entries.forEach((entry: SyncEntry) => {
      if (entry.status === SyncStatus.PENDING) {
        count++;
      }
    });
    return count;
  }

  /** 查询同步状态；从未入队返回 null。 */
  getStatus(recordId: string): SyncStatus | null {
    const entry: SyncEntry | undefined = this.entries.get(recordId);
    return entry === undefined ? null : entry.status;
  }

  /** 上传成功（created / duplicate 均视为成功，契约 §3.2）。 */
  markUploaded(recordId: string): void {
    const entry: SyncEntry | undefined = this.entries.get(recordId);
    if (entry === undefined) {
      return;
    }
    entry.status = SyncStatus.UPLOADED;
    entry.lastError = '';
    this.persist();
  }

  /** 载荷与服务端已有记录不一致，需用户确认；不再自动重试。 */
  markConflict(recordId: string, message: string): void {
    const entry: SyncEntry | undefined = this.entries.get(recordId);
    if (entry === undefined) {
      return;
    }
    entry.status = SyncStatus.CONFLICT;
    entry.lastError = message;
    this.persist();
  }

  /** 永久失败（后端 invalid）：不再自动重试。 */
  markFailed(recordId: string, message: string): void {
    const entry: SyncEntry | undefined = this.entries.get(recordId);
    if (entry === undefined) {
      return;
    }
    entry.status = SyncStatus.FAILED;
    entry.lastError = message;
    this.persist();
  }

  /**
   * 一次可恢复失败（网络 / 5xx）：计数 +1，按 5s/30s/5min 退避；
   * 达到 MAX_ATTEMPTS 转 FAILED。
   */
  scheduleRetry(recordId: string, error: string): void {
    const entry: SyncEntry | undefined = this.entries.get(recordId);
    if (entry === undefined) {
      return;
    }
    entry.attempts += 1;
    entry.lastError = error;
    if (entry.attempts >= MAX_ATTEMPTS) {
      entry.status = SyncStatus.FAILED;
      hilog.warn(DOMAIN, TAG, '%{public}s failed after %{public}d attempts: %{public}s',
        recordId, entry.attempts, error);
    } else {
      const backoff: number = BACKOFF_MS[Math.min(entry.attempts - 1, BACKOFF_MS.length - 1)];
      entry.nextRetryAtMs = Date.now() + backoff;
      hilog.info(DOMAIN, TAG, '%{public}s retry %{public}d in %{public}dms',
        recordId, entry.attempts, backoff);
    }
    this.persist();
  }

  /** 记录本地已删除 / 详情缺失时移除队列条目。 */
  remove(recordId: string): void {
    if (this.entries.delete(recordId)) {
      this.persist();
    }
  }

  /** 队列快照，供 UI 展示。 */
  snapshot(): SyncEntry[] {
    const list: SyncEntry[] = [];
    this.entries.forEach((entry: SyncEntry) => {
      list.push(entry);
    });
    return list;
  }
}
