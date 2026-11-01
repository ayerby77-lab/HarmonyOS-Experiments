/**
 * 智能物品识别助手主页面（Agent 3）。
 *
 * 依赖契约中的 GalleryImageService / RecognitionService；采集与推理实现分别由
 * Agent 1 / Agent 2 提供。页面负责状态机、请求防串图、坐标映射、结果编辑与耗时展示。
 */
import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import systemDateTime from '@ohos.systemDateTime';
import { COCO_CLASSES, DEFAULT_INFERENCE_OPTIONS, MODEL_ID, MODEL_SHA256 } from '../models/ModelConstants';
import {
  DetectionResult,
  InferenceAvailability,
  InferenceExecutionMode,
  InferenceOptions,
  RecognitionError,
  RecognitionErrorCode,
  RecognitionFailure,
  RecognitionStatus
} from '../models/DetectionTypes';
import { ImageSource } from '../models/ImageTypes';
import { GalleryImageService } from '../services/camera/GalleryImageService';
import { RecognitionService } from '../services/inference/RecognitionService';
import { RecognitionPreview } from '../components/recognition/RecognitionPreview';
import { StatusBanner } from '../components/recognition/StatusBanner';
import { ClassCountBar } from '../components/recognition/ClassCountBar';
import { DetectionList } from '../components/recognition/DetectionList';
import { TimingPanel } from '../components/recognition/TimingPanel';
import { CameraPreview, CameraCaptureResult, CameraErrorEvent } from '../components/camera/CameraPreview';
import { ImageAssetStore } from '../services/imaging/ImageAssetStore';
import { RecordService } from '../services/storage/RecordService';
import { SyncManager } from '../services/sync/SyncManager';
import { RecordSaveInput } from '../models/RecordTypes';
import { describeStorageError } from '../components/recognition/RecordFormat';
import { ModelUpdateBanner } from '../components/recognition/ModelUpdateBanner';
import {
  describeModelUpdateError,
  formatDownloadSize,
  formatUpdateReason,
  ModelUpdateInfo,
  ModelUpdatePort,
  ModelUpdateRegistry
} from '../components/recognition/ModelUpdate';
import {
  activeDetections,
  applyClassChange,
  buildEditableDetections,
  countByClass,
  countDeleted,
  countEdited,
  EditableDetection,
  setDeleted
} from '../components/recognition/EditableDetection';
import { createPreviewPixelMap } from '../components/recognition/PreviewPixelMap';
import { formatMs } from '../components/recognition/BoxGeometry';

const PAGE_BACKGROUND: string = '#F4F5F7';
const CARD_WHITE: string = '#FFFFFF';
const TEXT_PRIMARY: string = '#1F2430';
const TEXT_SECONDARY: string = '#6B7280';
const ACCENT: string = '#2E6BE6';
const PROBE_INTERVAL_MS: number = 100;
/** 内置示例图 rawfile 路径（tests/assets 同源，多物体桌面场景）。 */
const SAMPLE_IMAGE_RAWFILE: string = 'samples/04_multi_object_desk.jpg';

@Entry
@Component
struct Index {
  @State status: RecognitionStatus = RecognitionStatus.IDLE;
  @State availability: InferenceAvailability | undefined = undefined;
  @State hasImage: boolean = false;
  @State imageWidth: number = 0;
  @State imageHeight: number = 0;
  @State previewPixelMap: image.PixelMap | undefined = undefined;
  @State previewPreparing: boolean = false;
  @State previewError: string = '';
  @State items: EditableDetection[] = [];
  @State originalCount: number = 0;
  @State selectedId: number = -1;
  @State result: DetectionResult | undefined = undefined;
  @State errorMessage: string = '';
  @State errorDetail: string = '';
  @State errorCode: RecognitionErrorCode | undefined = undefined;
  @State confidenceThreshold: number = DEFAULT_INFERENCE_OPTIONS.confidenceThreshold;
  @State executionMode: InferenceExecutionMode = DEFAULT_INFERENCE_OPTIONS.executionMode;
  @State thresholdStale: boolean = false;
  @State imageBusy: boolean = false;
  @State probeRunning: boolean = false;
  @State uiTapLastMs: number = 0;
  @State uiTapMaxMs: number = 0;
  @State uiTapSamples: number = 0;
  @State uiTimerMaxMs: number = 0;
  @State uiTimerSamples: number = 0;
  @State cameraVisible: boolean = false;
  @State cameraErrorHint: string = '';
  @State saveBusy: boolean = false;
  @State savedRecordId: string = '';
  @State modelUpdatePhase: string = 'idle';
  @State modelUpdateVersion: string = '';
  @State modelUpdateReason: string = '';
  @State modelUpdateSize: string = '';
  @State modelUpdateProgress: number = 0;
  @State modelUpdateMessage: string = '';
  @State modelUpdateBusy: boolean = false;

  private recognition: RecognitionService = RecognitionService.getInstance();
  private gallery: GalleryImageService = GalleryImageService.getInstance();
  private currentImage: ImageSource | undefined = undefined;
  private currentRequestId: string = '';
  private currentImageId: string = '';
  private requestSeq: number = 0;
  private pageActive: boolean = true;
  private probeTimerId: number = -1;
  private probeLastTickMs: number = 0;
  private pendingThresholdRerun: boolean = false;
  private modelUpdatePort: ModelUpdatePort | undefined = undefined;
  private modelUpdateInfo: ModelUpdateInfo | undefined = undefined;

