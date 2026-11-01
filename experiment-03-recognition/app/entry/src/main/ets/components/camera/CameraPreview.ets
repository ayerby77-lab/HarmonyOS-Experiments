/**
 * 相机预览组件（契约 4.1 相机路径）。
 *
 * 内嵌 XComponent 预览、拍照按钮、前后切换按钮，以及权限/错误提示面板。
 * 页面（Agent 3）只需放置本组件并接收回调：
 *
 * ```ts
 * CameraPreview({
 *   onPhotoCaptured: (result: CameraCaptureResult) => { this.currentImage = result.image; ... },
 *   onCameraError: (error: CameraErrorEvent) => { ... } // 相机不可用时保留相册入口
 * })
 * ```
 *
 * 生命周期：
 * - aboutToAppear：注册应用前后台监听，发起权限与摄像头初始化；
 * - surface 创建/权限就绪两者齐备后启动预览；
 * - 切后台释放相机资源，回前台自动恢复（含从系统设置返回后的权限复查）；
 * - aboutToDisappear：注销监听并停止会话，保证重复进入退出无资源占用。
 */
import { application, ApplicationStateChangeCallback, common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ImageSource } from '../../models/ImageTypes';
import {
  CameraCaptureService,
  CameraDeviceInfo,
  CameraErrorInfo,
  CameraServiceState
} from '../../services/camera/CameraCaptureService';
import {
  CameraPermissionResult,
  ensureCameraPermission,
  hasCameraPermission,
  openCameraSettings
} from '../../services/camera/CameraPermission';

const TAG: string = 'CameraPreview';
const DOMAIN: number = 0x0000;

/**
 * 模块级降级标记（Q-18/BLK-11）：
 * 部分运行时（HarmonyOS 6.1.1 API 24 模拟器实测）off 带参抛
 * "applicationStateCallback must be function"、无参抛 401，两种形态均不可用。
 * 第一次注销失败时置位并记一条日志，之后销毁不再重复尝试，
 * 避免反复进出页面刷异常日志；残留监听因组件 disposed 标记惰性返回。
 */
let appStateOffWithCallbackRejected: boolean = false;
let appStateOffUnsupported: boolean = false;

/**
 * 拍照超时（毫秒）。
 * 无真实传感器的设备/模拟器上，PhotoOutput 的 capture 可能一直不回调，
 * 界面会永久停在 CAPTURING 转圈（实测卡死 30s+）。必须有兜底解除状态。
 */
const CAPTURE_TIMEOUT_MS: number = 8000;

/** 拍照结果事件（契约 4.1）。 */
export interface CameraCaptureResult {
  image: ImageSource;
}

/** 相机错误事件；页面可据此保留相册入口并提示。 */
export interface CameraErrorEvent {
  /** permission / no-camera / open-failed / session-failed / capture-failed / decode-failed。 */
  kind: string;
  message: string;
  recoverable: boolean;
}

/** 相机就绪事件，携带可用摄像头与当前摄像头。 */
export interface CameraReadyEvent {
  cameras: Array<CameraDeviceInfo>;
  activeCameraId: string;
}

/** 组件面板状态。 */
enum PanelState {
  /** 正在检查权限与设备。 */
  LOADING,
  /** 预览模式（含启动中/拍照中遮罩）。 */
  PREVIEW,
  /** 权限被拒绝，可再次发起授权。 */
  NEED_PERMISSION,
  /** 权限被禁用且不再弹框，引导去系统设置。 */
  NEED_SETTINGS,
  /** 无可用摄像头或打开失败。 */
  CAMERA_FAILED
}

/** 绑定 surface 生命周期的 XComponentController。 */
class PreviewSurfaceController extends XComponentController {
  onCreated: (surfaceId: string) => void = () => {
  };
  onDestroyed: () => void = () => {
  };

  onSurfaceCreated(surfaceId: string): void {
    this.onCreated(surfaceId);
  }

  onSurfaceDestroyed(surfaceId: string): void {
    this.onDestroyed();
  }
}

@Component
export struct CameraPreview {
  /** 拍照完成回调；交付契约 ImageSource。 */
  onPhotoCaptured?: (result: CameraCaptureResult) => void;
  /** 错误回调；kind=permission/no-camera 时页面应保留相册入口。 */
  onCameraError?: (error: CameraErrorEvent) => void;
  /** 相机就绪回调。 */
  onCameraReady?: (event: CameraReadyEvent) => void;

