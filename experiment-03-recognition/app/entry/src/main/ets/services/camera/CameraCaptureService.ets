/**
 * Camera Kit 采集服务：摄像头枚举、实时预览会话、拍照、前后切换与资源生命周期。
 *
 * 设计要点：
 * - 单例；同一时刻仅维护一条 PhotoSession（NORMAL_PHOTO），与第一阶段单预览组件对应。
 * - 拍照结果通过 photoAvailable 回调拿到 JPEG 字节，再走 ImageDecoder 共享管线，
 *   完成 EXIF 方向归一化后产出契约 ImageSource（isMirrored=false）。
 * - captureSetting 显式 mirror:false、quality:HIGH，rotation 由 PhotoSession.getPhotoRotation()
 *   按设备当前方向计算（API 23+ 不传参由系统取设备方向）。
 * - start/switch/stop 内部串行化，重复进入退出、切后台恢复不产生并发会话。
 */
import { camera } from '@kit.CameraKit';
import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ImageOrigin, ImageSource } from '../../models/ImageTypes';
import { RecognitionErrorCode, RecognitionFailure } from '../../models/DetectionTypes';
import { decodeToImageSource } from './ImageDecoder';

const TAG: string = 'CameraCaptureService';
const DOMAIN: number = 0x0000;

/** 预览目标分辨率（按面积就近选择）。 */
const PREVIEW_TARGET_WIDTH: number = 1280;
const PREVIEW_TARGET_HEIGHT: number = 720;
/** 拍照目标分辨率（按面积就近选择）；YOLO letterbox 到 640，2MP 足够且控制解码内存。 */
const PHOTO_TARGET_WIDTH: number = 1920;
const PHOTO_TARGET_HEIGHT: number = 1080;

/**
 * 照片送达超时（毫秒）。
 * 实测（API 24 模拟器）：PhotoOutput.capture() 会在几毫秒内 resolve，
 * 但 photoAvailable 回调始终不触发，导致 capture() 的 Promise 语义
 * 与「拿到照片」不一致，界面会永久停在 CAPTURING 转圈。
 * 因此以「照片真正送达」为完成条件，并设超时兜底。
 */
const PHOTO_DELIVERY_TIMEOUT_MS: number = 6000;

/** 一次拍照的送达等待器。 */
interface PhotoDeliveryWaiter {
  /** 结束等待：err 为空表示成功送达。 */
  settle: (err?: Error) => void;
}


/** 摄像头位置分类（前后切换只使用 BACK/FRONT，其余保留展示）。 */
export enum CameraPositionKind {
  BACK = 'back',
  FRONT = 'front',
  OTHER = 'other'
}

/** 可供页面展示的摄像头信息。 */
export interface CameraDeviceInfo {
  cameraId: string;
  position: CameraPositionKind;
  /** 面向用户的简短名称，如“后置”“前置”。 */
  displayName: string;
}

/** 采集服务状态，供组件渲染操作可用性。 */
export enum CameraServiceState {
  /** 未启动或已释放。 */
  IDLE = 'idle',
  /** 正在打开摄像头/配置会话。 */
  STARTING = 'starting',
  /** 预览运行中，可以拍照。 */
  READY = 'ready',
  /** 一次拍照进行中（capture 已发出，等待照片回调）。 */
  CAPTURING = 'capturing',
  /** 发生错误；错误详情经 onError 回调给出。 */
  ERROR = 'error'
}

/** 组件侧错误事件。 */
export interface CameraErrorInfo {
  /** 错误分类：permission/no-camera/open-failed/session-failed/capture-failed/decode-failed。 */
  kind: string;
  /** 面向用户的中文说明。 */
  message: string;
  /** true 表示可重试（如会话重启）；false 表示需要更换设备或授权。 */
  recoverable: boolean;
  detail: string;
}

/** 采集服务事件回调集，由 CameraPreview 组件注册。 */
export interface CameraServiceCallbacks {
  /** 拍照并解码完成，产出契约 ImageSource。 */
  onPhoto: (image: ImageSource) => void;
  /** 错误事件；服务状态同时转为 ERROR（拍照失败会回到 READY）。 */
  onError: (error: CameraErrorInfo) => void;
  /** 状态变化事件。 */
  onStateChange: (state: CameraServiceState) => void;
}

