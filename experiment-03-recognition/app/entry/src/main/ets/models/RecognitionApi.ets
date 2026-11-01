/**
 * 采集与推理的公共 API 契约。实现类由 Agent 1 / Agent 2 提供。
 */
import { ImageSource } from './ImageTypes';
import {
  DetectionResult,
  InferenceAvailability,
  InferenceOptions,
  RecognitionError,
  RecognitionErrorCode
} from './DetectionTypes';

/**
 * Agent 1 实现。返回值必须是方向归一化后的 ImageSource。
 * 取消、权限拒绝、解码失败分别以 RecognitionFailure(CANCELLED/... ) 或普通 Error 拒绝；
 * 拒绝时不得产生半成品 ImageSource。
 */
export interface ImageCaptureApi {
  /** 相册选图；用户取消时以 CANCELLED 拒绝。 */
  pickFromGallery(): Promise<ImageSource>;
  /** 相机拍照；相机未就绪时以普通 Error 拒绝，不返回空图。 */
  capturePhoto(): Promise<ImageSource>;
}

/**
 * Agent 2 实现。必须是单例或由页面持有唯一实例。
 * - initialize 幂等；模型缺失或 ABI 不支持时返回 available=false，不抛出。
 * - recognize 在失败时以 RecognitionFailure 拒绝。
 * - 同一实例最多一个推理在执行；新请求覆盖尚未开始的旧请求（latest wins），
 *   已在执行的请求不会被中断，其返回值仍带原 requestId 供调用方丢弃。
 * - dispose 后实例不可再次使用。
 */
export interface RecognitionServiceApi {
  initialize(): Promise<InferenceAvailability>;
  getAvailability(): InferenceAvailability;
  recognize(image: ImageSource, options: InferenceOptions, requestId: string): Promise<DetectionResult>;
  /** 取消尚未开始的请求；已开始执行的请求只能由调用方丢弃结果。 */
  cancel(requestId: string): void;
  dispose(): Promise<void>;
}

/** 服务层统一错误转换入口；实现类可直接抛出 RecognitionFailure。 */
export function toRecognitionError(error: Object): RecognitionError {
  return {
    code: RecognitionErrorCode.INFERENCE_FAILED,
    message: '识别失败，请重试',
    recoverable: true,
    detail: error.toString()
  };
}