  aboutToAppear(): void {
    this.pageActive = true;
    const context: common.Context | undefined = this.getUIContext().getHostContext();
    if (context !== undefined) {
      this.recognition.setContext(context);
    }
    this.initializeRecognition();
    this.checkModelUpdate();
  }

  aboutToDisappear(): void {
    this.pageActive = false;
    this.invalidateOutstandingRequest();
    const pixelMap: image.PixelMap | undefined = this.previewPixelMap;
    this.previewPixelMap = undefined;
    if (pixelMap !== undefined) {
      pixelMap.release().catch(() => {
      });
    }
  }

  // ---------- 初始化 ----------

  private async initializeRecognition(isRetry: boolean = false): Promise<void> {
    if (this.status === RecognitionStatus.INITIALIZING) {
      return;
    }
    this.status = RecognitionStatus.INITIALIZING;
    try {
      const next: InferenceAvailability = await this.recognition.initialize();
      if (!this.pageActive) {
        return;
      }
      this.availability = next;
      if (next.available) {
        this.clearError();
        this.status = RecognitionStatus.READY;
      } else {
        const failure: RecognitionError | undefined = next.error;
        this.status = RecognitionStatus.UNAVAILABLE;
        this.errorCode = failure?.code;
        this.errorMessage = failure !== undefined ? failure.message : '识别不可用';
        this.errorDetail = failure !== undefined ? (failure.detail ?? '') : '';
        if (isRetry) {
          this.notify('重新加载后仍不可用，请检查模型文件或设备 ABI');
        }
      }
    } catch (err) {
      this.status = RecognitionStatus.UNAVAILABLE;
      this.errorCode = RecognitionErrorCode.INFERENCE_FAILED;
      this.errorMessage = '模型初始化异常';
      this.errorDetail = `${err}`;
    }
  }

  // ---------- 图片采集 ----------

  private async onPickImage(): Promise<void> {
    if (this.imageBusy) {
      return;
    }
    this.imageBusy = true;
    try {
      const next: ImageSource = await this.gallery.pickFromGallery();
      if (!this.pageActive) {
        return;
      }
      await this.adoptImage(next);
    } catch (err) {
      this.handleImageFailure(err, '相册选图');
    } finally {
      this.imageBusy = false;
    }
  }

  /** 内置示例图入口：无媒体库/无相机的环境（如模拟器）用固定样例跑通识别链路。 */
  private async onPickSample(): Promise<void> {
    if (this.imageBusy) {
      return;
    }
    this.imageBusy = true;
    try {
      const context: common.Context | undefined = this.getUIContext().getHostContext();
      if (context === undefined) {
        throw new RecognitionFailure(RecognitionErrorCode.IMAGE_INVALID, '页面上下文不可用，无法读取示例图', true,
          'host context undefined');
      }
      const next: ImageSource = await this.gallery.loadSampleImage(SAMPLE_IMAGE_RAWFILE, context);
      if (!this.pageActive) {
        return;
      }
      await this.adoptImage(next);
    } catch (err) {
      this.handleImageFailure(err, '示例图');
    } finally {
      this.imageBusy = false;
    }
  }

  /**
   * 拍照入口：打开全屏 CameraPreview 覆盖层。
   * 照片完成由 onCameraPhotoCaptured 回调处理；相机不可用则 Toast 并降级相册。
   */
  private async onCapturePhoto(): Promise<void> {
    if (this.imageBusy || this.cameraVisible) {
      return;
    }
    this.cameraErrorHint = '';
    this.cameraVisible = true;
  }

  /** CameraPreview 成功拍照回调。 */
  private async onCameraPhotoCaptured(result: CameraCaptureResult): Promise<void> {
    this.cameraVisible = false;
    // 拍成功即清掉上一次的错误提示，否则重试成功后会残留「拍照超时」文案。
    this.cameraErrorHint = '';
    if (!this.pageActive) {
      return;
    }
    this.imageBusy = true;
    try {
      await this.adoptImage(result.image);
    } catch (err) {
      this.handleImageFailure(err, '拍照');
    } finally {
      this.imageBusy = false;
    }
  }

  /** CameraPreview 错误回调；相机不可用时保持页面在识别状态，提示用户改用相册。 */
  private onCameraError(error: CameraErrorEvent): void {
    // permission/no-camera/open-failed → 留在当前页面并提示
    if (error.kind === 'permission' || error.kind === 'no-camera' ||
      error.kind === 'open-failed' || error.kind === 'session-failed') {
      this.cameraVisible = false;
      this.notify(error.message);
      return;
    }
    // capture/decode 级错误：相机组件内部已经提示，不关闭覆盖层让用户重试
    this.cameraErrorHint = error.message;
  }

  private closeCamera(): void {
    this.cameraVisible = false;
    this.cameraErrorHint = '';
  }

  private handleImageFailure(err: Object, action: string): void {
    const failure: RecognitionFailure = err as RecognitionFailure;
    if (failure !== undefined && failure.code === RecognitionErrorCode.CANCELLED) {
      this.notify('已取消，保留当前图片与结果');
      return;
    }
    if (failure !== undefined && failure.code === RecognitionErrorCode.IMAGE_INVALID) {
      this.status = RecognitionStatus.ERROR;
      this.errorCode = RecognitionErrorCode.IMAGE_INVALID;
      this.errorMessage = failure.message;
      this.errorDetail = failure.detail;
      return;
    }
    const message: string = failure !== undefined && failure.message !== undefined && failure.message.length > 0 ?
      failure.message : `${action}失败，请重试`;
    this.notify(message);
  }

