/**
 * 云端记录查询的 UI 侧端口（Agent 3）。
 *
 * 页面只依赖本端口，不直接处理 HTTP。services/network（Agent 0）或
 * services/sync/CloudRecordService（Agent 4）实现后，在应用启动时调用
 * CloudRecordRegistry.register(port)。未注册时页面展示“云端服务尚未配置”
 * 并保留本地历史入口（phase-3-contract 第 4 节：不可用时 UI 降级到本地）。
 */
import { InferenceExecutionMode } from '../../models/DetectionTypes';
import { ImageOrigin } from '../../models/ImageTypes';

export type CloudErrorKind = 'UNAVAILABLE' | 'NETWORK' | 'AUTH' | 'SERVER' | 'UNKNOWN';
export type CloudErrorAction = 'retry' | 'relogin' | 'none';

export const CLOUD_OFFLINE_MESSAGE: string = '网络异常，记录将在恢复后自动上传';
export const CLOUD_AUTH_MESSAGE: string = '登录已过期，需要重新授权';
export const CLOUD_UNAVAILABLE_MESSAGE: string = '云端服务尚未配置，当前仅支持本地历史记录';

/** 端口实现抛出的错误；页面据此映射提示与恢复动作。 */
export class CloudQueryFailure extends Error {
  kind: CloudErrorKind;
  code: string;

  constructor(kind: CloudErrorKind, message: string, code: string = '') {
    super(message);
    this.kind = kind;
    this.code = code;
  }
}

/** 云端列表查询参数；undefined 表示不限制。 */
export interface CloudQueryFilter {
  fromMs?: number;
  toMs?: number;
  classId?: number;
  page: number;
  pageSize: number;
}

/** 云端统计只按时间范围聚合，不含类别筛选。 */
export interface CloudStatisticsFilter {
  fromMs?: number;
  toMs?: number;
}

export interface CloudClassCount {
  classId: number;
  label: string;
  count: number;
}

/** 云端记录摘要（服务端以 deleted=false 的最终类别重算计数）。 */
export interface CloudRecordItem {
  recordId: string;
  recognizedAtMs: number;
  source: ImageOrigin;
  imageWidth: number;
  imageHeight: number;
  boxCount: number;
  topClassLabel: string;
  topConfidence: number;
  executionMode: InferenceExecutionMode;
  totalMs: number;
  counts: CloudClassCount[];
}

export interface CloudRecordPage {
  items: CloudRecordItem[];
  page: number;
  pageSize: number;
  total: number;
  hasMore: boolean;
}

export interface CloudStatistics {
  totalRecords: number;
  totalDetections: number;
  counts: CloudClassCount[];
}

/**
 * 云端查询端口。实现方负责 JWT、超时、错误码到 CloudQueryFailure.kind 的映射：
 * - 未接入 / 后端未就绪 → UNAVAILABLE
 * - 断网 / 超时 → NETWORK
 * - 401/403 → AUTH
 * - 5xx / 响应格式错误 → SERVER
 */
export interface CloudRecordPort {
  list(filter: CloudQueryFilter): Promise<CloudRecordPage>;
  statistics(filter: CloudStatisticsFilter): Promise<CloudStatistics>;
  /** 重新鉴权（登录已过期时由用户点击“重新登录”触发）。 */
  reauthenticate(): Promise<void>;
}

/** 端口注册表：UI 只读，由 network/sync 层在启动时注册。 */
export class CloudRecordRegistry {
  private static port: CloudRecordPort | undefined = undefined;

  static register(port: CloudRecordPort): void {
    CloudRecordRegistry.port = port;
  }

  static resolve(): CloudRecordPort | undefined {
    return CloudRecordRegistry.port;
  }

  static available(): boolean {
    return CloudRecordRegistry.port !== undefined;
  }
}

export interface CloudErrorHint {
  message: string;
  action: CloudErrorAction;
}

/** 云端错误 → 面向用户的提示与恢复动作。 */
export function describeCloudError(err: Object): CloudErrorHint {
  const failure: CloudQueryFailure = err as CloudQueryFailure;
  if (failure !== undefined && failure.kind !== undefined) {
    switch (failure.kind) {
      case 'UNAVAILABLE':
        return { message: CLOUD_UNAVAILABLE_MESSAGE, action: 'none' };
      case 'NETWORK':
        return { message: CLOUD_OFFLINE_MESSAGE, action: 'retry' };
      case 'AUTH':
        return { message: CLOUD_AUTH_MESSAGE, action: 'relogin' };
      case 'SERVER':
        return { message: '云端服务异常，请稍后重试', action: 'retry' };
      default:
        break;
    }
    if (failure.message !== undefined && failure.message.length > 0) {
      return { message: failure.message, action: 'retry' };
    }
  }
  const plain: Error = err as Error;
  if (plain !== undefined && plain.message !== undefined && plain.message.length > 0) {
    return { message: plain.message, action: 'retry' };
  }
  return { message: '云端查询失败，请重试', action: 'retry' };
}
