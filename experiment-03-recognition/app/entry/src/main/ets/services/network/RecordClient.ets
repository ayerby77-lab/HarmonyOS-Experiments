/**
 * 云端记录查询端口实现（Agent 0）。依据 docs/phase-3-contract.md 第 4 节。
 *
 * 实现 components/recognition/CloudQuery.ets 的 CloudRecordPort：
 * - list()       → GET /api/records（时间/类别筛选、分页）
 * - statistics() → GET /api/statistics（时间范围聚合）
 * - reauthenticate() → 清空令牌后用内嵌密钥重新登录
 *
 * 错误映射（契约 §4.3）：断网→NETWORK，401/403→AUTH，5xx/格式错误→SERVER，其余→UNKNOWN。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';

import { ImageOrigin } from '../../models/ImageTypes';
import { InferenceExecutionMode } from '../../models/DetectionTypes';
import {
  CloudClassCount,
  CloudQueryFailure,
  CloudQueryFilter,
  CloudRecordItem,
  CloudRecordPage,
  CloudRecordPort,
  CloudStatistics,
  CloudStatisticsFilter
} from '../../components/recognition/CloudQuery';
import { AuthStore, DEV_CLIENT_KEY } from './AuthStore';
import { HttpClient, NetworkErrorCode, NetworkFailure } from './HttpClient';

const TAG: string = 'RecordClient';
const DOMAIN: number = 0x0000;

/** GET /api/records 响应中的单条摘要（后端 RecordSummary）。 */
interface CloudCountDto {
  classId: number;
  label: string;
  count: number;
}

interface CloudRecordSummaryDto {
  recordId: string;
  recognizedAtMs: number;
  savedAtMs: number;
  imageOrigin: string;
  imageWidth: number;
  imageHeight: number;
  modelId: string;
  executionMode: string;
  totalMs: number;
  rawDetectionCount: number;
  edited: boolean;
  counts: CloudCountDto[];
}

interface CloudRecordPageDto {
  items: CloudRecordSummaryDto[];
  page: number;
  pageSize: number;
  total: number;
  hasMore: boolean;
}

interface CloudStatisticsDto {
  totalRecords: number;
  totalDetections: number;
  counts: CloudCountDto[];
}

export class RecordClient implements CloudRecordPort {
  private static instance: RecordClient | null = null;

  static getInstance(): RecordClient {
    if (RecordClient.instance === null) {
      RecordClient.instance = new RecordClient();
    }
    return RecordClient.instance;
  }

  private constructor() {
  }

  async list(filter: CloudQueryFilter): Promise<CloudRecordPage> {
    await this.ensureToken();
    const path: string = this.buildRecordsPath(filter);
    try {
      const dto: CloudRecordPageDto = await HttpClient.getInstance().get<CloudRecordPageDto>(path);
      return this.toPage(dto);
    } catch (e) {
      throw this.mapError(e, '云端记录查询失败');
    }
  }

  async statistics(filter: CloudStatisticsFilter): Promise<CloudStatistics> {
    await this.ensureToken();
    const path: string = this.buildStatisticsPath(filter);
    try {
      const dto: CloudStatisticsDto = await HttpClient.getInstance().get<CloudStatisticsDto>(path);
      const counts: CloudClassCount[] = this.toCounts(dto.counts);
      const stats: CloudStatistics = {
        totalRecords: dto.totalRecords ?? 0,
        totalDetections: dto.totalDetections ?? 0,
        counts: counts
      };
      return stats;
    } catch (e) {
      throw this.mapError(e, '云端统计查询失败');
    }
  }

  /** 登录已过期后由用户触发：清空令牌并重新登录。 */
  async reauthenticate(): Promise<void> {
    const auth: AuthStore = AuthStore.getInstance();
    auth.clearTokens();
    try {
      await auth.login(HttpClient.getInstance().getBaseUrl(), DEV_CLIENT_KEY);
    } catch (e) {
      throw this.mapError(e, '重新登录失败');
    }
  }

  // ==================== 内部方法 ====================

  private async ensureToken(): Promise<void> {
    try {
      await AuthStore.getInstance().ensureValidToken(HttpClient.getInstance().getBaseUrl(), DEV_CLIENT_KEY);
    } catch (e) {
      throw this.mapError(e, '设备认证失败');
    }
  }