  /** 采用新图片：先作废旧请求，再替换页面状态，避免旧结果覆盖新图片。 */
  private async adoptImage(next: ImageSource): Promise<void> {
    this.invalidateOutstandingRequest();
    this.currentImage = next;
    this.currentImageId = next.imageId;
    this.hasImage = true;
    this.imageWidth = next.width;
    this.imageHeight = next.height;
    this.items = [];
    this.originalCount = 0;
    this.selectedId = -1;
    this.result = undefined;
    this.thresholdStale = false;
    this.savedRecordId = '';
    this.clearError();
    if (this.availability?.available === true) {
      this.status = RecognitionStatus.READY;
    }

    this.previewError = '';
    this.previewPreparing = true;
    try {
      const nextPixelMap: image.PixelMap = await createPreviewPixelMap(next);
      if (!this.pageActive || this.currentImage === undefined || this.currentImage.imageId !== next.imageId) {
        nextPixelMap.release().catch(() => {
        });
        return;
      }
      const previous: image.PixelMap | undefined = this.previewPixelMap;
      this.previewPixelMap = nextPixelMap;
      if (previous !== undefined) {
        previous.release().catch(() => {
        });
      }
    } catch (err) {
      this.previewError = '图片预览生成失败，仍可继续识别';
    } finally {
      if (this.currentImage !== undefined && this.currentImage.imageId === next.imageId) {
        this.previewPreparing = false;
      }
    }
  }

  // ---------- 识别 ----------

  private async startRecognition(): Promise<void> {
    if (this.status === RecognitionStatus.RUNNING || !this.pageActive) {
      return;
    }
    const source: ImageSource | undefined = this.currentImage;
    if (source === undefined) {
      this.notify('请先拍照或选择图片');
      return;
    }
    if (this.availability?.available !== true) {
      this.notify('识别不可用，请先重新加载模型');
      return;
    }

    this.requestSeq += 1;
    const requestId: string = `req-${Date.now()}-${this.requestSeq}`;
    this.currentRequestId = requestId;
    this.currentImageId = source.imageId;
    this.status = RecognitionStatus.RUNNING;
    this.clearError();
    // 旧结果仍展示时保持“阈值已变化”提示，直到拿到与新阈值一致的结果。
    this.thresholdStale = this.result !== undefined &&
      Math.abs(this.result.confidenceThreshold - this.confidenceThreshold) > 0.0001;
    this.pendingThresholdRerun = false;
    // 重新识别必须清空旧编辑状态，避免把旧删除/修正套到新框上。
    this.resetEditsToOriginal();
    this.resetUiProbe();
    this.startUiProbe();

    // 让“识别中”状态先完成一次渲染；同步模式随后会阻塞 UI 线程。
    await this.waitForUiPaint();

    try {
      const next: DetectionResult = await this.recognition.recognize(source, this.buildOptions(), requestId);
      if (!this.isCurrentOutcome(requestId, source.imageId)) {
        return;
      }
      this.applyResult(next);
    } catch (err) {
      if (this.isCurrentOutcome(requestId, source.imageId)) {
        this.applyFailure(err as Object);
      }
    } finally {
      if (this.isCurrentOutcome(requestId, source.imageId)) {
        this.currentRequestId = '';
        this.stopUiProbe();
        if (this.status === RecognitionStatus.RUNNING) {
          this.status = this.baseStatus();
        }
        if (this.pendingThresholdRerun) {
          this.pendingThresholdRerun = false;
          this.startRecognition();
        }
      }
    }
  }

  private buildOptions(): InferenceOptions {
    return {
      confidenceThreshold: this.confidenceThreshold,
      iouThreshold: DEFAULT_INFERENCE_OPTIONS.iouThreshold,
      maxDetections: DEFAULT_INFERENCE_OPTIONS.maxDetections,
      executionMode: this.executionMode
    };
  }

  /**
   * 保存本次识别：先持久化原图与缩略图，再写 RDB；RDB 失败时回滚图片。
   * 保存的是模型原始框（result.boxes），与页面编辑副本分开。
   */
  private async handleSave(): Promise<void> {
    if (this.saveBusy) {
      return;
    }
    if (this.savedRecordId.length > 0) {
      this.notify('本次识别已保存，可在历史记录中查看');
      return;
    }
    const source: ImageSource | undefined = this.currentImage;
    const result: DetectionResult | undefined = this.result;
    if (source === undefined || result === undefined || this.status !== RecognitionStatus.SUCCEEDED) {
      return;
    }
    const context: common.Context | undefined = this.getUIContext().getHostContext();
    if (context === undefined) {
      this.notify('无法访问应用存储，保存失败');
      return;
    }
    this.saveBusy = true;
    const assetStore: ImageAssetStore = ImageAssetStore.getInstance();
    try {
      const assets = await assetStore.persistCapturedImage(context, source);
      const input: RecordSaveInput = {
        boxes: result.boxes,
        modelId: result.modelId,
        modelSha256: result.modelSha256,
        imageWidth: result.imageWidth,
        imageHeight: result.imageHeight,
        coldStart: result.timing.coldStart,
        totalMs: result.timing.totalMs,
        executionMode: result.executionMode
      };
      try {
        const recordId: string = await RecordService.getInstance().save(
          input, source.origin, assets.original.relativePath, assets.thumbnail.relativePath);
        if (!this.pageActive) {
          return;
        }
        this.savedRecordId = recordId;
        // 契约 §3.3：保存成功 → 入队并立即尝试上传（此前只入队不触发，需重启才上传）。
        SyncManager.getInstance().onRecordSaved(recordId);
        this.notify('已保存到历史记录');
      } catch (err) {
        // RecordService 内部已尝试回滚；这里按契约再清理一次（幂等）。
        await assetStore.deleteImages(context, assets.originalPath, assets.thumbnailPath);
        if (this.pageActive) {
          this.notify(describeStorageError(err as Object));
        }
      }
    } catch (err) {
      if (this.pageActive) {
        this.notify(describeStorageError(err as Object));
      }
    } finally {
      this.saveBusy = false;
    }
  }