  @State private panelState: PanelState = PanelState.LOADING;
  @State private serviceState: CameraServiceState = CameraServiceState.IDLE;
  @State private cameras: Array<CameraDeviceInfo> = [];
  @State private activeCameraId: string = '';
  @State private errorMessage: string = '';

  private surfaceController: PreviewSurfaceController = new PreviewSurfaceController();
  private surfaceId: string = '';
  private permissionGranted: boolean = false;
  private starting: boolean = false;
  private wasActiveBeforeBackground: boolean = false;
  private cameraService: CameraCaptureService = CameraCaptureService.getInstance();

  /** 应用状态监听注册成功标记；未注册成功时销毁阶段跳过 off。 */
  private appStateRegistered: boolean = false;
  /** 组件销毁标记；残留（注销失败的运行时）监听据此惰性返回。 */
  private disposed: boolean = false;

  private appStateCallback: ApplicationStateChangeCallback = {
    onApplicationForeground: (): void => {
      if (!this.disposed) {
        this.onAppForeground();
      }
    },
    onApplicationBackground: (): void => {
      if (!this.disposed) {
        this.onAppBackground();
      }
    }
  };

  aboutToAppear(): void {
    this.disposed = false;
    try {
      application.getApplicationContext().on('applicationStateChange', this.appStateCallback);
      this.appStateRegistered = true;
    } catch (e) {
      this.appStateRegistered = false;
      hilog.warn(DOMAIN, TAG, 'on applicationStateChange failed: %{public}s', JSON.stringify(e));
    }
    this.surfaceController.onCreated = (surfaceId: string): void => {
      this.surfaceId = surfaceId;
      this.maybeStartCamera();
    };
    this.surfaceController.onDestroyed = (): void => {
      this.surfaceId = '';
      this.stopCamera();
    };
    this.cameraService.setCallbacks({
      onPhoto: (image: ImageSource): void => {
        this.onPhotoCaptured?.({ image: image });
      },
      onError: (error: CameraErrorInfo): void => {
        this.handleServiceError(error);
      },
      onStateChange: (state: CameraServiceState): void => {
        this.serviceState = state;
        if (state === CameraServiceState.READY) {
          this.activeCameraId = this.cameraService.getActiveCameraId();
          this.panelState = PanelState.PREVIEW;
          this.onCameraReady?.({ cameras: this.cameras, activeCameraId: this.activeCameraId });
        }
      }
    });
    this.initCamera();
  }

  aboutToDisappear(): void {
    // 先置销毁标记：即使注销失败而残留监听（异常运行时），回调也惰性返回。
    this.disposed = true;
    this.unregisterAppStateChange();
    // 组件销毁后不再接收服务侧回调，避免回调触发已销毁的 UI 状态。
    this.cameraService.setCallbacks(null);
    // 异步 stop： singleton 持 opChain 串行令牌保证资源正确释放；
    // 回调已置 null，后续 setState/onPhoto 不会触发已销毁组件。
    this.stopCamera();
  }

  /**
   * 按 SDK 签名 off(type: 'applicationStateChange', callback?: ApplicationStateChangeCallback)
   * 注销应用状态监听（Q-18/BLK-11 修复）：
   * 1. 优先携带注册时保存的同一引用精确注销（官方文档主形态）；
   * 2. 带参形态被运行时拒绝时回退无参注销——CameraPreview 是全屏覆盖层，
   *    销毁时移除该类型全部监听安全；
   * 3. 两种形态均抛错的运行时降级一次后置标记，后续销毁静默跳过，
   *    残留监听因 disposed 惰性返回，反复进出不产生异常日志。
   */
  private unregisterAppStateChange(): void {
    if (!this.appStateRegistered || appStateOffUnsupported) {
      return;
    }
    this.appStateRegistered = false;
    const appContext = application.getApplicationContext();
    if (!appStateOffWithCallbackRejected) {
      try {
        appContext.off('applicationStateChange', this.appStateCallback);
        return;
      } catch (e) {
        appStateOffWithCallbackRejected = true;
        hilog.info(DOMAIN, TAG, 'off with callback rejected, fallback to no-arg: %{public}s', JSON.stringify(e));
      }
    }
    try {
      appContext.off('applicationStateChange');
    } catch (e) {
      appStateOffUnsupported = true;
      hilog.warn(DOMAIN, TAG,
        'off applicationStateChange unsupported on this runtime, listener left inert: %{public}s', JSON.stringify(e));
    }
  }

