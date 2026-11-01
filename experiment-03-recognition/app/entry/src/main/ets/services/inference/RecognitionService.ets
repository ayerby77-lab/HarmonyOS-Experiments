/**
 * 识别服务主类。实现 RecognitionServiceApi。
 *
 * 职责：
 * - 初始化：ABI 检查、模型沙箱拷贝与 hash 校验、native Ort C API session 创建。
 * - 识别：串行执行（最多一个任务运行），同步/TaskPool 双模式共享 native 全局 session。
 * - 取消：latest-wins 策略，未开始的请求以 CANCELLED 拒绝。
 * - 释放：native 资源释放。
 *
 * 线程约束：
 * - native 层 Ort session 为进程级单例，所有线程共享（Ort C API 线程安全）。
 * - ArkTS native bridge 模块级 `initialized` 标记在每个 TaskPool worker 独立维护，
 *   但 native initNative 函数内部 `g_initialized` 为进程级，idempotent。
 */
import { taskpool } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';

import { RecognitionServiceApi } from '../../models/RecognitionApi';
import {
  DetectionResult,
  InferenceAvailability,
  InferenceExecutionMode,
  InferenceOptions,
  InferenceTiming,
  ModelInfo,
  RecognitionErrorCode,
  RecognitionFailure,
  RecognitionOutcome
} from '../../models/DetectionTypes';
import { ImageSource, PixelFormat } from '../../models/ImageTypes';
import { MODEL_INFO, MODEL_OUTPUT_BYTES } from '../../models/ModelConstants';

import { InferenceEngine } from './InferenceEngine';
import { ModelLoader } from './ModelLoader';
import * as NativeBridge from './NativeInferenceBridge';
import { runInferenceTask } from '../../tasks/InferenceTask';

const TAG: string = 'RecognitionService';
const DOMAIN: number = 0x0003;

/**
 * TaskPool 任务参数的像素缓冲上限（字节）。
 *
 * 依据实测：9.4MB 缓冲可正常跨线程传递，30.3MB（1920×4138 RGB）直接失败且耗时仅 29ms
 * （远快于一次推理，说明卡在参数序列化阶段）。取 16MB 作为保守阈值，
 * 超过则降级为同步执行，保证功能可用。
 */
export const TASKPOOL_MAX_BYTES: number = 16 * 1024 * 1024;


/** 云端模型热更新描述。 */
export interface ModelOverride {
  modelId: string;
  fileName: string;
  sha256: string;
}

/** 待执行请求的内部表示。 */
interface PendingRequest {
  image: ImageSource;
  options: InferenceOptions;
  requestId: string;
  resolve: (result: DetectionResult) => void;
  reject: (error: RecognitionFailure) => void;
}

export class RecognitionService implements RecognitionServiceApi {
  private static instance: RecognitionService | null = null;

  private context: common.Context | null = null;
  private modelInfo: ModelInfo = MODEL_INFO;
  private modelPath: string = '';
  private availability: InferenceAvailability | null = null;
  private initialized: boolean = false;
  private disposed: boolean = false;
  /**
   * 正在进行的初始化 Promise。
   * EntryAbility.onCreate 与首页 aboutToAppear 几乎同时调用 initialize()，
   * 若不合并，两条链路会各自执行一遍「模型拷贝 + hash 校验」，
   * 并发写同一个模型文件可能产出损坏文件，表现为间歇性「识别不可用：模型无效」。
   */
  private initInFlight: Promise<InferenceAvailability> | null = null;

  // 串行调度状态
  private running: boolean = false;
  private pending: PendingRequest | null = null;

  // 冷启动耗时记录
  private modelLoadMs: number = 0;

  private constructor() {
  }

  static getInstance(): RecognitionService {
    if (RecognitionService.instance === null) {
      RecognitionService.instance = new RecognitionService();
    }
    return RecognitionService.instance;
  }

  /**
   * 设置 Ability 上下文。必须在 initialize 之前调用。
   */
  setContext(context: common.Context): void {
    this.context = context;
  }

