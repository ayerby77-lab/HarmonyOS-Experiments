/**
 * 同步调度器（第三阶段，Agent 4）。依据 docs/phase-3-contract.md 第 3 节。
 *
 * - 统一入口：初始化时配置 HttpClient/AuthStore/SyncQueue，监听网络状态；
 * - 触发时机：RecordService.save 成功（onRecordSaved）、用户手动（syncNow）、
 *   网络恢复（netAvailable）、应用启动（initialize 时 flush 一次，即 requeueStale：
 *   队列持久化在 Preferences，重启后自动恢复待传记录）；
 * - 上传前确保已登录（ensureValidToken），断网时跳过不消耗重试次数。
 *
 * 接入建议（Agent 0 / EntryAbility）：onWindowStageCreate 中
 *   void SyncManager.getInstance().initialize(this.context);
 * onDestroy 中 dispose()。
 */
import { connection } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AuthStore, DEV_CLIENT_KEY } from '../network/AuthStore';
import { HttpClient } from '../network/HttpClient';
import { SyncQueue, SyncEntry, SyncStatus } from './SyncQueue';
import { UploadService } from './UploadService';

const TAG: string = 'SyncManager';
const DOMAIN: number = 0x0000;

/** 网络级失败后的延迟重试间隔与连续上限（超过后等待下次 netAvailable/手动/重启触发）。 */
const RETRY_DELAY_MS: number = 8000;
const RETRY_KICK_LIMIT: number = 3;

export class SyncManager {
  private static instance: SyncManager | null = null;

  static getInstance(): SyncManager {
    if (SyncManager.instance === null) {
      SyncManager.instance = new SyncManager();
    }
    return SyncManager.instance;
  }

  private netConnection: connection.NetConnection | null = null;
  private initialized: boolean = false;
  /** 生产构建应由 build profile 注入（契约 §6）；当前为开发默认密钥。 */
  private clientKey: string = DEV_CLIENT_KEY;
  private retryTimerId: number = -1;
  private retryKicks: number = 0;

  private constructor() {
  }

  /** 可选：覆盖后端地址与密钥（默认 http://127.0.0.1:8000 + 开发密钥）。 */
  configure(baseUrl: string, clientKey?: string): void {
    HttpClient.getInstance().setBaseUrl(baseUrl);
    if (clientKey !== undefined) {
      this.clientKey = clientKey;
    }
  }

  /**
   * 初始化并立即尝试一轮上传（含重启后遗留队列，即契约 requeueStale 语义）。
   * 幂等。网络监听注册失败不影响本地功能。
   */
  async initialize(context?: common.Context): Promise<void> {
    if (this.initialized) {
      return;
    }
    if (context !== undefined) {
      // 透传给依赖的存储（它们各自有 getContext 兜底）。
      await AuthStore.getInstance().initialize(context);
      await SyncQueue.getInstance().initialize(context);
    } else {
      await AuthStore.getInstance().initialize();
      await SyncQueue.getInstance().initialize();
    }
    this.registerNetworkListener();
    this.initialized = true;
    hilog.info(DOMAIN, TAG, 'initialized, pending=%{public}d', SyncQueue.getInstance().pendingCount());
    void this.tryFlush();
  }

  /** 保存成功后触发：入队并立即尝试上传。 */
  onRecordSaved(recordId: string): void {
    SyncQueue.getInstance().enqueue(recordId);
    void this.tryFlush();
  }

  /** 手动触发上传（"同步"按钮）。返回本次成功上传的 recordId 列表。 */
  async syncNow(): Promise<string[]> {
    const queue: SyncQueue = SyncQueue.getInstance();
    // 手动触发忽略退避窗口：把 PENDING 条目的重试时间清零。
    queue.snapshot().forEach((entry: SyncEntry) => {
      if (entry.status === SyncStatus.PENDING) {
        entry.nextRetryAtMs = 0;
      }
    });
    return this.tryFlush();
  }

  /** 队列快照，供 UI 展示同步状态。 */
  snapshot(): SyncEntry[] {
    return SyncQueue.getInstance().snapshot();
  }

  dispose(): void {
    if (this.retryTimerId !== -1) {
      clearTimeout(this.retryTimerId);
      this.retryTimerId = -1;
    }
    this.retryKicks = 0;
    if (this.netConnection !== null) {
      this.netConnection.unregister((e) => {
        if (e) {
          hilog.warn(DOMAIN, TAG, 'unregister net listener: %{public}s', JSON.stringify(e));
        }
      });
      this.netConnection = null;
    }
    this.initialized = false;
  }

  private registerNetworkListener(): void {
    try {
      const netConn: connection.NetConnection = connection.createNetConnection();
      netConn.register((e) => {
        if (e) {
          hilog.warn(DOMAIN, TAG, 'net register failed: %{public}s', JSON.stringify(e));
        }
      });
      netConn.on('netAvailable', () => {
        hilog.info(DOMAIN, TAG, 'net available, flush queue');
        void this.tryFlush();
      });
      this.netConnection = netConn;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'net listener unavailable: %{public}s', JSON.stringify(e));
    }
  }

  /** 有网则登录并 flush；断网 / 登录失败跳过并记录（不消耗队列重试次数）。
   * flush 后队列仍有待传条目时安排延迟重试：否则「保存后瞬时失败 → 队列卡死到下次重启」。 */
  private async tryFlush(): Promise<string[]> {
    try {
      hilog.info(DOMAIN, TAG, 'tryFlush begin');
      const online: boolean = await connection.hasDefaultNet();
      if (!online) {
        hilog.warn(DOMAIN, TAG, 'tryFlush: no default net, schedule retry');
        this.scheduleDelayedRetry();
        return [];
      }
      await AuthStore.getInstance().ensureValidToken(HttpClient.getInstance().getBaseUrl(), this.clientKey);
      const uploaded: string[] = await UploadService.getInstance().flush();
      hilog.info(DOMAIN, TAG, 'tryFlush end, uploaded=%{public}d', uploaded.length);
      if (uploaded.length > 0) {
        this.retryKicks = 0;
      }
      if (SyncQueue.getInstance().pendingCount() > 0) {
        this.scheduleDelayedRetry();
      }
      return uploaded;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'tryFlush skipped: %{public}s', JSON.stringify(e));
      this.scheduleDelayedRetry();
      return [];
    }
  }

  /** 网络级失败后的单次延迟重试；连续失败最多 3 次，成功或队列清空后复位。 */
  private scheduleDelayedRetry(): void {
    if (this.retryTimerId !== -1 || this.retryKicks >= RETRY_KICK_LIMIT) {
      return;
    }
    this.retryKicks += 1;
    this.retryTimerId = setTimeout(() => {
      this.retryTimerId = -1;
      hilog.info(DOMAIN, TAG, 'delayed retry flush (kick %{public}d)', this.retryKicks);
      void this.tryFlush();
    }, RETRY_DELAY_MS);
  }
}
