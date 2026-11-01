/**
 * NativeInferenceBridge — 通过 C++ native module 调 Ort C API 做推理。
 */
import hilog from '@ohos.hilog';
import nativeInfer from 'libonnx_native.so';

const TAG: string = 'NativeBridge';
const DOMAIN: number = 0x0005;

let initialized: boolean = false;
let everInitialized: boolean = false;

/** 初始化 native 推理。返回 debug 字符串（包含探测到的布局），失败返回空串。 */
export function initNative(modelPath: string): string {
  if (initialized) {
    hilog.info(DOMAIN, TAG, 'native 已初始化');
    return 'OK:already_init';
  }
  try {
    const result: string = nativeInfer.nativeInit(modelPath);
    hilog.info(DOMAIN, TAG, 'nativeInit result: %{public}s', result);
    if (result && result.startsWith('OK')) {
      initialized = true;
      everInitialized = true;
    }
    return result;
  } catch (e) {
    hilog.error(DOMAIN, TAG, 'nativeInit 异常: %{public}s', (e as Error).message);
    return '';
  }
}

/** 查询 native session 是否曾经创建过（冷启动判定用）。 */
export function wasEverInitialized(): boolean {
  return everInitialized;
}

/** 执行推理。 */
export function runNative(
  inputBuffer: ArrayBuffer,
  inputShape: number[],
  inputName: string,
  outputName: string,
  outputSizeBytes: number
): ArrayBuffer {
  if (!initialized) {
    throw new Error('native inference not initialized');
  }
  return nativeInfer.nativeRun(
    inputBuffer, inputShape, inputName, outputName, outputSizeBytes);
}

/** 释放 native 资源。 */
export function disposeNative(): void {
  if (initialized) {
    try { nativeInfer.nativeDispose(); } catch (e) {
      hilog.error(DOMAIN, TAG, 'nativeDispose: %{public}s', (e as Error).message);
    }
  }
  initialized = false;
  everInitialized = false;
}

export function isNativeReady(): boolean {
  return initialized;
}