  private openHistory(): void {
    this.getUIContext().getRouter().pushUrl({ url: 'pages/RecordList' }).catch(() => {
      this.notify('无法打开历史记录');
    });
  }

  // ---------- 模型更新 ----------

  /**
   * 查询模型是否有新版本。端口未注册（network 层未接入）或查询失败时静默跳过，
   * 不影响离线识别主流程。
   */
  private async checkModelUpdate(): Promise<void> {
    const port: ModelUpdatePort | undefined = ModelUpdateRegistry.resolve();
    if (port === undefined) {
      return;
    }
    this.modelUpdatePort = port;
    try {
      const info: ModelUpdateInfo | null = await port.check(MODEL_ID, MODEL_SHA256);
      if (!this.pageActive || info === null) {
        return;
      }
      this.modelUpdateInfo = info;
      this.modelUpdateVersion = info.version;
      this.modelUpdateReason = formatUpdateReason(info.reason);
      this.modelUpdateSize = formatDownloadSize(info.sizeBytes);
      this.modelUpdatePhase = 'available';
    } catch (err) {
      this.modelUpdatePhase = 'idle';
    }
  }

  /** 下载并替换模型；完成后重新初始化识别服务。 */
  private async startModelUpdate(): Promise<void> {
    const port: ModelUpdatePort | undefined = this.modelUpdatePort;
    const info: ModelUpdateInfo | undefined = this.modelUpdateInfo;
    if (port === undefined || info === undefined || this.modelUpdateBusy) {
      return;
    }
    this.modelUpdateBusy = true;
    this.modelUpdatePhase = 'downloading';
    this.modelUpdateProgress = 0;
    this.modelUpdateMessage = '';
    try {
      await port.download(info, (fraction: number) => {
        if (this.pageActive) {
          this.modelUpdateProgress = fraction;
        }
      });
      if (!this.pageActive) {
        return;
      }
      this.modelUpdatePhase = 'installed';
      this.modelUpdateMessage = `模型 ${info.version} 已更新，已重新加载`;
      this.notify('模型已更新');
      await this.initializeRecognition(true);
    } catch (err) {
      if (this.pageActive) {
        this.modelUpdatePhase = 'failed';
        this.modelUpdateMessage = describeModelUpdateError(err as Object);
        this.notify(this.modelUpdateMessage);
      }
    } finally {
      this.modelUpdateBusy = false;
    }
  }

  private applyResult(next: DetectionResult): void {
    this.result = next;
    this.savedRecordId = '';
    this.originalCount = next.boxes.length;
    this.items = buildEditableDetections(next.boxes);
    this.selectedId = -1;
    this.status = next.boxes.length === 0 ? RecognitionStatus.EMPTY : RecognitionStatus.SUCCEEDED;
    this.thresholdStale = Math.abs(next.confidenceThreshold - this.confidenceThreshold) > 0.0001;
    if (this.thresholdStale) {
      this.pendingThresholdRerun = true;
    }
  }

  private applyFailure(err: Object): void {
    const failure: RecognitionFailure = err as RecognitionFailure;
    if (failure !== undefined && failure.code === RecognitionErrorCode.CANCELLED) {
      this.status = this.baseStatus();
      return;
    }
    this.status = RecognitionStatus.ERROR;
    // 失败时仍展示的旧结果必须保留阈值不一致标记，避免误认为符合当前阈值。
    if (this.result !== undefined) {
      this.thresholdStale = Math.abs(this.result.confidenceThreshold - this.confidenceThreshold) > 0.0001;
    }
    if (failure !== undefined && failure.message !== undefined && failure.message.length > 0) {
      this.errorMessage = failure.message;
      this.errorCode = failure.code;
      this.errorDetail = failure.detail;
    } else {
      this.errorMessage = '识别失败，请重试';
      this.errorCode = RecognitionErrorCode.INFERENCE_FAILED;
      this.errorDetail = `${err}`;
    }
  }

  private isCurrentOutcome(requestId: string, imageId: string): boolean {
    return this.pageActive &&
      requestId === this.currentRequestId &&
      imageId === this.currentImageId &&
      this.currentImage !== undefined &&
      this.currentImage.imageId === imageId;
  }

  /** 作废未完成请求：取消排队任务并停止探针，切换图片或退出页面时调用。 */
  private invalidateOutstandingRequest(): void {
    if (this.currentRequestId.length > 0) {
      this.recognition.cancel(this.currentRequestId);
      this.currentRequestId = '';
    }
    this.pendingThresholdRerun = false;
    this.stopUiProbe();
  }

  private baseStatus(): RecognitionStatus {
    return this.availability?.available === true ? RecognitionStatus.READY : RecognitionStatus.UNAVAILABLE;
  }