  /** 权限检查与摄像头枚举。 */
  private initCamera(): void {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    this.panelState = PanelState.LOADING;
    ensureCameraPermission(context).then((result: CameraPermissionResult) => {
      if (result === CameraPermissionResult.GRANTED) {
        this.permissionGranted = true;
        return this.cameraService.enumerateCameras(context).then((cameras: Array<CameraDeviceInfo>) => {
          if (cameras.length === 0) {
            this.panelState = PanelState.CAMERA_FAILED;
            this.errorMessage = '未检测到可用摄像头，可继续使用相册识别';
            this.emitError('no-camera', this.errorMessage, false);
            return;
          }
          this.cameras = cameras;
          this.panelState = PanelState.PREVIEW;
          this.maybeStartCamera();
        });
      }
      this.permissionGranted = false;
      if (result === CameraPermissionResult.DENIED) {
        this.panelState = PanelState.NEED_PERMISSION;
        this.errorMessage = '需要相机权限才能拍照识别，可继续使用相册识别';
        this.emitError('permission', this.errorMessage, true);
      } else {
        this.panelState = PanelState.NEED_SETTINGS;
        this.errorMessage = '相机权限已关闭，请在系统设置中开启后可拍照；也可继续使用相册识别';
        this.emitError('permission', this.errorMessage, false);
      }
      return;
    }).catch((e: Object) => {
      this.panelState = PanelState.CAMERA_FAILED;
      this.errorMessage = '相机初始化失败，可继续使用相册识别';
      this.emitError('open-failed', `${this.errorMessage}（${JSON.stringify(e)}）`, true);
    });
  }

  /** surface 与权限齐备后启动预览。 */
  private maybeStartCamera(): void {
    if (!this.permissionGranted || this.surfaceId.length === 0 || this.cameras.length === 0 || this.starting) {
      return;
    }
    this.starting = true;
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    const targetId: string = this.activeCameraId.length > 0 ?
      this.activeCameraId : this.cameraService.pickDefaultCameraId();
    this.cameraService.start(context, targetId, this.surfaceId)
      .catch((e: Object) => {
        hilog.error(DOMAIN, TAG, 'start camera failed: %{public}s', JSON.stringify(e));
      })
      .finally(() => {
        this.starting = false;
      });
  }

  private stopCamera(): void {
    this.cameraService.stop().catch((e: Object) => {
      hilog.error(DOMAIN, TAG, 'stop camera failed: %{public}s', JSON.stringify(e));
    });
  }

  private handleServiceError(error: CameraErrorInfo): void {
    this.emitError(error.kind, error.message, error.recoverable);
    if (error.kind === 'capture-failed' || error.kind === 'decode-failed') {
      // 拍照级错误：预览继续，仅提示。
      this.errorMessage = error.message;
      return;
    }
    this.panelState = PanelState.CAMERA_FAILED;
    this.errorMessage = `${error.message}，可重试或继续使用相册识别`;
  }

  private emitError(kind: string, message: string, recoverable: boolean): void {
    const event: CameraErrorEvent = { kind: kind, message: message, recoverable: recoverable };
    this.onCameraError?.(event);
  }

  private onAppBackground(): void {
    this.wasActiveBeforeBackground = this.serviceState !== CameraServiceState.IDLE;
    this.stopCamera();
  }

  private onAppForeground(): void {
    // 从系统设置返回时复查权限；从普通后台返回时恢复预览。
    if (this.panelState === PanelState.NEED_SETTINGS || this.panelState === PanelState.NEED_PERMISSION) {
      if (hasCameraPermission()) {
        this.initCamera();
      }
      return;
    }
    if (this.wasActiveBeforeBackground && this.panelState === PanelState.PREVIEW) {
      this.wasActiveBeforeBackground = false;
      this.initCamera();
    }
  }