  /**
   * 应用云端下载的模型并重建 native session（模型热更新）。
   *
   * 与 dispose() 不同：这里不置永久释放标记，替换后仍可继续识别。
   * 新模型已按 fileName 落在 filesDir/models/ 下，且 sha256 由调用方校验过；
   * initialize() 会因 hash 一致而直接复用该文件，不再回到 rawfile 复制。
   */
  async replaceModel(override: ModelOverride): Promise<InferenceAvailability> {
    hilog.info(DOMAIN, TAG, '模型热更新: %{public}s', override.modelId);
    this.modelInfo = {
      modelId: override.modelId,
      fileName: override.fileName,
      // 下载模型不在 rawfile 中；assetPath 仅在沙箱文件缺失时作为兜底
      assetPath: `models/${override.fileName}`,
      sha256: override.sha256,
      inputName: this.modelInfo.inputName,
      outputName: this.modelInfo.outputName,
      inputWidth: this.modelInfo.inputWidth,
      inputHeight: this.modelInfo.inputHeight,
      classCount: this.modelInfo.classCount,
      opset: this.modelInfo.opset
    };
    NativeBridge.disposeNative();
    this.modelPath = '';
    this.availability = null;
    this.initialized = false;
    return this.initialize();
  }

  /** 当前生效的模型元信息（供模型更新比对版本）。 */
  getModelInfo(): ModelInfo {
    return this.modelInfo;
  }

  /**
   * 初始化推理服务。幂等，不抛出模型/ABI 错误，而是通过 available=false 返回。
   *
   * 语义说明：
   * - 首次成功后（available=true），后续调用直接返回缓存，不再重复创建 session。
   * - 上一次返回 available=false 时，initialize() **会重新尝试**（允许用户在模型恢复
   *   或设备切换后点击"重新加载模型"）。上一次 available=true 但后来 dispose 则走
   *   disposed 分支。
   */
  async initialize(): Promise<InferenceAvailability> {
    // 并发调用合并：已有初始化在飞行中时直接复用同一个 Promise。
    // 这既避免重复拷贝模型（见 initInFlight 注释），也保证两次调用拿到同一份结果。
    if (this.initInFlight !== null) {
      return this.initInFlight;
    }
    const pending: Promise<InferenceAvailability> = this.doInitialize();
    this.initInFlight = pending;
    try {
      return await pending;
    } finally {
      this.initInFlight = null;
    }
  }

  private async doInitialize(): Promise<InferenceAvailability> {
    if (this.disposed) {
      throw new Error('RecognitionService 已释放，不可复用');
    }
    if (this.context === null) {
      throw new Error('必须先调用 setContext 设置 Ability 上下文');
    }
    // 已成功初始化：直接返回缓存，跳过重复 session 创建
    if (this.initialized && this.availability !== null && this.availability.available) {
      return this.availability;
    }
    // 上一次返回 available=false：清空缓存，允许重新尝试
    this.availability = null;
    this.initialized = false;
    if (this.disposed) {
      throw new Error('RecognitionService 已释放，不可复用');
    }
    if (this.context === null) {
      throw new Error('必须先调用 setContext 设置 Ability 上下文');
    }

    // 1. ABI 检查
    if (!ModelLoader.isAbiSupported()) {
      this.availability = ModelLoader.unavailable(
        this.modelInfo,
        RecognitionErrorCode.UNSUPPORTED_ABI,
        '当前设备不支持端侧推理（仅支持 arm64）',
        false,
        `device abi not arm64`
      );
      this.initialized = true;
      return this.availability;
    }

    // 2. 模型拷贝与 hash 校验
    try {
      this.modelPath = await ModelLoader.ensureModelInSandbox(this.context, this.modelInfo);
    } catch (e) {
      if (e instanceof RecognitionFailure) {
        this.availability = ModelLoader.unavailable(
          this.modelInfo,
          e.code,
          e.message,
          e.recoverable,
          e.detail
        );
      } else {
        this.availability = ModelLoader.unavailable(
          this.modelInfo,
          RecognitionErrorCode.MODEL_MISSING,
          '模型文件缺失，识别功能不可用',
          true,
          (e as Error).message
        );
      }
      this.initialized = true;
      return this.availability;
    }

    // 3. 初始化 native Ort C API session（进程级单例）
    try {
      const loadStart = Date.now();
      const initResult = NativeBridge.initNative(this.modelPath);
      if (!initResult.startsWith('OK')) {
        this.availability = ModelLoader.unavailable(
          this.modelInfo,
          RecognitionErrorCode.MODEL_INVALID,
          'native 模型加载失败',
          false,
          `NativeBridge.initNative: ${initResult || 'empty result'}`
        );
        this.initialized = true;
        return this.availability;
      }
      this.modelLoadMs = Date.now() - loadStart;
      hilog.info(DOMAIN, TAG, 'native session 创建成功，耗时 %{public}d ms (%{public}s)', this.modelLoadMs, initResult);
    } catch (e) {
      this.availability = ModelLoader.unavailable(
        this.modelInfo,
        RecognitionErrorCode.MODEL_INVALID,
        'native 模型加载异常',
        false,
        (e as Error).message
      );
      this.initialized = true;
      return this.availability;
    }

    this.availability = {
      available: true,
      modelInfo: this.modelInfo
    };
    this.initialized = true;
    hilog.info(DOMAIN, TAG, '识别服务初始化成功');
    return this.availability;
  }