  private async waitForUiPaint(): Promise<void> {
    await new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, 32);
    });
  }

  // ---------- 阈值、模式与编辑 ----------

  private handleThresholdChange(value: number, mode: SliderChangeMode): void {
    const previous: number = this.confidenceThreshold;
    const next: number = Math.min(0.95, Math.max(0.05, Math.round(value * 100) / 100));
    if (next !== previous) {
      this.confidenceThreshold = next;
      // 阈值变化后旧结果与编辑状态不再对应当前配置。
      this.resetEditsToOriginal();
    }
    if (this.result === undefined) {
      return;
    }
    const stale: boolean = Math.abs(this.result.confidenceThreshold - next) > 0.0001;
    this.thresholdStale = stale;
    if (!stale) {
      return;
    }
    if (this.status === RecognitionStatus.RUNNING) {
      this.pendingThresholdRerun = true;
      return;
    }
    if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
      if (this.hasImage && this.availability?.available === true && this.status !== RecognitionStatus.INITIALIZING) {
        // 契约要求阈值变化后重新识别，不在本地过滤旧结果。
        this.startRecognition();
      }
    }
  }

  private handleModeChange(mode: InferenceExecutionMode): void {
    if (this.executionMode === mode) {
      return;
    }
    this.executionMode = mode;
    // 数据契约：执行模式变化后清空旧编辑状态，等待下一次识别产生新结果。
    this.resetEditsToOriginal();
    if (this.status === RecognitionStatus.RUNNING) {
      this.notify('执行模式将在本次识别结束后生效');
    }
  }

  private handleEditClass(rawIndex: number): void {
    const item: EditableDetection | undefined =
      this.items.find((entry: EditableDetection): boolean => entry.rawIndex === rawIndex);
    if (item === undefined) {
      return;
    }
    this.getUIContext().showTextPickerDialog({
      range: COCO_CLASSES,
      selected: item.classId,
      onAccept: (value: TextPickerResult) => {
        let index: number = item.classId;
        if (typeof value.index === 'number') {
          index = value.index;
        } else if (value.index.length > 0) {
          index = value.index[0];
        }
        this.items = applyClassChange(this.items, rawIndex, index);
      }
    });
  }

  private handleDelete(rawIndex: number): void {
    // 保留墓碑而不是物理删除，保证原始模型结果可追溯。
    this.items = setDeleted(this.items, rawIndex, true);
    if (this.selectedId === rawIndex) {
      this.selectedId = -1;
    }
  }

  private handleRestore(): void {
    if (this.result === undefined) {
      return;
    }
    this.items = buildEditableDetections(this.result.boxes);
    this.selectedId = -1;
  }

  /** 丢弃用户编辑，回到最近一次原始模型结果（不含墓碑）。 */
  private resetEditsToOriginal(): void {
    if (this.result !== undefined) {
      this.items = buildEditableDetections(this.result.boxes);
    } else {
      this.items = [];
    }
    this.selectedId = -1;
  }

  // ---------- UI 响应探针 ----------

  private resetUiProbe(): void {
    this.uiTapLastMs = 0;
    this.uiTapMaxMs = 0;
    this.uiTapSamples = 0;
    this.uiTimerMaxMs = 0;
    this.uiTimerSamples = 0;
  }

  private startUiProbe(): void {
    this.stopUiProbe();
    this.probeRunning = true;
    this.probeLastTickMs = Date.now();
    this.probeTimerId = setInterval(() => {
      const now: number = Date.now();
      const delay: number = now - this.probeLastTickMs - PROBE_INTERVAL_MS;
      this.probeLastTickMs = now;
      if (delay > 0) {
        this.uiTimerMaxMs = Math.max(this.uiTimerMaxMs, delay);
      }
      this.uiTimerSamples += 1;
    }, PROBE_INTERVAL_MS);
  }

  private stopUiProbe(): void {
    if (this.probeTimerId !== -1) {
      clearInterval(this.probeTimerId);
      this.probeTimerId = -1;
    }
    this.probeRunning = false;
  }

  /**
   * 记录点击事件从产生到主线程处理的排队时间，与推理耗时分开统计。
   * event.timestamp 为纳秒（自系统启动），异常值直接跳过，避免污染指标。
   */
  private recordTapProbe(event: ClickEvent): void {
    const nowUptimeMs: number = systemDateTime.getUptime(systemDateTime.TimeType.STARTUP);
    const eventUptimeMs: number = event.timestamp / 1000000;
    if (!Number.isFinite(nowUptimeMs) || !Number.isFinite(eventUptimeMs) || eventUptimeMs <= 0 ||
      eventUptimeMs > nowUptimeMs) {
      return;
    }
    const delay: number = Math.max(0, nowUptimeMs - eventUptimeMs);
    this.uiTapLastMs = delay;
    this.uiTapMaxMs = Math.max(this.uiTapMaxMs, delay);
    this.uiTapSamples += 1;
  }

  // ---------- 展示辅助 ----------

  private clearError(): void {
    this.errorMessage = '';
    this.errorDetail = '';
    this.errorCode = undefined;
  }

  private notify(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
    } catch (err) {
      // Toast 失败不影响主流程。
    }
  }

  private modelStatusText(): string {
    if (this.status === RecognitionStatus.INITIALIZING || this.status === RecognitionStatus.IDLE) {
      return '模型检查中';
    }
    return this.availability?.available === true ? '模型就绪' : '识别不可用';
  }

  private modelStatusColor(): string {
    if (this.status === RecognitionStatus.INITIALIZING || this.status === RecognitionStatus.IDLE) {
      return '#2E6BE6';
    }
    return this.availability?.available === true ? '#1D9E6C' : '#C53B32';
  }

  private visibleCount(): number {
    return this.items.length - countDeleted(this.items);
  }

  private headline(): string {
    if (this.status === RecognitionStatus.INITIALIZING) {
      return '正在初始化模型与运行库';
    }
    if (this.status === RecognitionStatus.UNAVAILABLE) {
      const code: RecognitionErrorCode | undefined = this.errorCode;
      if (code === RecognitionErrorCode.MODEL_MISSING) {
        return '识别不可用：模型文件缺失';
      }
      if (code === RecognitionErrorCode.MODEL_INVALID) {
        return '识别不可用：模型无效';
      }
      if (code === RecognitionErrorCode.UNSUPPORTED_ABI) {
        return '识别不可用：设备不支持端侧推理';
      }
      return '识别不可用';
    }
    if (this.status === RecognitionStatus.RUNNING) {
      return this.executionMode === InferenceExecutionMode.SYNC ? '识别中（同步模式会阻塞界面）' :
        '识别中（TaskPool 后台执行）';
    }
    if (this.status === RecognitionStatus.SUCCEEDED) {
      return `识别完成：${this.visibleCount()} 项`;
    }
    if (this.status === RecognitionStatus.EMPTY) {
      return '识别完成：未检测到物品';
    }
    if (this.status === RecognitionStatus.ERROR) {
      return this.errorMessage.length > 0 ? this.errorMessage : '识别失败';
    }
    if (this.status === RecognitionStatus.READY) {
      return this.hasImage ? '已选择图片，可开始识别' : '模型就绪，等待选择图片';
    }
    return '准备就绪';
  }

  private description(): string {
    if (this.status === RecognitionStatus.INITIALIZING) {
      return '正在检查 rawfile 模型、SHA-256 与原生库可用性。';
    }
    if (this.status === RecognitionStatus.UNAVAILABLE) {
      return this.recoveryHint();
    }
    if (this.status === RecognitionStatus.RUNNING) {
      return this.executionMode === InferenceExecutionMode.SYNC ?
        '同步推理与界面同线程，期间点击会排队；可点击“响应探针”记录排队时间。' :
        '推理在 TaskPool 工作线程执行，界面保持可交互；可点击“响应探针”采样。';
    }
    if (this.status === RecognitionStatus.EMPTY) {
      return '空结果不是错误。可降低置信度阈值后重新识别，或换一张图片。';
    }
    if (this.status === RecognitionStatus.ERROR) {
      return this.recoveryHint();
    }
    if (this.status === RecognitionStatus.READY) {
      return this.hasImage ? `阈值 ${this.confidenceThreshold.toFixed(2)} · ` +
        `模式 ${this.executionMode === InferenceExecutionMode.SYNC ? '同步' : 'TaskPool'}` :
        '拍照或从相册选择图片，然后点击“开始识别”。识别完全在端侧离线完成。';
    }
    return '';
  }

  private recoveryHint(): string {
    const code: RecognitionErrorCode | undefined = this.errorCode;
    if (code === RecognitionErrorCode.MODEL_MISSING) {
      return '请将 yolov13n.onnx 放入 resources/rawfile/models 后点击“重新加载模型”；' +
        '若本次会话已缓存失败结果，请重启应用后再试。';
    }
    if (code === RecognitionErrorCode.MODEL_INVALID) {
      return '模型 hash 或输入输出形状校验失败，请更换官方导出的模型后点击“重新加载模型”；' +
        '若本次会话已缓存失败结果，请重启应用后再试。';
    }
    if (code === RecognitionErrorCode.UNSUPPORTED_ABI) {
      return '当前设备 ABI 不是 arm64-v8a，端侧推理不可用；请更换设备或等待提供对应 ABI 的库。';
    }
    if (code === RecognitionErrorCode.IMAGE_INVALID) {
      return '图片损坏、格式不支持或尺寸过大，请重新拍照或选择其他图片。';
    }
    if (code === RecognitionErrorCode.INFERENCE_FAILED) {
      return '可重试识别；若持续失败，请检查模型文件与设备日志。';
    }
    return '请按提示恢复后重试。';
  }

  private errorDetailText(): string {
    if (this.status === RecognitionStatus.UNAVAILABLE || this.status === RecognitionStatus.ERROR) {
      return this.errorDetail;
    }
    return '';
  }

  private canRecognize(): boolean {
    return this.hasImage && this.availability?.available === true &&
      this.status !== RecognitionStatus.RUNNING && this.status !== RecognitionStatus.INITIALIZING;
  }

  private probeHint(): string {
    return this.probeRunning ? '识别中可点击，记录主线程排队' : '点击采样主线程响应';
  }

  @Builder
  modeButton(label: string, mode: InferenceExecutionMode) {
    Button(label)
      .fontSize(12)
      .height(30)
      .layoutWeight(1)
      .backgroundColor(this.executionMode === mode ? ACCENT : '#F0F2F5')
      .fontColor(this.executionMode === mode ? '#FFFFFF' : '#4A4F58')
      .borderRadius(8)
      .onClick(() => this.handleModeChange(mode))
  }

  @Builder
  sectionTitle(title: string, hint: string) {
    Row({ space: 8 }) {
      Text(title)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(TEXT_PRIMARY)
      Text(hint)
        .fontSize(11)
        .fontColor(TEXT_SECONDARY)
        .layoutWeight(1)
        .textAlign(TextAlign.End)
    }
    .width('100%')
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Scroll() {
      Column({ space: 12 }) {
        // 标题与模型状态
        Row({ space: 10 }) {
          Column({ space: 2 }) {
            Text('智能物品识别助手')
              .fontSize(22)
              .fontWeight(FontWeight.Bold)
              .fontColor(TEXT_PRIMARY)
            Text('端侧 YOLOv13n · COCO 80 类 · 离线识别')
              .fontSize(11)
              .fontColor(TEXT_SECONDARY)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Text(this.modelStatusText())
            .fontSize(11)
            .fontColor(this.modelStatusColor())
            .backgroundColor(CARD_WHITE)
            .borderRadius(10)
            .padding({ left: 8, right: 8, top: 5, bottom: 5 })
        }
        .width('100%')
        .padding({ top: 4 })

        // 采集入口
        Row({ space: 10 }) {
          Button(this.imageBusy ? '处理中…' : '拍照')
            .fontSize(14)
            .height(42)
            .layoutWeight(1)
            .backgroundColor(ACCENT)
            .fontColor('#FFFFFF')
            .enabled(!this.imageBusy)
            .onClick(() => {
              this.onCapturePhoto();
            })
          Button(this.imageBusy ? '处理中…' : '相册选图')
            .fontSize(14)
            .height(42)
            .layoutWeight(1)
            .backgroundColor('#FFFFFF')
            .fontColor(ACCENT)
            .border({ width: 1, color: '#C7D7FA' })
            .enabled(!this.imageBusy)
            .onClick(() => {
              this.onPickImage();
            })
        }
        .width('100%')

        Button(this.imageBusy ? '处理中…' : '示例图片（内置样例，模拟器可用）')
          .fontSize(12)
          .height(32)
          .width('100%')
          .backgroundColor('#FFFFFF')
          .fontColor('#5B6472')
          .border({ width: 1, color: '#E0E4EA' })
          .enabled(!this.imageBusy)
          .onClick(() => {
            this.onPickSample();
          })

        Button('历史记录 · 本地保存')
          .fontSize(12)
          .height(36)
          .width('100%')
          .backgroundColor(CARD_WHITE)
          .fontColor(ACCENT)
          .border({ width: 1, color: '#C7D7FA' })
          .borderRadius(9)
          .onClick(() => {
            this.openHistory();
          })

        // 模型更新：有可用版本或下载中时展示；未接入时不占位
        ModelUpdateBanner({
          phase: this.modelUpdatePhase,
          version: this.modelUpdateVersion,
          reasonText: this.modelUpdateReason,
          sizeText: this.modelUpdateSize,
          progress: this.modelUpdateProgress,
          message: this.modelUpdateMessage,
          onInstall: () => {
            this.startModelUpdate();
          }
        })

        // 图片预览与检测框
        RecognitionPreview({
          pixelMap: $previewPixelMap,
          imageWidth: this.imageWidth,
          imageHeight: this.imageHeight,
          items: activeDetections(this.items),
          selectedId: this.selectedId,
          preparing: this.previewPreparing,
          previewError: this.previewError,
          onSelect: (rawIndex: number) => {
            this.selectedId = rawIndex;
          }
        })

        // 状态与恢复操作
        StatusBanner({
          status: this.status,
          headline: this.headline(),
          description: this.description(),
          detail: this.errorDetailText(),
          showInitializeAction: this.status === RecognitionStatus.UNAVAILABLE ||
            (this.status === RecognitionStatus.ERROR && this.errorCode !== undefined &&
              this.errorCode !== RecognitionErrorCode.IMAGE_INVALID &&
              this.errorCode !== RecognitionErrorCode.INFERENCE_FAILED),
          showPickAction: this.status === RecognitionStatus.ERROR &&
            this.errorCode === RecognitionErrorCode.IMAGE_INVALID,
          showRetryAction: this.status === RecognitionStatus.ERROR && this.hasImage &&
            this.availability?.available === true &&
            this.errorCode !== RecognitionErrorCode.IMAGE_INVALID,
          actionBusy: this.status === RecognitionStatus.INITIALIZING,
          onInitialize: () => {
            this.initializeRecognition(true);
          },
          onPickImage: () => {
            this.onPickImage();
          },
          onRetryRecognize: () => {
            this.startRecognition();
          }
        })

        // 保存入口：保存原图与模型原始框，编辑副本不写入
        if (this.status === RecognitionStatus.SUCCEEDED && this.result !== undefined) {
          Column({ space: 6 }) {
            Button(this.savedRecordId.length > 0 ? '已保存到历史记录' :
              (this.saveBusy ? '保存中…' : '保存识别结果'))
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .height(42)
              .width('100%')
              .backgroundColor(this.savedRecordId.length > 0 ? '#1D9E6C' : ACCENT)
              .fontColor('#FFFFFF')
              .enabled(!this.saveBusy && this.savedRecordId.length === 0)
              .onClick(() => {
                this.handleSave();
              })
            Text(this.savedRecordId.length > 0 ?
              '可在“历史记录”中查看或继续编辑检测框。' :
              '保存原图、模型原始框与当前统计；页面上的改类/删除仅在本次会话生效。')
              .fontSize(10)
              .fontColor('#8A9099')
              .width('100%')
              .lineHeight(14)
          }
          .width('100%')
        }

        // 识别控制
        Column({ space: 12 }) {
          this.sectionTitle('执行模式', this.executionMode === InferenceExecutionMode.SYNC ?
            '同步：占用 UI 线程' : 'TaskPool：工作线程执行')
          Row({ space: 8 }) {
            this.modeButton('同步', InferenceExecutionMode.SYNC)
            this.modeButton('TaskPool', InferenceExecutionMode.TASK_POOL)
          }
          .width('100%')

          Column({ space: 6 }) {
            Row() {
              Text('置信度阈值')
                .fontSize(13)
                .fontColor(TEXT_PRIMARY)
              Text(this.confidenceThreshold.toFixed(2))
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor(ACCENT)
                .layoutWeight(1)
                .textAlign(TextAlign.End)
            }
            .width('100%')

            Slider({
              value: this.confidenceThreshold,
              min: 0.05,
              max: 0.95,
              step: 0.05,
              style: SliderStyle.OutSet
            })
              .width('100%')
              .selectedColor(ACCENT)
              .onChange((value: number, mode: SliderChangeMode) => {
                this.handleThresholdChange(value, mode);
              })

            Text(this.thresholdStale ?
              `当前显示结果基于 ${this.result !== undefined ? this.result.confidenceThreshold.toFixed(2) : '--'}` +
              `，松开滑块后按 ${this.confidenceThreshold.toFixed(2)} 重新识别` :
              '阈值变化后重新执行识别，不在本地过滤旧结果')
              .fontSize(10)
              .fontColor(this.thresholdStale ? '#B45309' : '#8A9099')
              .width('100%')
          }

          Row({ space: 10 }) {
            Button(this.status === RecognitionStatus.RUNNING ? '识别中…' : '开始识别')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .height(44)
              .layoutWeight(1)
              .backgroundColor(this.canRecognize() ? ACCENT : '#C9D3E4')
              .fontColor('#FFFFFF')
              .enabled(this.canRecognize())
              .onClick(() => {
                this.startRecognition();
              })

            Button('响应探针')
              .fontSize(12)
              .height(44)
              .width(104)
              .backgroundColor(this.probeRunning ? '#1D9E6C' : '#FFFFFF')
              .fontColor(this.probeRunning ? '#FFFFFF' : ACCENT)
              .border({ width: 1, color: this.probeRunning ? '#1D9E6C' : '#C7D7FA' })
              .onClick((event: ClickEvent) => {
                this.recordTapProbe(event);
              })
          }
          .width('100%')

          Text(this.probeHint())
            .fontSize(10)
            .fontColor('#8A9099')
            .width('100%')
        }
        .width('100%')
        .padding(12)
        .borderRadius(12)
        .backgroundColor(CARD_WHITE)
        .alignItems(HorizontalAlign.Start)

        // 统计与结果
        if (this.result !== undefined) {
          ClassCountBar({
            counts: countByClass(this.items),
            total: this.visibleCount()
          })

          TimingPanel({
            result: this.result,
            selectedMode: this.executionMode,
            uiTapLastMs: this.uiTapLastMs,
            uiTapMaxMs: this.uiTapMaxMs,
            uiTapSamples: this.uiTapSamples,
            uiTimerMaxMs: this.uiTimerMaxMs,
            uiTimerSamples: this.uiTimerSamples,
            probeRunning: this.probeRunning
          })

          DetectionList({
            items: activeDetections(this.items),
            selectedId: this.selectedId,
            originalCount: this.originalCount,
            editedCount: countEdited(this.items),
            deletedCount: countDeleted(this.items),
            onSelect: (rawIndex: number) => {
              this.selectedId = rawIndex;
            },
            onEditClass: (rawIndex: number) => {
              this.handleEditClass(rawIndex);
            },
            onDelete: (rawIndex: number) => {
              this.handleDelete(rawIndex);
            },
            onRestore: () => {
              this.handleRestore();
            }
          })

        } else if (this.hasImage) {
          Column({ space: 6 }) {
            Text('尚未识别')
              .fontSize(13)
              .fontColor(TEXT_PRIMARY)
            Text('点击“开始识别”运行端侧模型。检测框会叠加在图片上，并按类别统计数量。')
              .fontSize(11)
              .fontColor(TEXT_SECONDARY)
              .lineHeight(16)
          }
          .width('100%')
          .padding(12)
          .borderRadius(12)
          .backgroundColor(CARD_WHITE)
          .alignItems(HorizontalAlign.Start)
        }

        Text('原始模型结果与编辑结果分开保存：编辑只修改页面副本，可随时恢复。\n' +
          `最近总耗时：${this.result !== undefined ? formatMs(this.result.timing.totalMs) : '--'}（与界面响应指标独立）`)
          .fontSize(10)
          .fontColor('#9AA1AC')
          .width('100%')
          .lineHeight(15)
          .padding({ top: 2, bottom: 12 })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(PAGE_BACKGROUND)
    .scrollBar(BarState.Off)

      // 全屏相机覆盖层：XComponent 常驻但被覆盖层隐藏（HitTestMode.Block），
      // CameraPreview 组件的 aboutToAppear/aboutToDisappear 处理资源生命周期。
      if (this.cameraVisible) {
        Stack({ alignContent: Alignment.Bottom }) {
          CameraPreview({
            onPhotoCaptured: (result: CameraCaptureResult) => {
              this.onCameraPhotoCaptured(result);
            },
            onCameraError: (error: CameraErrorEvent) => {
              this.onCameraError(error);
            }
          })
            .width('100%')
            .height('100%')

          // 返回按钮：覆盖层不销毁时也能关闭。
          Button('返回')
            .fontSize(14)
            .width(72)
            .height(44)
            .backgroundColor('#AA000000')
            .fontColor('#FFFFFF')
            .position({ x: '5%', y: 16 })
            .onClick(() => {
              this.closeCamera();
            })

          if (this.cameraErrorHint.length > 0) {
            Text(this.cameraErrorHint)
              .fontSize(13)
              .fontColor('#FFFFFF')
              .backgroundColor('#AA000000')
              .padding(8)
              .borderRadius(8)
              // 左对齐并限宽：原先 x:'50%' 会让长提示超出右边界被裁掉。
              .width('90%')
              .textAlign(TextAlign.Start)
              .position({ x: '5%', y: 64 })
          }
        }
        .width('100%')
        .height('100%')
      }
    }
  }
}
