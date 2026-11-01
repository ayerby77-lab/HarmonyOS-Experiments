/**
 * 模型更新端口实现（Agent 0）。依据 docs/phase-3-contract.md 第 2 节。
 *
 * 实现 components/recognition/ModelUpdate.ets 的 ModelUpdatePort：
 * - check()    → GET /api/models/version，比对 modelId + sha256，无更新返回 null
 * - download() → GET /api/models/download，写入 cacheDir 临时文件，SHA-256 校验通过后
 *                原子替换到 filesDir/models/{fileName}，再通知 RecognitionService 重建 session
 *
 * 下载失败保持旧模型可用：临时文件在 finally 中删除，沙箱内原模型不受影响。
 */
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

import { ModelUpdateInfo, ModelUpdatePort } from '../../components/recognition/ModelUpdate';
import { ModelLoader } from '../inference/ModelLoader';
import { RecognitionService } from '../inference/RecognitionService';
import { AuthStore, DEV_CLIENT_KEY } from './AuthStore';
import { HttpClient, NetworkFailure } from './HttpClient';

const TAG: string = 'ModelClient';
const DOMAIN: number = 0x0000;

const MODEL_SUBDIR: string = 'models';

/** GET /api/models/version 响应（后端 ModelVersionResponse）。 */
interface ModelVersionDto {
  modelId: string;
  version: string;
  sha256: string;
  fileName: string;
  sizeBytes: number;
  opset: number;
  inputWidth: number;
  inputHeight: number;
  classCount: number;
  releasedAtMs: number;
  downloadUrl: string;
}

export class ModelClient implements ModelUpdatePort {
  private static instance: ModelClient | null = null;

  static getInstance(): ModelClient {
    if (ModelClient.instance === null) {
      ModelClient.instance = new ModelClient();
    }
    return ModelClient.instance;
  }

  private context: common.Context | null = null;
  /** check() 拿到的版本元数据，download() 复用，避免重复请求。 */
  private version: ModelVersionDto | null = null;

  private constructor() {
  }

  /** 设置 Ability 上下文（下载落盘需要 cacheDir / filesDir）。 */
  initialize(context: common.Context): void {
    this.context = context;
  }

  async check(currentModelId: string, currentSha256: string): Promise<ModelUpdateInfo | null> {
    const version: ModelVersionDto = await this.fetchVersion();
    this.version = version;
    const sameId: boolean = version.modelId === currentModelId;
    const sameHash: boolean = version.sha256.toLowerCase() === currentSha256.toLowerCase();
    if (sameId && sameHash) {
      hilog.info(DOMAIN, TAG, '模型已是最新: %{public}s', version.version);
      return null;
    }
    const info: ModelUpdateInfo = {
      modelId: version.modelId,
      version: version.version,
      // 版本元数据不含更新原因，按是否更换模型标识推断展示文案
      reason: sameId ? 'bugfix' : 'accuracy',
      sizeBytes: version.sizeBytes
    };
    hilog.info(DOMAIN, TAG, '发现模型更新: %{public}s sha=%{public}s', version.version, version.sha256);
    return info;
  }

  async download(info: ModelUpdateInfo, onProgress: (fraction: number) => void): Promise<void> {
    const version: ModelVersionDto = await this.resolveVersion(info);
    await this.ensureToken();
    const context: common.Context = this.requireContext();
    const cacheDir: string = `${context.cacheDir}/${MODEL_SUBDIR}`;
    const filesDir: string = `${context.filesDir}/${MODEL_SUBDIR}`;
    await this.ensureDir(cacheDir);
    await this.ensureDir(filesDir);

    const tempPath: string = `${cacheDir}/${version.modelId}-${version.sha256}.downloading`;
    const destPath: string = `${filesDir}/${version.fileName}`;
    let body: ArrayBuffer | null = null;
    try {
      body = await HttpClient.getInstance().getBinary(version.downloadUrl, onProgress);
      this.writeFile(tempPath, body);
      body = null;
      // 校验通过才替换，避免半个文件或损坏模型污染沙箱
      const hashOk: boolean = await ModelLoader.verifySha256(tempPath, version.sha256);
      if (!hashOk) {
        throw new Error('模型文件校验失败（SHA-256 不匹配）');
      }
      this.replaceFile(tempPath, destPath);
      hilog.info(DOMAIN, TAG, '模型已就位: %{public}s', destPath);
    } finally {
      body = null;
      this.removeQuietly(tempPath);
    }

    // 重建 native session；失败时抛出，由 UI 展示错误（旧 session 已在 replaceModel 内释放）
    const availability = await RecognitionService.getInstance().replaceModel({
      modelId: version.modelId,
      fileName: version.fileName,
      sha256: version.sha256
    });
    if (!availability.available) {
      throw new Error(availability.error ? availability.error.message : '模型已下载但加载失败');
    }
  }

  // ==================== 内部方法 ====================

  private async fetchVersion(): Promise<ModelVersionDto> {
    await this.ensureToken();
    try {
      const dto: ModelVersionDto = await HttpClient.getInstance().get<ModelVersionDto>('/api/models/version');
      return dto;
    } catch (e) {
      throw this.wrapError(e, '模型版本查询失败');
    }
  }

  private async resolveVersion(info: ModelUpdateInfo): Promise<ModelVersionDto> {
    const cached: ModelVersionDto | null = this.version;
    if (cached !== null && cached.modelId === info.modelId) {
      return cached;
    }
    return this.fetchVersion();
  }

  private async ensureToken(): Promise<void> {
    try {
      await AuthStore.getInstance().ensureValidToken(HttpClient.getInstance().getBaseUrl(), DEV_CLIENT_KEY);
    } catch (e) {
      throw this.wrapError(e, '设备认证失败');
    }
  }

  private requireContext(): common.Context {
    if (this.context !== null) {
      return this.context;
    }
    const context: common.Context = getContext() as common.Context;
    this.context = context;
    return context;
  }

  private async ensureDir(dir: string): Promise<void> {
    if (await fileIo.access(dir)) {
      return;
    }
    try {
      await fileIo.mkdir(dir);
    } catch (e) {
      // 并发创建时目录已存在，忽略
    }
  }

  private writeFile(path: string, buffer: ArrayBuffer): void {
    const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, buffer, { offset: 0, length: buffer.byteLength });
    } finally {
      fileIo.closeSync(file);
    }
  }

  /** 原子替换：优先 moveFileSync，失败时退回 copy + unlink。 */
  private replaceFile(tempPath: string, destPath: string): void {
    try {
      fileIo.moveFileSync(tempPath, destPath);
      return;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'moveFileSync 失败，改用 copy: %{public}s', (e as Error).message);
    }
    try {
      fileIo.unlinkSync(destPath);
    } catch (e) {
      // 目标不存在
    }
    fileIo.copyFileSync(tempPath, destPath);
  }

  private removeQuietly(path: string): void {
    try {
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
    } catch (e) {
      // 清理失败不影响主流程
    }
  }

  private wrapError(e: Object, fallbackMessage: string): Error {
    if (e instanceof Error) {
      if (e instanceof NetworkFailure) {
        return new Error(`${fallbackMessage}: ${e.message}`);
      }
      return e;
    }
    return new Error(fallbackMessage);
  }
}