  getAvailability(): InferenceAvailability {
    if (this.availability !== null) {
      return this.availability;
    }
    return {
      available: false,
      modelInfo: this.modelInfo,
      error: {
        code: RecognitionErrorCode.INFERENCE_FAILED,
        message: '识别服务尚未初始化',
        recoverable: true
      }
    };
  }

  /**
   * 执行识别。串行执行，latest-wins。
   *
   * @throws RecognitionFailure 选项非法、推理失败或被取消。
   */
  async recognize(image: ImageSource, options: InferenceOptions, requestId: string): Promise<DetectionResult> {
    if (this.disposed) {
      throw new RecognitionFailure(
        RecognitionErrorCode.INFERENCE_FAILED,
        '识别服务已释放',
        false,
        'service disposed'
      );
    }
    if (!this.initialized || this.availability === null || !this.availability.available) {
      throw new RecognitionFailure(
        RecognitionErrorCode.INFERENCE_FAILED,
        '识别服务未就绪，请先初始化',
        false,
        'service not available'
      );
    }

    // 校验输入图像
    this.validateImage(image);
    // 校验选项
    this.validateOptions(options);

    return new Promise<DetectionResult>((resolve, reject) => {
      const request: PendingRequest = { image, options, requestId, resolve, reject };

      if (!this.running) {
        this.executeRequest(request);
      } else {
        // 替换尚未开始的旧请求（latest wins）
        if (this.pending !== null) {
          const old = this.pending;
          this.pending = null;
          old.reject(new RecognitionFailure(
            RecognitionErrorCode.CANCELLED,
            '请求被新请求替换',
            true,
            `replaced by ${requestId}`
          ));
        }
        this.pending = request;
        hilog.info(DOMAIN, TAG, '请求排队等待: %{public}s', requestId);
      }
    });
  }

  /**
   * 取消尚未开始执行的请求。已在执行的请求无法中断，调用方通过 requestId 丢弃结果。
   */
  cancel(requestId: string): void {
    if (this.pending !== null && this.pending.requestId === requestId) {
      const old = this.pending;
      this.pending = null;
      old.reject(new RecognitionFailure(
        RecognitionErrorCode.CANCELLED,
        '用户取消识别',
        true,
        `cancelled ${requestId}`
      ));
      hilog.info(DOMAIN, TAG, '已取消排队请求: %{public}s', requestId);
    }
  }

  async dispose(): Promise<void> {
    this.disposed = true;
    if (this.pending !== null) {
      const old = this.pending;
      this.pending = null;
      old.reject(new RecognitionFailure(
        RecognitionErrorCode.CANCELLED,
        '服务已释放',
        false,
        'disposed'
      ));
    }
    NativeBridge.disposeNative();
    hilog.info(DOMAIN, TAG, '识别服务已释放');
  }