  private buildRecordsPath(filter: CloudQueryFilter): string {
    const params: string[] = [];
    if (filter.fromMs !== undefined && filter.fromMs > 0) {
      params.push(`fromMs=${Math.floor(filter.fromMs)}`);
    }
    if (filter.toMs !== undefined && filter.toMs > 0) {
      params.push(`toMs=${Math.floor(filter.toMs)}`);
    }
    if (filter.classId !== undefined && filter.classId >= 0) {
      params.push(`classId=${Math.floor(filter.classId)}`);
    }
    params.push(`page=${Math.max(1, Math.floor(filter.page))}`);
    params.push(`pageSize=${Math.max(1, Math.floor(filter.pageSize))}`);
    return `/api/records?${params.join('&')}`;
  }

  private buildStatisticsPath(filter: CloudStatisticsFilter): string {
    const params: string[] = [];
    if (filter.fromMs !== undefined && filter.fromMs > 0) {
      params.push(`fromMs=${Math.floor(filter.fromMs)}`);
    }
    if (filter.toMs !== undefined && filter.toMs > 0) {
      params.push(`toMs=${Math.floor(filter.toMs)}`);
    }
    if (params.length === 0) {
      return '/api/statistics';
    }
    return `/api/statistics?${params.join('&')}`;
  }

  private toPage(dto: CloudRecordPageDto): CloudRecordPage {
    const items: CloudRecordItem[] = [];
    const raw: CloudRecordSummaryDto[] = dto.items ?? [];
    for (let i = 0; i < raw.length; i++) {
      items.push(this.toItem(raw[i]));
    }
    const page: CloudRecordPage = {
      items: items,
      page: dto.page,
      pageSize: dto.pageSize,
      total: dto.total,
      hasMore: dto.hasMore
    };
    return page;
  }

  private toItem(dto: CloudRecordSummaryDto): CloudRecordItem {
    const counts: CloudClassCount[] = this.toCounts(dto.counts);
    let boxCount: number = 0;
    for (let i = 0; i < counts.length; i++) {
      boxCount += counts[i].count;
    }
    const topLabel: string = counts.length > 0 ? counts[0].label : '';
    // 后端摘要不含 topConfidence，类别筛选与展示只用 label；此处填 0 表示未提供。
    const item: CloudRecordItem = {
      recordId: dto.recordId,
      recognizedAtMs: dto.recognizedAtMs,
      source: dto.imageOrigin === 'camera' ? ImageOrigin.CAMERA : ImageOrigin.GALLERY,
      imageWidth: dto.imageWidth,
      imageHeight: dto.imageHeight,
      boxCount: boxCount,
      topClassLabel: topLabel,
      topConfidence: 0,
      executionMode: dto.executionMode === 'sync' ? InferenceExecutionMode.SYNC : InferenceExecutionMode.TASK_POOL,
      totalMs: dto.totalMs,
      counts: counts
    };
    return item;
  }

  private toCounts(raw: CloudCountDto[] | undefined): CloudClassCount[] {
    const out: CloudClassCount[] = [];
    if (raw === undefined) {
      return out;
    }
    for (let i = 0; i < raw.length; i++) {
      const count: CloudClassCount = {
        classId: raw[i].classId,
        label: raw[i].label,
        count: raw[i].count
      };
      out.push(count);
    }
    return out;
  }

  /** NetworkFailure / AuthFailure → CloudQueryFailure（契约 §4.3）。 */
  private mapError(e: Object, fallbackMessage: string): CloudQueryFailure {
    if (e instanceof CloudQueryFailure) {
      return e;
    }
    if (e instanceof NetworkFailure) {
      switch (e.code) {
        case NetworkErrorCode.OFFLINE:
          return new CloudQueryFailure('NETWORK', '网络异常，记录将在恢复后自动上传', e.serverCode);
        case NetworkErrorCode.UNAUTHORIZED:
        case NetworkErrorCode.FORBIDDEN:
          return new CloudQueryFailure('AUTH', '登录已过期，需要重新授权', e.serverCode);
        case NetworkErrorCode.SERVER:
        case NetworkErrorCode.INVALID_RESPONSE:
          return new CloudQueryFailure('SERVER', '云端服务异常，请稍后重试', e.serverCode);
        default:
          break;
      }
      hilog.warn(DOMAIN, TAG, 'query rejected: %{public}s %{public}s', e.code, e.message);
      return new CloudQueryFailure('UNKNOWN', e.message.length > 0 ? e.message : fallbackMessage, e.serverCode);
    }
    const plain: Error = e as Error;
    if (plain !== undefined && plain.message !== undefined && plain.message.length > 0) {
      return new CloudQueryFailure('AUTH', plain.message);
    }
    return new CloudQueryFailure('UNKNOWN', fallbackMessage);
  }
}
