/**
 * TaskPool 推理任务（native Ort C API 路径）。
 *
 * native 层 Ort session 是进程级单例，各 TaskPool worker 调用 initNative 时
 *  native 内部 g_initialized 为 true 会立即返回，不会重复创建 session。
 * 因此本任务无需自行创建/关闭 session，仅调用 NativeBridge 的线程安全接口。
 *
 * 注意：@Concurrent 函数不能引用顶层 import 的模块变量，
 *  必须在函数内部用动态 import 加载 NativeBridge。
 */
import { InferenceEngine } from '../services/inference/InferenceEngine';
import { MODEL_OUTPUT_BYTES } from '../models/ModelConstants';
import {
  DetectionResult,
  InferenceOptions,
  InferenceTiming,
  RecognitionError,
  RecognitionErrorCode,
  RecognitionOutcome,
  ModelInfo
} from '../models/DetectionTypes';
import { PixelFormat } from '../models/ImageTypes';

/** NativeBridge 的函数签名（类型检查用）。 */
interface NativeBridgeApi {
  initNative(path: string): string;
  runNative(
    inputBuffer: ArrayBuffer,
    inputShape: number[],
    inputName: string,
    outputName: string,
    outputSizeBytes: number
  ): ArrayBuffer;
  isNativeReady(): boolean;
  wasEverInitialized(): boolean;
}

/**
 * TaskPool 并发推理任务。
 */
@Concurrent
export async function runInferenceTask(
  modelPath: string,
  pixels: ArrayBuffer,
  imageWidth: number,
  imageHeight: number,
  rowStride: number,
  pixelFormatStr: string,
  options: InferenceOptions,
  requestId: string,
  imageId: string,
  modelInfo: ModelInfo
): Promise<RecognitionOutcome> {
  const totalStart = Date.now();
  let modelLoadMs = 0;
  let coldStart = false;

  try {
    // 动态加载 NativeBridge（@Concurrent 限制）
    const bridgeMod = await import('../services/inference/NativeInferenceBridge');
    const bridge = bridgeMod as NativeBridgeApi;

    // 1. 初始化 native（进程级，idempotent）
    //    冷启动判定必须以 native 返回值语义为准：
    //      - 'OK:already_init'：进程级 session 已存在，本次没有创建 → 非冷启动
    //      - 其它 'OK:...'：本次真正创建了 session → 冷启动
    //    不能用 wasEverInitialized()：TaskPool worker 各自维护一份模块级标记，
    //    在新 worker 里恒为 false，会把热启动误判成冷启动（R3-03）。
    const loadStart = Date.now();
    const initResult = bridge.initNative(modelPath);
    if (!initResult.startsWith('OK')) {
      const err: RecognitionError = {
        code: RecognitionErrorCode.INFERENCE_FAILED,
        message: 'native 模型初始化失败',
        recoverable: false,
        detail: `NativeBridge.initNative: ${initResult || 'empty'}`
      };
      return { ok: false, error: err };
    }
    coldStart = !initResult.startsWith('OK:already_init');
    modelLoadMs = coldStart ? Date.now() - loadStart : 0;

    // 2. 预处理
    const preStart = Date.now();
    const pixelFormat = pixelFormatStr === 'rgba8888' ? PixelFormat.RGBA_8888 : PixelFormat.RGB_888;
    const preprocess = InferenceEngine.preprocess(
      pixels,
      rowStride,
      imageWidth,
      imageHeight,
      pixelFormat,
      modelInfo.inputWidth,
      modelInfo.inputHeight
    );
    const preprocessMs = Date.now() - preStart;

    // 3. native 推理
    const inferStart = Date.now();
    const inputBuf = preprocess.tensor.buffer as ArrayBuffer;
    const outputBuffer = bridge.runNative(
      inputBuf,
      [1, 3, modelInfo.inputHeight, modelInfo.inputWidth],
      modelInfo.inputName,
      modelInfo.outputName,
      MODEL_OUTPUT_BYTES
    );
    const inferenceMs = Date.now() - inferStart;

    // 4. 后处理
    const postStart = Date.now();
    const boxes = InferenceEngine.postprocess(
      outputBuffer,
      preprocess.letterbox,
      imageWidth,
      imageHeight,
      8400,
      modelInfo.classCount,
      options
    );
    const postprocessMs = Date.now() - postStart;

    const totalMs = Date.now() - totalStart;
    const timing: InferenceTiming = {
      preprocessMs,
      inferenceMs,
      postprocessMs,
      totalMs,
      coldStart,
      modelLoadMs
    };

    const detectionResult: DetectionResult = {
      requestId,
      imageId,
      imageWidth,
      imageHeight,
      boxes,
      timing,
      executionMode: options.executionMode,
      confidenceThreshold: options.confidenceThreshold,
      iouThreshold: options.iouThreshold,
      modelId: modelInfo.modelId,
      modelSha256: modelInfo.sha256,
      recognizedAtMs: Date.now()
    };

    return { ok: true, result: detectionResult };
  } catch (e) {
    const err = e as Error;
    const error: RecognitionError = {
      code: RecognitionErrorCode.INFERENCE_FAILED,
      message: '识别失败，请重试',
      recoverable: true,
      detail: err.message
    };
    return { ok: false, error };
  }
}
