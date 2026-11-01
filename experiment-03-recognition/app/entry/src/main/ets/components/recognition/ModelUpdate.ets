/**
 * 模型更新的 UI 侧端口（Agent 3）。
 *
 * 页面只依赖本端口；services/network/ModelClient（Agent 0）实现后，在应用启动时调用
 * ModelUpdateRegistry.register(port)。页面负责展示可用版本、下载进度，并在完成后
 * 重新初始化 RecognitionService。
 */
export type ModelUpdatePhase = 'idle' | 'checking' | 'available' | 'downloading' | 'installed' | 'failed';

export interface ModelUpdateInfo {
  modelId: string;
  version: string;
  /** bugfix / accuracy / compat */
  reason: string;
  sizeBytes: number;
}

/**
 * 模型更新端口。实现方负责版本查询、原子下载替换与 SHA-256 校验：
 * - check() 无更新返回 null
 * - download() 周期性回调进度 0..1，完成后模型已就位
 */
export interface ModelUpdatePort {
  check(currentModelId: string, currentSha256: string): Promise<ModelUpdateInfo | null>;
  download(info: ModelUpdateInfo, onProgress: (fraction: number) => void): Promise<void>;
}

export class ModelUpdateRegistry {
  private static port: ModelUpdatePort | undefined = undefined;

  static register(port: ModelUpdatePort): void {
    ModelUpdateRegistry.port = port;
  }

  static resolve(): ModelUpdatePort | undefined {
    return ModelUpdateRegistry.port;
  }

  static available(): boolean {
    return ModelUpdateRegistry.port !== undefined;
  }
}

/** 更新原因中文名。 */
export function formatUpdateReason(reason: string): string {
  if (reason === 'bugfix') {
    return '缺陷修复';
  }
  if (reason === 'accuracy') {
    return '精度提升';
  }
  if (reason === 'compat') {
    return '兼容性更新';
  }
  return '版本更新';
}

/** 下载体积展示。 */
export function formatDownloadSize(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) {
    return '';
  }
  if (bytes >= 1024 * 1024) {
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  }
  return `${Math.max(1, Math.round(bytes / 1024))} KB`;
}

/** 下载失败提示。 */
export function describeModelUpdateError(err: Object): string {
  const plain: Error = err as Error;
  if (plain !== undefined && plain.message !== undefined && plain.message.length > 0) {
    return `模型更新失败：${plain.message}`;
  }
  return '模型更新失败，请检查网络后重试';
}
