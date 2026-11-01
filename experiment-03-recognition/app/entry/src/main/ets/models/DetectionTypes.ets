/**
 * 检测结果、推理配置、耗时与识别状态共享契约。由 Agent 0 维护。
 */

/** 推理执行方式。 */
export enum InferenceExecutionMode {
  /** 在调用线程同步执行，会占用 UI 线程。 */
  SYNC = 'sync',
  /** 在 TaskPool 并发任务中执行，不占用 UI 线程。 */
  TASK_POOL = 'taskpool'
}

/** 页面可展示的识别状态。 */
export enum RecognitionStatus {
  /** 尚未初始化。 */
  IDLE = 'idle',
  /** 正在检查模型和原生库。 */
  INITIALIZING = 'initializing',
  /** 已就绪，可以发起识别。 */
  READY = 'ready',
  /** 识别进行中。 */
  RUNNING = 'running',
  /** 识别成功且至少有一个检测框。 */
  SUCCEEDED = 'succeeded',
  /** 识别成功但没有检测框。 */
  EMPTY = 'empty',
  /** 本次识别失败，可重试。 */
  ERROR = 'error',
  /** 模型缺失、模型损坏或设备 ABI 不支持，识别入口不可用。 */
  UNAVAILABLE = 'unavailable'
}

/** 统一错误码。 */
export enum RecognitionErrorCode {
  MODEL_MISSING = 'MODEL_MISSING',
  MODEL_INVALID = 'MODEL_INVALID',
  UNSUPPORTED_ABI = 'UNSUPPORTED_ABI',
  IMAGE_INVALID = 'IMAGE_INVALID',
  INFERENCE_FAILED = 'INFERENCE_FAILED',
  CANCELLED = 'CANCELLED'
}

/**
 * 单个检测框。
 *
 * 坐标空间：ImageSource 方向归一化后的原图像素坐标，原点左上角。
 * left/top/right/bottom 为浮点像素值，已裁剪到 [0, width] 与 [0, height]；
 * 必须满足 right > left 且 bottom > top。分类编号与 COCO_CLASSES 下标一致。
 */
export interface DetectionBox {
  classId: number;
  label: string;
  /** 0..1，取 80 个类别分数中的最大值；模型输出不含 objectness。 */
  confidence: number;
  left: number;
  top: number;
  right: number;
  bottom: number;
}

/** 分阶段耗时，单位毫秒。`totalMs` 为三段之和加上调度开销。 */
export interface InferenceTiming {
  preprocessMs: number;
  inferenceMs: number;
  postprocessMs: number;
  totalMs: number;
  /** 本次请求是否新建了 ONNX session。 */
  coldStart: boolean;
  /** 新建 session 的耗时；复用 session 时为 0。 */
  modelLoadMs: number;
}

/** 单次识别的输入选项。 */
export interface InferenceOptions {
  /** 置信度阈值，范围 (0, 1]，默认 0.25。过滤发生在 NMS 之前。 */
  confidenceThreshold: number;
  /** 按类别 NMS 的 IoU 阈值，范围 (0, 1]，默认 0.7。 */
  iouThreshold: number;
  /** NMS 后最多保留的检测框数量，默认 300。 */
  maxDetections: number;
  executionMode: InferenceExecutionMode;
}

/** 一次成功识别（含空结果）的全部输出。 */
export interface DetectionResult {
  /** 调用方生成的请求标识，跨线程原样返回。不得作为数据库主键或上传幂等键。 */
  requestId: string;
  /** 对 ImageSource.imageId 的原样引用。 */
  imageId: string;
  /** 坐标空间对应的原图宽度。 */
  imageWidth: number;
  /** 坐标空间对应的原图高度。 */
  imageHeight: number;
  /** 已排序（置信度降序）且已裁剪的检测框。 */
  boxes: DetectionBox[];
  timing: InferenceTiming;
  executionMode: InferenceExecutionMode;
  /** 本次结果实际使用的阈值，界面必须展示该值。 */
  confidenceThreshold: number;
  iouThreshold: number;
  /** 模型标识，来自 MODEL_INFO。 */
  modelId: string;
  /** 模型文件 SHA-256，便于日志核对。 */
  modelSha256: string;
  /** 识别完成、即将返回调用方的时间，Unix 毫秒。 */
  recognizedAtMs: number;
}

/** 可序列化的错误信息，可跨 TaskPool 边界传递。 */
export interface RecognitionError {
  code: RecognitionErrorCode;
  /** 面向用户的简短中文说明。 */
  message: string;
  /** true 表示处理后可重试；false 表示需要更换模型或设备。 */
  recoverable: boolean;
  /** 原始错误信息或诊断细节，可为空。 */
  detail?: string;
}

/**
 * 公共 API 抛出的错误类型。
 * TaskPool 内部不得跨线程抛 Error 对象，必须在任务内转换为 RecognitionError。
 */
export class RecognitionFailure extends Error {
  code: RecognitionErrorCode;
  recoverable: boolean;
  detail: string;

  constructor(code: RecognitionErrorCode, message: string, recoverable: boolean, detail: string = '') {
    super(message);
    this.code = code;
    this.recoverable = recoverable;
    this.detail = detail;
  }

  toRecognitionError(): RecognitionError {
    return {
      code: this.code,
      message: this.message,
      recoverable: this.recoverable,
      detail: this.detail
    };
  }
}

/** 模型静态信息。模型缺失时仍然保留，用于界面和日志。 */
export interface ModelInfo {
  modelId: string;
  fileName: string;
  /** rawfile 内路径，相对 resources/rawfile。 */
  assetPath: string;
  sha256: string;
  inputName: string;
  outputName: string;
  inputWidth: number;
  inputHeight: number;
  classCount: number;
  opset: number;
}

/** 初始化结果。available=false 时 UI 必须显示识别不可用。 */
export interface InferenceAvailability {
  available: boolean;
  modelInfo: ModelInfo;
  error?: RecognitionError;
}

/** TaskPool 并发任务的统一返回值，避免跨线程传递 Error。 */
export interface RecognitionOutcome {
  ok: boolean;
  result?: DetectionResult;
  error?: RecognitionError;
}

/** 页面状态快照。旧请求必须通过 requestId/imageId 与当前页面比对后再写回。 */
export interface RecognitionState {
  status: RecognitionStatus;
  modelAvailable: boolean;
  /** 当前页面正在等待或已展示的请求标识。 */
  requestId: string;
  /** 当前页面图片标识。 */
  imageId: string;
  result?: DetectionResult;
  error?: RecognitionError;
}