  // ==================== 内部方法 ====================

  private validateImage(image: ImageSource): void {
    if (image.width <= 0 || image.height <= 0) {
      throw new RecognitionFailure(
        RecognitionErrorCode.IMAGE_INVALID,
        '图像尺寸无效',
        true,
        `invalid dimensions ${image.width}x${image.height}`
      );
    }
    const expectedLength = image.rowStride * image.height;
    if (image.data.byteLength !== expectedLength) {
      throw new RecognitionFailure(
        RecognitionErrorCode.IMAGE_INVALID,
        '图像数据长度不匹配',
        true,
        `expected ${expectedLength}, got ${image.data.byteLength}`
      );
    }
    const channels = image.pixelFormat === PixelFormat.RGB_888 ? 3 : 4;
    if (image.rowStride < image.width * channels) {
      throw new RecognitionFailure(
        RecognitionErrorCode.IMAGE_INVALID,
        '图像行步长过小',
        true,
        `rowStride ${image.rowStride} < width*channels ${image.width * channels}`
      );
    }
  }

  private validateOptions(options: InferenceOptions): void {
    if (options.confidenceThreshold <= 0 || options.confidenceThreshold > 1) {
      throw new RecognitionFailure(
        RecognitionErrorCode.INFERENCE_FAILED,
        '置信度阈值必须在 (0, 1] 范围内',
        true,
        `confidenceThreshold=${options.confidenceThreshold}`
      );
    }
    if (options.iouThreshold <= 0 || options.iouThreshold > 1) {
      throw new RecognitionFailure(
        RecognitionErrorCode.INFERENCE_FAILED,
        'IoU 阈值必须在 (0, 1] 范围内',
        true,
        `iouThreshold=${options.iouThreshold}`
      );
    }
    if (options.maxDetections < 1 || options.maxDetections > 300) {
      throw new RecognitionFailure(
        RecognitionErrorCode.INFERENCE_FAILED,
        '最大检测数必须在 1..300 范围内',
        true,
        `maxDetections=${options.maxDetections}`
      );
    }
  }

  private async executeRequest(request: PendingRequest): Promise<void> {
    this.running = true;
    hilog.info(DOMAIN, TAG, '开始执行推理: %{public}s', request.requestId);

    try {
      const result = await this.runInference(request.image, request.options, request.requestId);
      request.resolve(result);
    } catch (e) {
      const err = e as Error;
      if (err instanceof RecognitionFailure) {
        // 详情必须落日志：否则上层只看到「识别失败，请重试」，无法定位真因。
        hilog.error(DOMAIN, TAG, '推理失败 %{public}s: code=%{public}s detail=%{public}s',
          request.requestId, String(err.code), err.detail);
        request.reject(err);
      } else {
        hilog.error(DOMAIN, TAG, '推理异常 %{public}s: %{public}s', request.requestId, err.message);
        request.reject(new RecognitionFailure(
          RecognitionErrorCode.INFERENCE_FAILED,
          '识别失败，请重试',
          true,
          err.message
        ));
      }
    } finally {
      this.running = false;
      // 执行下一个排队请求
      const next = this.pending;
      this.pending = null;
      if (next !== null) {
        hilog.info(DOMAIN, TAG, '执行排队请求: %{public}s', next.requestId);
        this.executeRequest(next);
      }
    }
  }

  private async runInference(image: ImageSource, options: InferenceOptions, requestId: string): Promise<DetectionResult> {
    if (options.executionMode === InferenceExecutionMode.SYNC) {
      return this.runSync(image, options, requestId);
    }
    return this.runTaskPool(image, options, requestId);
  }