/** 服务内部错误类型，便于 catch 后用 instanceof 还原分类（ArkTS 不支持类型谓词）。 */
class CameraServiceError extends Error {
  kind: string;
  recoverable: boolean;
  detail: string;

  constructor(kind: string, message: string, recoverable: boolean, detail: string) {
    super(message);
    this.kind = kind;
    this.recoverable = recoverable;
    this.detail = detail;
  }

  toInfo(): CameraErrorInfo {
    const info: CameraErrorInfo = {
      kind: this.kind,
      message: this.message,
      recoverable: this.recoverable,
      detail: this.detail
    };
    return info;
  }
}

function toCameraErrorInfo(kind: string, message: string, recoverable: boolean, e: Object): CameraErrorInfo {
  const info: CameraErrorInfo = {
    kind: kind,
    message: message,
    recoverable: recoverable,
    detail: JSON.stringify(e)
  };
  return info;
}

/** 按目标面积就近挑选 profile。 */
function pickProfile(profiles: Array<camera.Profile>, targetWidth: number, targetHeight: number): camera.Profile | null {
  let best: camera.Profile | null = null;
  let bestDiff: number = Number.MAX_VALUE;
  const targetArea: number = targetWidth * targetHeight;
  for (const profile of profiles) {
    const area: number = profile.size.width * profile.size.height;
    const diff: number = Math.abs(area - targetArea);
    if (diff < bestDiff) {
      bestDiff = diff;
      best = profile;
    }
  }
  return best;
}

export class CameraCaptureService {
  private static instance: CameraCaptureService | null = null;

  static getInstance(): CameraCaptureService {
    if (CameraCaptureService.instance === null) {
      CameraCaptureService.instance = new CameraCaptureService();
    }
    return CameraCaptureService.instance;
  }

  private constructor() {
  }

  private callbacks: CameraServiceCallbacks | null = null;
  private state: CameraServiceState = CameraServiceState.IDLE;
  private devices: Array<camera.CameraDevice> = [];
  private cameraInfos: Array<CameraDeviceInfo> = [];
  private activeCameraId: string = '';

  private cameraManager: camera.CameraManager | null = null;
  private cameraInput: camera.CameraInput | null = null;
  private session: camera.PhotoSession | null = null;
  private previewOutput: camera.PreviewOutput | null = null;
  private photoOutput: camera.PhotoOutput | null = null;
  /** start/switch/stop 串行化令牌。 */
  private opChain: Promise<void> = Promise.resolve();
  /** 当前拍照的送达等待器；null 表示没有进行中的拍照。 */
  private photoDelivery: PhotoDeliveryWaiter | null = null;

  /** 注册/替换事件回调。 */
  setCallbacks(callbacks: CameraServiceCallbacks | null): void {
    this.callbacks = callbacks;
  }

  getState(): CameraServiceState {
    return this.state;
  }

  getCameraInfos(): Array<CameraDeviceInfo> {
    return this.cameraInfos;
  }

  getActiveCameraId(): string {
    return this.activeCameraId;
  }

  private setState(next: CameraServiceState): void {
    if (this.state !== next) {
      this.state = next;
      this.callbacks?.onStateChange(next);
    }
  }

  private reportError(error: CameraErrorInfo): void {
    hilog.error(DOMAIN, TAG, 'Camera error [%{public}s]: %{public}s', error.kind, error.detail);
    this.callbacks?.onError(error);
  }