  private onShutterClick(): void {
    hilog.info(DOMAIN, TAG, 'shutter clicked, serviceState=%{public}s', String(this.serviceState));
    let settled: boolean = false;
    const timer: number = setTimeout(() => {
      if (settled) {
        return;
      }
      settled = true;
      hilog.warn(DOMAIN, TAG, 'capture timeout after %{public}d ms, serviceState=%{public}s',
        CAPTURE_TIMEOUT_MS, String(this.serviceState));
      this.errorMessage = '拍照超时：相机没有返回图像，请重试';
      // 先解除 CAPTURING 再回调，避免父级回调抛错导致界面永久锁死
      this.serviceState = CameraServiceState.READY;
      this.emitError('capture-timeout', this.errorMessage, true);
    }, CAPTURE_TIMEOUT_MS);

    this.cameraService.capture().then(() => {
      hilog.info(DOMAIN, TAG, 'capture resolved, settled=%{public}s', settled ? 'true' : 'false');
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timer);
    }).catch((e: Error) => {
      hilog.error(DOMAIN, TAG, 'capture rejected: %{public}s', e.message);
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timer);
      this.errorMessage = e.message;
      this.serviceState = CameraServiceState.READY;
      this.emitError('capture-failed', e.message, true);
    });
  }

  private onSwitchClick(): void {
    const nextId: string = this.cameraService.pickNextCameraId();
    if (nextId.length === 0 || this.serviceState !== CameraServiceState.READY) {
      return;
    }
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    this.activeCameraId = nextId;
    this.cameraService.switchCamera(context, nextId, this.surfaceId).catch((e: Object) => {
      hilog.error(DOMAIN, TAG, 'switch camera failed: %{public}s', JSON.stringify(e));
    });
  }

  @Builder
  permissionPanel(title: string, primaryText: string, onPrimary: () => void, showSettings: boolean): void {
    Column({ space: 16 }) {
      Text(title)
        .fontSize(15)
        .fontColor('#FFFFFF')
        .textAlign(TextAlign.Center)
        .padding({ left: 24, right: 24 })
      Button(primaryText)
        .fontSize(15)
        .onClick(onPrimary)
      if (showSettings) {
        Button('前往系统设置')
          .fontSize(15)
          .backgroundColor('#444444')
          .onClick(() => {
            const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
            openCameraSettings(context).catch((e: Object) => {
              hilog.error(DOMAIN, TAG, 'open settings failed: %{public}s', JSON.stringify(e));
            });
          })
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#222222')
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      // 预览 surface 常驻最底层，面板以不透明背景覆盖，保证 surface 生命周期稳定。
      XComponent({
        id: 'cameraPreviewSurface',
        type: XComponentType.SURFACE,
        controller: this.surfaceController
      })
        .width('100%')
        .height('100%')

      if (this.panelState === PanelState.LOADING) {
        Column() {
          Text('正在准备相机…')
            .fontSize(15)
            .fontColor('#FFFFFF')
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#222222')
      } else if (this.panelState === PanelState.NEED_PERMISSION) {
        this.permissionPanel(this.errorMessage, '重新授权', () => {
          this.initCamera();
        }, true)
      } else if (this.panelState === PanelState.NEED_SETTINGS) {
        this.permissionPanel(this.errorMessage, '重试', () => {
          this.initCamera();
        }, true)
      } else if (this.panelState === PanelState.CAMERA_FAILED) {
        this.permissionPanel(this.errorMessage, '重试', () => {
          this.initCamera();
        }, false)
      }

      if (this.panelState === PanelState.PREVIEW) {
        // 拍照级错误提示由页面（Index）统一渲染：组件内再画一份会与页面提示叠字。
        // 组件侧只维护 errorMessage 状态，渲染交给 cameraErrorHint。

        // 前后切换：靠右上角，与父级左上角的「返回」分离，避免同点重叠。
        if (this.cameras.length > 1) {
          Row() {
            Button('切换镜头')
              .fontSize(14)
              .backgroundColor('#AA000000')
              .enabled(this.serviceState === CameraServiceState.READY)
              .onClick(() => {
                this.onSwitchClick();
              })
          }
          .width('100%')
          .justifyContent(FlexAlign.End)
          .padding({ left: 16, right: 16, top: 16 })
          .position({ x: 0, y: 0 })
        }

        // 拍照按钮。
        Button() {
          Circle()
            .width(56)
            .height(56)
            .fill(this.serviceState === CameraServiceState.READY ? '#FFFFFF' : '#88FFFFFF')
        }
        .width(72)
        .height(72)
        .backgroundColor(Color.Transparent)
        .enabled(this.serviceState === CameraServiceState.READY)
        .margin({ bottom: 32 })
        .onClick(() => {
          this.onShutterClick();
        })

        if (this.serviceState === CameraServiceState.STARTING ||
          this.serviceState === CameraServiceState.CAPTURING) {
          Column() {
            LoadingProgress()
              .width(48)
              .height(48)
              .color('#FFFFFF')
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .backgroundColor('#33000000')
          .hitTestBehavior(HitTestMode.Block)
        }
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
  }
}