  /**
   * 同步模式：在当前线程通过 native Ort C API 执行推理。
   * 会阻塞调用线程（UI 线程），这是同步/异步对比的一部分。
   */
  private runSync(image: ImageSource, options: InferenceOptions, requestId: string): DetectionResult {
    if (!NativeBridge.isNativeReady()) {
      throw new RecognitionFailure(
        RecognitionErrorCode.INFERENCE_FAILED,
        'native session 未就绪',
        false,
        'native bridge not ready'
      );
    }

    const totalStart = Date.now();

    // 预处理
    const preStart = Date.now();
    const preprocess = InferenceEngine.preprocess(
      image.data,
      image.rowStride,
      image.width,
      image.height,
      image.pixelFormat,
      this.modelInfo.inputWidth,
      this.modelInfo.inputHeight
    );
    const preprocessMs = Date.now() - preStart;

    // 推理
    const inferStart = Date.now();
    // preprocess.tensor 是 Float32Array，buffer 无偏移；直接取底层 ArrayBuffer 传给 native
    const inputBuf = preprocess.tensor.buffer as ArrayBuffer;
    const outputBuffer = NativeBridge.runNative(
      inputBuf,
      [1, 3, this.modelInfo.inputHeight, this.modelInfo.inputWidth],
      this.modelInfo.inputName,
      this.modelInfo.outputName,
      MODEL_OUTPUT_BYTES
    );
    const inferenceMs = Date.now() - inferStart;

    // 后处理
    const postStart = Date.now();
    const boxes = InferenceEngine.postprocess(
      outputBuffer,
      preprocess.letterbox,
      image.width,
      image.height,
      8400,
      this.modelInfo.classCount,
      options
    );
    const postprocessMs = Date.now() - postStart;

    const totalMs = Date.now() - totalStart;
    // 同步路径的 session 在 initialize() 阶段创建，识别本身不建 session，故 coldStart 恒为 false；
    // 但把本次进程内的 session 创建耗时带上，便于和 TaskPool 路径同口径对比（R3-03）。
    const timing: InferenceTiming = {
      preprocessMs,
      inferenceMs,
      postprocessMs,
      totalMs,
      coldStart: false,
      modelLoadMs: this.modelLoadMs
    };

    return {
      requestId,
      imageId: image.imageId,
      imageWidth: image.width,
      imageHeight: image.height,
      boxes,
      timing,
      executionMode: InferenceExecutionMode.SYNC,
      confidenceThreshold: options.confidenceThreshold,
      iouThreshold: options.iouThreshold,
      modelId: this.modelInfo.modelId,
      modelSha256: this.modelInfo.sha256,
      recognizedAtMs: Date.now()
    };
  }

  /**
   * TaskPool 模式：在工作线程中执行推理。
   * session 在任务内部创建/使用/关闭，不跨线程传递。
   */
  private async runTaskPool(image: ImageSource, options: InferenceOptions, requestId: string): Promise<DetectionResult> {
    // TaskPool 会把任务参数序列化后跨线程传递，大像素缓冲会在这里直接失败。
    // 实测 30.3MB（1920×4138 RGB）失败、9.4MB 成功，按 16MB 保守设限并降级同步执行，
    // 避免「大图 + 默认 TaskPool 模式」变成用户可见的失败。
    const bytes: number = image.data.byteLength;
    if (bytes > TASKPOOL_MAX_BYTES) {
      hilog.warn(DOMAIN, TAG,
        '像素缓冲 %{public}d B 超过 TaskPool 序列化上限 %{public}d B，降级为 SYNC 执行: %{public}s',
        bytes, TASKPOOL_MAX_BYTES, requestId);
      return this.runSync(image, options, requestId);
    }

    const pixelFormatStr = image.pixelFormat === PixelFormat.RGBA_8888 ? 'rgba8888' : 'rgb888';

    const task = new taskpool.Task(
      runInferenceTask,
      this.modelPath,
      image.data,
      image.width,
      image.height,
      image.rowStride,
      pixelFormatStr,
      options,
      requestId,
      image.imageId,
      this.modelInfo
    );
    // 复制像素缓冲区，不转移所有权，UI 仍可显示原图
    task.setCloneList([image.data]);

    const rawResult = await taskpool.execute(task);
    const outcome = rawResult as RecognitionOutcome;

    if (!outcome.ok) {
      const err = outcome.error!;
      throw new RecognitionFailure(err.code, err.message, err.recoverable, err.detail);
    }
    return outcome.result!;
  }
}