  /**
   * 枚举支持 NORMAL_PHOTO 的摄像头。需要相机权限已授权。
   * 结果缓存于服务内，getCameraInfos() 可读。
   */
  async enumerateCameras(context: common.Context): Promise<Array<CameraDeviceInfo>> {
    const manager: camera.CameraManager = camera.getCameraManager(context);
    let devices: Array<camera.CameraDevice>;
    try {
      devices = manager.getSupportedCameras();
    } catch (e) {
      throw new CameraServiceError('open-failed', '无法枚举设备摄像头', false, JSON.stringify(e));
    }
    const infos: Array<CameraDeviceInfo> = [];
    const supported: Array<camera.CameraDevice> = [];
    for (const device of devices) {
      let modes: Array<camera.SceneMode> = [];
      try {
        modes = manager.getSupportedSceneModes(device);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'getSupportedSceneModes failed for %{public}s: %{public}s',
          device.cameraId, JSON.stringify(e));
      }
      if (modes.indexOf(camera.SceneMode.NORMAL_PHOTO) < 0) {
        continue;
      }
      let position: CameraPositionKind = CameraPositionKind.OTHER;
      let displayName: string = '其他';
      if (device.cameraPosition === camera.CameraPosition.CAMERA_POSITION_BACK) {
        position = CameraPositionKind.BACK;
        displayName = '后置';
      } else if (device.cameraPosition === camera.CameraPosition.CAMERA_POSITION_FRONT) {
        position = CameraPositionKind.FRONT;
        displayName = '前置';
      }
      supported.push(device);
      infos.push({ cameraId: device.cameraId, position: position, displayName: displayName });
    }
    this.cameraManager = manager;
    this.devices = supported;
    this.cameraInfos = infos;
    hilog.info(DOMAIN, TAG, 'Enumerated %{public}d photo cameras', infos.length);
    return infos;
  }

  /** 默认摄像头：优先后置，否则列表第一个。 */
  pickDefaultCameraId(): string {
    for (const info of this.cameraInfos) {
      if (info.position === CameraPositionKind.BACK) {
        return info.cameraId;
      }
    }
    return this.cameraInfos.length > 0 ? this.cameraInfos[0].cameraId : '';
  }

  /** 切换目标：返回与当前不同的下一个摄像头，单摄时返回空串。 */
  pickNextCameraId(): string {
    if (this.cameraInfos.length <= 1) {
      return '';
    }
    const index: number = this.cameraInfos.findIndex((info) => info.cameraId === this.activeCameraId);
    const next: number = (index + 1) % this.cameraInfos.length;
    return this.cameraInfos[next].cameraId;
  }

  /**
   * 打开指定摄像头并启动预览。串行执行；重复调用前先 stop。
   *
   * @param context UI 上下文（getCameraManager 需要）。
   * @param cameraId 目标摄像头；空串时使用默认摄像头。
   * @param surfaceId XComponent 预览 surfaceId。
   */
  start(context: common.Context, cameraId: string, surfaceId: string): Promise<void> {
    return this.enqueue(async () => {
      await this.releaseLocked();
      await this.openLocked(context, cameraId, surfaceId);
    });
  }

  /** 切换摄像头（先释放当前会话，再以同一 surface 打开新摄像头）。 */
  switchCamera(context: common.Context, cameraId: string, surfaceId: string): Promise<void> {
    return this.start(context, cameraId, surfaceId);
  }

  /** 停止预览并释放全部相机资源；可重复调用。 */
  stop(): Promise<void> {
    return this.enqueue(async () => {
      await this.releaseLocked();
    });
  }

  /**
   * 拍照。结果经 onPhoto 回调返回；失败经 onError 回调并恢复 READY。
   * 非 READY 或上一张未完成时以普通 Error 拒绝（契约：未就绪不返回空图）。
   *
   * 完成条件为「照片真正送达」而非 capture() resolve：实测部分设备
   * capture() 立即 resolve 但 photoAvailable 不回调，若以 resolve 为准
   * 会让界面永久停在 CAPTURING。
   */
  async capture(): Promise<void> {
    const output: camera.PhotoOutput | null = this.photoOutput;
    if (this.state !== CameraServiceState.READY || output === null) {
      throw new Error('相机未就绪，无法拍照');
    }
    this.setState(CameraServiceState.CAPTURING);
    // HarmonyOS CameraKit PhotoSession 没有 getPhotoRotation；
    // PhotoCaptureSetting 传 ROTATION_0 + mirror:false 即可，JPEG 方向由系统处理。
    const setting: camera.PhotoCaptureSetting = {
      quality: camera.QualityLevel.QUALITY_LEVEL_HIGH,
      rotation: camera.ImageRotation.ROTATION_0,
      // 契约 2.2：送入识别的静态图不镜像。
      mirror: false
    };
    const delivered: Promise<void> = this.beginPhotoDelivery();
    // capture() 抛错时不会 await delivered，先挂空 catch 避免 unhandled rejection。
    delivered.catch(() => {
    });
    try {
      await output.capture(setting);
      await delivered;
    } catch (e) {
      this.cancelPhotoDelivery();
      this.setState(CameraServiceState.READY);
      const message: string = e instanceof Error ? e.message : '拍照失败，请重试';
      throw new Error(message);
    }
  }

  /** 开始等待照片送达；超时则以 Error 拒绝。 */
  private beginPhotoDelivery(): Promise<void> {
    return new Promise<void>((resolve: () => void, reject: (e: Error) => void) => {
      const timer: number = setTimeout(() => {
        if (this.photoDelivery === null) {
          return;
        }
        this.photoDelivery = null;
        hilog.error(DOMAIN, TAG, 'photo delivery timeout after %{public}d ms', PHOTO_DELIVERY_TIMEOUT_MS);
        reject(new Error('拍照超时：相机没有返回图像，请重试'));
      }, PHOTO_DELIVERY_TIMEOUT_MS);
      this.photoDelivery = {
        settle: (err?: Error): void => {
          clearTimeout(timer);
          this.photoDelivery = null;
          if (err !== undefined) {
            reject(err);
          } else {
            resolve();
          }
        }
      };
    });
  }

  /** 结束等待（成功或失败）；无进行中拍照时为空操作。 */
  private settlePhotoDelivery(err?: Error): void {
    const waiter: PhotoDeliveryWaiter | null = this.photoDelivery;
    if (waiter === null) {
      return;
    }
    waiter.settle(err);
  }

  /** 丢弃等待器（不改状态、不 resolve/reject 之外的动作）。 */
  private cancelPhotoDelivery(): void {
    const waiter: PhotoDeliveryWaiter | null = this.photoDelivery;
    if (waiter === null) {
      return;
    }
    this.photoDelivery = null;
    waiter.settle(new Error('拍照已取消'));
  }

  private enqueue(op: () => Promise<void>): Promise<void> {
    const run: Promise<void> = this.opChain.then(op);
    this.opChain = run.catch((e: Error) => {
      hilog.error(DOMAIN, TAG, 'op chain error: %{public}s', JSON.stringify(e));
    });
    return run;
  }

  private async openLocked(context: common.Context, cameraId: string, surfaceId: string): Promise<void> {
    this.setState(CameraServiceState.STARTING);
    try {
      let manager: camera.CameraManager | null = this.cameraManager;
      if (manager === null) {
        manager = camera.getCameraManager(context);
        this.cameraManager = manager;
      }
      if (this.devices.length === 0) {
        await this.enumerateCameras(context);
      }
      const targetId: string = cameraId.length > 0 ? cameraId : this.pickDefaultCameraId();
      const device: camera.CameraDevice | undefined =
        this.devices.find((item) => item.cameraId === targetId);
      if (device === undefined) {
        throw new CameraServiceError('no-camera', '未检测到可用摄像头', false, 'empty camera list');
      }
      const capability: camera.CameraOutputCapability =
        manager.getSupportedOutputCapability(device, camera.SceneMode.NORMAL_PHOTO);
      const previewProfile: camera.Profile | null =
        pickProfile(capability.previewProfiles, PREVIEW_TARGET_WIDTH, PREVIEW_TARGET_HEIGHT);
      const photoProfiles: Array<camera.Profile> = capability.photoProfiles.filter(
        (profile) => profile.format === camera.CameraFormat.CAMERA_FORMAT_JPEG);
      const photoProfile: camera.Profile | null =
        pickProfile(photoProfiles.length > 0 ? photoProfiles : capability.photoProfiles,
          PHOTO_TARGET_WIDTH, PHOTO_TARGET_HEIGHT);
      if (previewProfile === null || photoProfile === null) {
        throw new CameraServiceError('no-camera', '摄像头不支持所需的预览或拍照格式', false, 'empty profile list');
      }
      hilog.info(DOMAIN, TAG,
        'Open camera %{public}s, preview %{public}dx%{public}d, photo %{public}dx%{public}d',
        device.cameraId, previewProfile.size.width, previewProfile.size.height,
        photoProfile.size.width, photoProfile.size.height);

      // 打开输入。
      const input: camera.CameraInput = manager.createCameraInput(device);
      await input.open();
      this.cameraInput = input;

      // 配置会话。
      const session: camera.PhotoSession = manager.createSession<camera.PhotoSession>(camera.SceneMode.NORMAL_PHOTO);
      const previewOutput: camera.PreviewOutput = manager.createPreviewOutput(previewProfile, surfaceId);
      const photoOutput: camera.PhotoOutput = manager.createPhotoOutput(photoProfile);
      this.session = session;
      this.previewOutput = previewOutput;
      this.photoOutput = photoOutput;
      photoOutput.on('photoAvailable', (err, photo) => {
        this.onPhotoAvailable(err, photo);
      });

      session.beginConfig();
      session.addInput(input);
      session.addOutput(previewOutput);
      session.addOutput(photoOutput);
      await session.commitConfig();
      await session.start();

      this.activeCameraId = device.cameraId;
      this.setState(CameraServiceState.READY);
      hilog.info(DOMAIN, TAG, 'Camera %{public}s preview started', device.cameraId);
    } catch (e) {
      await this.releaseLocked();
      this.setState(CameraServiceState.ERROR);
      if (e instanceof CameraServiceError) {
        this.reportError(e.toInfo());
      } else {
        this.reportError(toCameraErrorInfo('open-failed', '相机打开失败，请重试', true, e));
      }
    }
  }

  private onPhotoAvailable(err: BusinessError, photo: camera.Photo): void {
    if (err !== undefined && err.code !== 0) {
      this.setState(CameraServiceState.READY);
      this.reportError(toCameraErrorInfo('capture-failed', '拍照失败，请重试', true, err));
      this.settlePhotoDelivery(new Error('拍照失败，请重试'));
      return;
    }
    this.handlePhoto(photo).catch((e: Error) => {
      hilog.error(DOMAIN, TAG, 'handlePhoto failed: %{public}s', JSON.stringify(e));
    });
  }

  private async handlePhoto(photo: camera.Photo): Promise<void> {
    let main: image.Image | null = null;
    try {
      main = photo.main;
      const component: image.Component = await main.getComponent(image.ComponentType.JPEG);
      // 复制为紧凑 ArrayBuffer 后再释放原生 image.Image。
      const jpeg: ArrayBuffer = component.byteBuffer.slice(0);
      await main.release();
      main = null;
      await photo.release();

      const source: image.ImageSource = image.createImageSource(jpeg);
      try {
        const result: ImageSource = await decodeToImageSource(source, ImageOrigin.CAMERA);
        this.setState(CameraServiceState.READY);
        // 先结束等待再回调，保证 capture() 的 Promise 在页面拿到结果前已结算。
        this.settlePhotoDelivery();
        this.callbacks?.onPhoto(result);
      } finally {
        try {
          await source.release();
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'ImageSource release failed: %{public}s', JSON.stringify(e));
        }
      }
    } catch (e) {
      this.setState(CameraServiceState.READY);
      if (e instanceof RecognitionFailure) {
        this.reportError({
          kind: 'decode-failed',
          message: e.message,
          recoverable: e.recoverable,
          detail: e.detail
        });
      } else {
        this.reportError(toCameraErrorInfo('capture-failed', '照片处理失败，请重试', true, e));
      }
      this.settlePhotoDelivery(new Error(e instanceof RecognitionFailure ? e.message : '照片处理失败，请重试'));
    } finally {
      if (main !== null) {
        try {
          await main.release();
          await photo.release();
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'Photo release failed: %{public}s', JSON.stringify(e));
        }
      }
    }
  }

  /** 释放全部相机资源；内部使用，调用方需持串行令牌。 */
  private async releaseLocked(): Promise<void> {
    // 释放前先结束可能仍在等待的拍照，避免 Promise 永久挂起。
    this.cancelPhotoDelivery();
    if (this.photoOutput !== null) {
      try {
        this.photoOutput.off('photoAvailable');
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'photoOutput off failed: %{public}s', JSON.stringify(e));
      }
      this.photoOutput = null;
    }
    if (this.session !== null) {
      try {
        await this.session.stop();
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'session stop failed: %{public}s', JSON.stringify(e));
      }
      try {
        await this.session.release();
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'session release failed: %{public}s', JSON.stringify(e));
      }
      this.session = null;
    }
    this.previewOutput = null;
    if (this.cameraInput !== null) {
      try {
        await this.cameraInput.close();
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'cameraInput close failed: %{public}s', JSON.stringify(e));
      }
      this.cameraInput = null;
    }
    this.activeCameraId = '';
    this.setState(CameraServiceState.IDLE);
  }
}
