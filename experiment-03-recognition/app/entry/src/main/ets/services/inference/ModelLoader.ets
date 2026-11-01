/**
 * 模型文件管理：rawfile 拷贝到沙箱、SHA-256 校验、设备 ABI 检查。
 * 模型文件较大（~10 MB），复制到沙箱后用文件路径创建 session，避免每次推理传递缓冲区。
 */
import { fileIo } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

import {
  RecognitionErrorCode,
  RecognitionFailure,
  InferenceAvailability,
  ModelInfo
} from '../../models/DetectionTypes';

const TAG: string = 'ModelLoader';
const DOMAIN: number = 0x0001;

export class ModelLoader {
  /**
   * 将 rawfile 中的模型复制到应用沙箱并校验 SHA-256。
   * 已存在且 hash 一致时跳过复制。
   *
   * @param context Ability 上下文，用于获取 filesDir 和 resourceManager。
   * @param modelInfo 模型静态信息（assetPath、sha256 等）。
   * @returns 沙箱内模型文件的绝对路径。
   * @throws RecognitionFailure(MODEL_MISSING) / (MODEL_INVALID)
   */
  static async ensureModelInSandbox(context: common.Context, modelInfo: ModelInfo): Promise<string> {
    const destDir = `${context.filesDir}/models`;
    const destPath = `${destDir}/${modelInfo.fileName}`;

    // 确保目录存在
    try {
      await fileIo.mkdir(destDir);
    } catch (e) {
      // 目录已存在，忽略
    }

    // 若沙箱已有模型且 hash 一致，直接复用
    if (await fileIo.access(destPath)) {
      const hashOk = await ModelLoader.verifySha256(destPath, modelInfo.sha256);
      if (hashOk) {
        hilog.info(DOMAIN, TAG, '模型已在沙箱且校验通过: %{public}s', destPath);
        return destPath;
      }
      hilog.warn(DOMAIN, TAG, '沙箱模型 hash 不符，重新复制');
      try {
        await fileIo.unlink(destPath);
      } catch (e) {
        // 忽略删除错误
      }
    }

    // 从 rawfile 复制到沙箱
    const rawfilePath = `rawfile/${modelInfo.assetPath}`;
    hilog.info(DOMAIN, TAG, '从 rawfile 复制模型: %{public}s -> %{public}s', rawfilePath, destPath);

    try {
      // getRawFileContent 返回 Uint8Array（TypedArray）。
      // fileIo.writeSync 接受 TypedArray 但某些设备版本对其 ArrayBuffer 底层引用
      // 敏感（write 缓冲区必须严格对应 view.byteOffset..byteOffset+byteLength），
      // 这里显式复制一份 ArrayBuffer，避免 Invalid argument。
      const view = await context.resourceManager.getRawFileContent(modelInfo.assetPath);
      const copy = new Uint8Array(view.byteLength);
      copy.set(view);
      const file = fileIo.openSync(destPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY);
      try {
        // HarmonyOS fileIo.writeSync(fd, buffer, options?) 只接受 2-3 个参数，
        // 这里通过 options.offset / length 写入完整副本。
        fileIo.writeSync(file.fd, copy.buffer, { offset: copy.byteOffset, length: copy.byteLength });
      } finally {
        fileIo.closeSync(file);
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, '模型复制失败: %{public}s', (e as Error).message);
      throw new RecognitionFailure(
        RecognitionErrorCode.MODEL_MISSING,
        '模型文件缺失，无法初始化识别功能',
        true,
        `rawfile copy failed: ${(e as Error).message}`
      );
    }

    // 校验沙箱文件 hash
    const hashOk = await ModelLoader.verifySha256(destPath, modelInfo.sha256);
    if (!hashOk) {
      try {
        await fileIo.unlink(destPath);
      } catch (e) {
        // 忽略
      }
      throw new RecognitionFailure(
        RecognitionErrorCode.MODEL_INVALID,
        '模型文件损坏，请重新安装应用',
        false,
        'SHA-256 mismatch after copy'
      );
    }

    hilog.info(DOMAIN, TAG, '模型复制并校验通过: %{public}s', destPath);
    return destPath;
  }

  /**
   * 计算文件 SHA-256 并与期望值比对。
   */
  static async verifySha256(filePath: string, expectedSha256: string): Promise<boolean> {
    try {
      // HarmonyOS cryptoFramework 不接受 'SHA-256'（带连字符），必须用 'SHA256'
      const md = await cryptoFramework.createMd('SHA256');
      const file = fileIo.openSync(filePath, fileIo.OpenMode.READ_ONLY);
      const stat = fileIo.statSync(filePath);
      const buffer = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buffer);
      fileIo.closeSync(file);

      const dataBlob: cryptoFramework.DataBlob = { data: new Uint8Array(buffer) };
      await md.update(dataBlob);
      const digest = await md.digest();
      const actual = ModelLoader.bufferToHex(digest.data);
      const match = actual.toLowerCase() === expectedSha256.toLowerCase();
      if (!match) {
        hilog.warn(DOMAIN, TAG, 'SHA-256 不匹配: 期望 %{public}s, 实际 %{public}s', expectedSha256, actual);
      }
      return match;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'SHA-256 校验异常: %{public}s', (e as Error).message);
      return false;
    }
  }

  private static bufferToHex(buffer: Uint8Array): string {
    let hex = '';
    for (let i = 0; i < buffer.length; i++) {
      hex += buffer[i].toString(16).padStart(2, '0');
    }
    return hex;
  }

  /**
   * 检查设备 ABI 是否受支持。当前依赖仅提供 arm64-v8a 原生库。
   *
   * @returns true 表示支持；false 表示不支持。
   */
  static isAbiSupported(): boolean {
    // deviceInfo.abiList 返回逗号分隔的 ABI 列表，如 'arm64-v8a,armeabi-v7a'
    const abiList = deviceInfo.abiList;
    const supported = abiList.includes('arm64');
    hilog.info(DOMAIN, TAG, '设备 ABI: %{public}s, 支持: %{public}s', abiList, supported ? 'yes' : 'no');
    return supported;
  }

  /**
   * 构建模型不可用时的 InferenceAvailability。
   */
  static unavailable(modelInfo: ModelInfo, code: RecognitionErrorCode, message: string, recoverable: boolean,
    detail: string = ''): InferenceAvailability {
    return {
      available: false,
      modelInfo,
      error: { code, message, recoverable, detail }
    };
  }
}
