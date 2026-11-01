# 第一阶段图像识别共享契约

> Agent 0 制定并冻结。Agent 1/2/3 按此实现；需要改动共享类型或语义时，先写入交接报告由负责人协调。
> 配套文档：[`docs/phase-1-model.md`](phase-1-model.md)。共享类型位于 `app/entry/src/main/ets/models/`。

## 1. 范围

本契约覆盖：

- 采集层（Agent 1）向推理层（Agent 2）交付的图像数据结构；
- 推理层向界面层（Agent 3）交付的检测结果、耗时和错误；
- 方向、镜像、坐标空间、资源所有权；
- TaskPool 跨线程传递边界；
- 模型缺失、ABI 不支持、阈值变化、空结果的一致行为。

不覆盖：RDB、JWT、云端同步、模型热更新、相机 UI 细节、识别页面布局。

## 2. 图像与坐标模型

### 2.1 ImageSource

定义文件：`app/entry/src/main/ets/models/ImageTypes.ets`。

| 字段 | 类型 | 约束 |
| --- | --- | --- |
| `imageId` | `string` | 每次采集唯一；由 Agent 1 生成 |
| `origin` | `ImageOrigin` | `camera` / `gallery` |
| `width` / `height` | `number` | 方向归一化后的像素宽高，正整数 |
| `pixelFormat` | `PixelFormat` | 本阶段用 `RGB_888`（推荐）或 `RGBA_8888` |
| `rowStride` | `number` | 每行字节数；RGB ≥ width×3，RGBA ≥ width×4 |
| `data` | `ArrayBuffer` | 长度必须等于 `rowStride × height` |
| `isMirrored` | `boolean` | 像素是否已水平镜像；相机静态拍照必须为 `false` |
| `exifOrientation` | `number` | 原始 EXIF 1-8；未知为 0，仅诊断用 |
| `capturedAtMs` | `number` | Unix 毫秒 |

不变式：

1. **像素格式**：RGB 顺序为 R、G、B；RGBA 顺序为 R、G、B、A。本阶段不使用 BGR、NV21、YUV。
2. **行布局**：行优先；行与行之间只允许 `rowStride` 声明的填充；`data` 之外不得再有像素。
3. **方向归一化**：Agent 1 在返回前已按 EXIF Orientation 旋转/翻转，使 `(0,0)` 是正常观看方向的左上角。Agent 2/3 不得再次旋转。
4. **镜像**：相机预览可以镜像；**送入识别的静态图不镜像**。若某实现确实镜像了像素，必须令 `isMirrored=true`，且后续坐标以此像素空间为准。
5. **分辨率**：`width/height` 就是坐标参考空间。Agent 1 不得在未声明的情况下静默缩放；超大图无法分配时以 `IMAGE_INVALID` 拒绝并提示换图。

### 2.2 方向与镜像由谁处理

| 环节 | 负责内容 |
| --- | --- |
| Agent 1 | 解码、EXIF 方向归一化、PixelMap → RGB/RGBA `ArrayBuffer`、生成 `imageId`、释放原生对象 |
| Agent 1 相机预览组件 | 仅预览层的前置镜像；不影响拍照输出 |
| Agent 2 | 仅做 letterbox 缩放与推理；不旋转、不镜像原图 |
| Agent 3 | 将检测框从 `ImageSource` 像素空间映射到图片显示区域；不旋转、不镜像静态图 |

**结论：前置镜像只存在于相机预览层；静态图、检测框、界面显示共用同一未镜像的像素空间。** 若未来产品要求镜像自拍，必须同时镜像像素并设置 `isMirrored=true`，由 Agent 1 统一完成，其他层不得各转一次。

### 2.3 显示坐标转换（Agent 3）

图片在容器内以 `contain` 方式显示时：

```text
contentScale = min(displayWidth / imageWidth, displayHeight / imageHeight)
offsetX = (displayWidth - imageWidth * contentScale) / 2
offsetY = (displayHeight - imageHeight * contentScale) / 2
screenX = offsetX + pixelX * contentScale
screenY = offsetY + pixelY * contentScale
```

- 必须使用 `ImageSource.width/height`，不能使用 `PixelMap` 原始尺寸或控件尺寸。
- 必须扣除 `contain` 留白，否则长图会出现系统性偏移。
- 不得对静态图额外旋转 90° 或水平翻转。

### 2.4 DetectionBox

定义文件：`models/DetectionTypes.ets`。

| 字段 | 含义 |
| --- | --- |
| `classId` | 0-79，对应 `COCO_CLASSES` 下标 |
| `label` | 类别名，由 `classLabel(classId)` 生成 |
| `confidence` | 0..1；80 个类别分数的最大值，不含 objectness |
| `left/top/right/bottom` | 原图像素坐标，浮点，原点左上角 |

约束：

- 坐标单位是**原图像素**，不是归一化 0..1，也不是屏幕像素。
- 必须裁剪到 `[0, imageWidth] × [0, imageHeight]`。
- 必须满足 `right > left`、`bottom > top`；退化框丢弃。
- 结果按置信度降序；同类框已做 NMS。

## 3. 共享类型清单

| 类型 | 文件 | 用途 |
| --- | --- | --- |
| `PixelFormat`、`ImageOrigin`、`ImageSource` | `models/ImageTypes.ets` | 采集输出 |
| `InferenceExecutionMode` | `models/DetectionTypes.ets` | 同步/TaskPool |
| `RecognitionStatus` | `models/DetectionTypes.ets` | 页面状态 |
| `RecognitionErrorCode`、`RecognitionError`、`RecognitionFailure` | `models/DetectionTypes.ets` | 错误 |
| `DetectionBox`、`DetectionResult`、`InferenceTiming`、`InferenceOptions` | `models/DetectionTypes.ets` | 推理输出/输入 |
| `ModelInfo`、`InferenceAvailability`、`RecognitionOutcome`、`RecognitionState` | `models/DetectionTypes.ets` | 初始化、跨线程返回、页面快照 |
| `ModelConstants`、`COCO_CLASSES`、`DEFAULT_INFERENCE_OPTIONS` | `models/ModelConstants.ets` | 固定模型与默认阈值 |
| `ImageCaptureApi`、`RecognitionServiceApi` | `models/RecognitionApi.ets` | 服务接口 |

`DetectionResult` 关键字段语义：

- `requestId`：调用方生成，服务原样返回；用于丢弃旧结果。
- `imageId`：与输入 `ImageSource.imageId` 完全一致。
- `imageWidth/imageHeight`：坐标空间尺寸，等于输入 `ImageSource` 的宽高。
- `confidenceThreshold/iouThreshold`：本次实际使用的值；界面展示结果时必须显示。
- `modelId/modelSha256`：来自 `MODEL_INFO`，日志核对用。
- `timing.totalMs`：冷启动时包含 `modelLoadMs`，热启动时为三段之和（含少量调度开销）。

`InferenceTiming`：

| 字段 | 含义 |
| --- | --- |
| `preprocessMs` | 颜色转换、letterbox、归一化、NCHW 拷贝 |
| `inferenceMs` | `OnnxSession.Run` 前后的墙钟时间 |
| `postprocessMs` | 解码、阈值、NMS、逆变换、裁剪 |
| `coldStart` | 本次是否新建 session |
| `modelLoadMs` | 新建 session 的耗时；复用为 0 |
| `totalMs` | 端到端耗时 |

## 4. 公共 API

实现类名与方法必须与本节一致。返回 `Promise` 的方法失败时，以 `RecognitionFailure` 拒绝（`Error` 子类，带 `code/message/recoverable/detail`）。

### 4.1 Agent 1：采集

导出类：

```ts
class GalleryImageService implements ImageCaptureApi {
  static getInstance(): GalleryImageService;
  pickFromGallery(): Promise<ImageSource>;   // 取消 -> CANCELLED
  capturePhoto(): Promise<ImageSource>;      // 未就绪 -> 普通 Error
}
```

相机预览组件（`ets/components/camera/`）通过回调交付：

```ts
interface CameraCaptureResult {
  image: ImageSource;
}
// 组件事件：onPhotoCaptured(result: CameraCaptureResult)
```

要求：

- 成功返回前已释放 `image.PixelMap`、`image.ImageSource` 等原生对象；返回的只有 `ArrayBuffer` 和标量。
- 取消选图：`RecognitionFailure(RecognitionErrorCode.CANCELLED, '已取消选图', true)`，不得破坏页面已有图片/结果。
- 解码失败、格式不支持、超大图：`IMAGE_INVALID`，`recoverable=true`。
- 权限拒绝由页面处理，不通过 `ImageSource` 表达。

### 4.2 Agent 2：推理

导出类：

```ts
class RecognitionService implements RecognitionServiceApi {
  static getInstance(): RecognitionService;
  initialize(): Promise<InferenceAvailability>;  // 幂等，不抛模型/ABI 错误
  getAvailability(): InferenceAvailability;
  recognize(image: ImageSource, options: InferenceOptions, requestId: string): Promise<DetectionResult>;
  cancel(requestId: string): void;
  dispose(): Promise<void>;
}
```

初始化规则：

1. 读取 rawfile `models/yolov13n.onnx`，校验 SHA-256 与输入输出形状。
2. 将模型复制到应用沙箱（如 `context.filesDir/models/yolov13n.onnx`），后续用文件路径创建 session，避免每次传 9.7 MB 缓冲区。
3. 延迟加载 `@ohos/onnxruntime`（如 `await import('@ohos/onnxruntime')`）并捕获加载失败；不要让原生库加载失败在页面 import 阶段崩溃。
4. `available=false` 时返回 `MODEL_MISSING` / `MODEL_INVALID` / `UNSUPPORTED_ABI`，`recoverable` 分别为 `true/false/false`。
5. 校验 `deviceInfo.abi` 并写入日志；非 `arm64` 直接返回 `UNSUPPORTED_ABI`。

识别规则：

- `options` 非法（阈值不在 `(0,1]`、`maxDetections` 不在 `1..300`）时以 `INFERENCE_FAILED` 拒绝，不启动任务。
- 同一实例最多一个推理执行；新请求替换尚未开始的旧请求（latest wins），被替换的请求以 `CANCELLED` 拒绝。
- 正在执行的请求不强制中断；其 `DetectionResult.requestId` 供页面比对后丢弃。
- 失败后服务保持可用，下一次 `recognize` 可重试。
- `dispose()` 关闭 session、释放 tensor/result，之后实例不可复用。

### 4.3 Agent 3：页面

页面只依赖：

```ts
import { RecognitionService } from '../services/inference/RecognitionService';
import { GalleryImageService } from '../services/camera/GalleryImageService';
import { DEFAULT_INFERENCE_OPTIONS, COCO_CLASSES, classLabel } from '../models/ModelConstants';
```

页面职责：

- 维护当前 `ImageSource`、当前 `requestId`、`RecognitionState`。
- 发起识别前生成新 `requestId`；回调时同时校验 `requestId` 与 `imageId`。
- 根据 `InferenceAvailability.available` 显示/禁用识别入口。
- 将 `DetectionBox` 映射到显示区域（第 2.3 节）。
- 阈值变化时重新识别，不本地过滤旧结果。
- 展示 `DetectionResult.confidenceThreshold`、三阶段耗时、总耗时、执行模式。
- 编辑（改类别、删除）只修改页面副本；`DetectionResult.boxes` 视为原始模型结果，不原地改写。

## 5. 线程、TaskPool 与资源所有权

### 5.1 线程模型

| 模式 | session 所在线程 | 生命周期 |
| --- | --- | --- |
| `SYNC` | 调用 `recognize` 的线程（UI 线程） | `initialize` 创建，复用至 `dispose`；所有 `Run` 必须在同一线程 |
| `TASK_POOL` | TaskPool 工作线程 | 在每个并发任务内创建、使用、`Close`；不跨线程缓存 |

理由：`OnnxSession`/`OnnxTensor`/`OnnxResult` 是 NAPI 原生对象，不可序列化；TaskPool 不保证同一任务落在同一线程。若 Agent 2 后续验证了常驻 `ThreadWorker` 方案，可内部替换，但公共 API 与结果语义不变，并在报告中说明。

同步模式下 UI 会阻塞，页面必须显示“识别中”并禁止重复点击；这正是同步/异步对比的一部分。

### 5.2 跨 TaskPool 传递的数据

允许：

- `ArrayBuffer`（像素，复制传递）
- `string`、`number`、`boolean`
- 仅含上述字段的普通对象/数组（`InferenceOptions`、`DetectionResult`、`RecognitionError`、`RecognitionOutcome`）

禁止：

- `OnnxSession`、`OnnxTensor`、`OnnxResult`、`PixelMap`、`image.ImageSource`
- `UIAbilityContext`、`resourceManager`、Ability/窗口对象
- `Error` 实例、`RecognitionFailure`、带方法或闭包的对象

任务参数建议逐项传递，不整体传 `ImageSource`：

```ts
@Concurrent
function runInferenceTask(
  modelPath: string,
  pixels: ArrayBuffer,
  imageWidth: number,
  imageHeight: number,
  rowStride: number,
  pixelFormat: string,
  options: InferenceOptions,
  requestId: string,
  imageId: string
): Promise<RecognitionOutcome>
```

调度侧必须：

```ts
const task = new taskpool.Task(runInferenceTask, modelPath, image.data, ...);
task.setCloneList([image.data]);   // 复制，不转移；UI 仍需显示原图
await taskpool.execute(task);
```

- **不要**对 `image.data` 调用 `setTransferList`，否则 UI 侧缓冲区失效。
- 若出现 `10200006` 序列化异常，先检查是否传入了原生对象或 `Error`。
- 串行执行优先使用 `taskpool.SequenceRunner`，或服务自身维护“最多一个运行中任务”。

### 5.3 资源所有权与释放时机

| 资源 | 所有者 | 释放时机 |
| --- | --- | --- |
| 解码用 `PixelMap`/`ImageSource` | Agent 1 | 返回 `ImageSource` 前立即释放 |
| `ImageSource.data` (`ArrayBuffer`) | 页面（接收方） | 页面替换图片或离开页面时丢弃引用；推理层只读 |
| TaskPool 内像素副本 | 工作线程任务 | 任务结束由 GC 回收 |
| `OnnxSession` / `OnnxTensor` / `OnnxResult` | Agent 2 | `finally` 中 `Close`；同步模式在 `dispose` 时 |
| 沙箱模型文件 | Agent 2 | 可长期缓存；模型更换时覆盖 |
| `DetectionResult` | 页面 | 页面状态替换；不得含原生句柄 |

不得把原生对象塞进 `DetectionResult` 或 `RecognitionState`。

## 6. 一致行为

### 6.1 预处理与模型

- RGB、`float32`、`0..1`、NCHW、`[1,3,640,640]`。
- letterbox 缩放与填充值 114；逆变换使用实际 `scale/padLeft/padTop`。
- 输出 `[1,84,8400]`：4 个框值 + 80 个类别分数；无 objectness、无 NMS。
- 类别分数已 Sigmoid；置信度取 80 类最大值。
- 详见 `docs/phase-1-model.md` 第 4 节。

### 6.2 阈值与 NMS

| 项 | 约定 |
| --- | --- |
| 默认置信度 | 0.25 |
| 默认 IoU | 0.7 |
| NMS | 按类别（class-wise），IoU 0.7，最多 300 个，置信度降序 |
| 阈值范围 | `(0,1]`；UI 在调用前 clamp |
| 阈值变化 | 重新执行识别；服务在 NMS 前过滤，旧结果不得本地再过滤 |
| 结果展示 | 必须显示本次 `confidenceThreshold` |

### 6.3 样例图

本阶段样例图不随包分发；算法对照使用外部图片，避免包体和许可问题。

| 场景 | 预期行为 |
| --- | --- |
| 单物品图 | 至少 1 个框，类别合理，框贴合 |
| 多同类物品 | 同类计数值等于保留框数（编辑后同步） |
| 重叠物品 | 同类高 IoU 被抑制，异类保留 |
| 横图/竖图/方图 | 框对齐，无系统性留白偏移 |
| 带 EXIF 旋转的照片 | 方向正确，无重复旋转，框对齐 |
| 空白/无目标图 | `boxes=[]`，状态 `EMPTY`，不是错误 |
| 超大图内存不足 | `IMAGE_INVALID`，提示换图，不崩溃 |
| 损坏/不支持格式 | `IMAGE_INVALID`，可继续选图 |

数值对照基准：`bus.jpg`（810×1080，SHA-256 `c02019c4979c191eb739ddd944445ef408dad5679acab6fd520ef9d434bfbc63`），预期 1 个 bus + 至少 4 个 person（conf≥0.25，IoU 0.7）。PyTorch 与 ONNX 的框数可能因插值/NMS 边界差 1，不要求逐框完全相等，但类别与位置需一致。

### 6.4 模型缺失与 ABI 不支持

| 场景 | 服务行为 | 界面行为 |
| --- | --- | --- |
| rawfile 无模型 | `available=false`，`MODEL_MISSING`，`recoverable=true` | 状态 `UNAVAILABLE`，显示“识别不可用：模型文件缺失”，禁用识别 |
| hash/IO 不符 | `available=false`，`MODEL_INVALID`，`recoverable=false` | 同上，提示模型无效 |
| ABI 非 arm64 / 原生库加载失败 | `available=false`，`UNSUPPORTED_ABI`，`recoverable=false` | 同上，提示当前设备不支持端侧推理 |
| 模型恢复 | 重新 `initialize()` 或重启页面后可识别 | 入口恢复 |

模型缺失时工程必须可构建、可安装、可进入首页；不得因缺文件在编译期或页面 import 期失败。

### 6.5 状态机

```text
IDLE -> INITIALIZING -> READY -> RUNNING -> SUCCEEDED | EMPTY | ERROR
                     \-> UNAVAILABLE
```

- `RUNNING` 时禁止重复触发（同步模式天然阻塞，仍要禁用按钮）。
- 只有 `requestId` 和 `imageId` 都与当前页面一致时，才允许写入 `SUCCEEDED/EMPTY/ERROR`。
- 切换图片、离开页面后，旧结果必须丢弃。

## 7. 调用示例

```ts
import { ImageSource } from '../models/ImageTypes';
import {
  DetectionResult,
  InferenceOptions,
  RecognitionFailure,
  RecognitionStatus
} from '../models/DetectionTypes';
import { DEFAULT_INFERENCE_OPTIONS } from '../models/ModelConstants';
import { GalleryImageService } from '../services/camera/GalleryImageService';
import { RecognitionService } from '../services/inference/RecognitionService';

const gallery = GalleryImageService.getInstance();
const recognition = RecognitionService.getInstance();

async function prepare(): Promise<void> {
  const availability = await recognition.initialize();
  if (!availability.available) {
    // state.status = RecognitionStatus.UNAVAILABLE;
    // 展示 availability.error?.message；识别按钮禁用
    return;
  }
  // state.status = RecognitionStatus.READY;
}

async function recognizePicked(): Promise<DetectionResult | null> {
  let image: ImageSource;
  try {
    image = await gallery.pickFromGallery();
  } catch (e) {
    // CANCELLED：保留现有结果；其他错误：提示
    return null;
  }

  const requestId = `req-${Date.now()}`;
  // state = { status: RUNNING, requestId, imageId: image.imageId, modelAvailable: true }

  const options: InferenceOptions = {
    confidenceThreshold: DEFAULT_INFERENCE_OPTIONS.confidenceThreshold,
    iouThreshold: DEFAULT_INFERENCE_OPTIONS.iouThreshold,
    maxDetections: DEFAULT_INFERENCE_OPTIONS.maxDetections,
    executionMode: DEFAULT_INFERENCE_OPTIONS.executionMode
  };

  try {
    const result = await recognition.recognize(image, options, requestId);
    if (result.requestId !== requestId || result.imageId !== image.imageId) {
      return null; // 旧结果，丢弃
    }
    // state.status = result.boxes.length === 0 ? EMPTY : SUCCEEDED
    // state.result = result
    return result;
  } catch (e) {
    const failure = e as RecognitionFailure;
    // state.status = ERROR; state.error = failure.toRecognitionError()
    return null;
  }
}
```

阈值变化：使用同一 `image`，更新 `options.confidenceThreshold`，生成新 `requestId` 再次调用 `recognize`；不要改写上一次的 `result.boxes`。

## 8. 文件归属

| 范围 | 所有者 | 说明 |
| --- | --- | --- |
| `docs/phase-1-contract.md`、`docs/phase-1-model.md` | Agent 0 | 契约冻结后由负责人协调修改 |
| `app/entry/src/main/ets/models/**` | Agent 0 | 共享类型与模型常量；Agent 2 在移交后维护模型常量 |
| `app/entry/oh-package.json5`（onnxruntime 依赖） | Agent 0 → Agent 2 | 本次已声明，移交后由 Agent 2 维护 |
| `app/entry/src/main/resources/rawfile/models/**` | Agent 0 → Agent 2 | 已放置 `yolov13n.onnx` |
| `app/entry/src/main/ets/services/camera/**`、`components/camera/**` | Agent 1 | 采集、权限、相机组件 |
| `app/entry/src/main/module.json5` 相机权限及文案资源 | Agent 1 | 只改权限与相关字符串 |
| `app/entry/src/main/ets/services/inference/**`、`tasks/**` | Agent 2 | session、预处理、后处理、TaskPool |
| 推理相关测试目录 | Agent 2（用例）、Agent 5（质量与验收） | Agent 5 负责测试框架与证据整理 |
| `app/entry/src/main/ets/pages/Index.ets`、`components/recognition/**`、页面状态 | Agent 3 | 页面、结果编辑、耗时展示 |
| `docs/phase-1-review.md`、最终集成修复 | Agent 0 | 各模块交付后由 Agent 0 接管 |

共享类型不得由 Agent 1–5 私自修改。确需新增字段时，写入各自交接报告，由负责人统一更新。

## 9. 验证状态

已实测：

- `@ohos/onnxruntime` 1.0.0 安装成功，传递依赖 `@ohos/aki` 1.3.1。
- `./scripts/build-app.sh` 构建成功；HAP 内含 `libs/arm64-v8a/liblibrary.so`。
- 共享类型通过临时编译探针（已从 `Index.ets` 移除）编译通过；移除探针后的最终构建同样成功。
- ONNX 模型由 ONNX Runtime 1.23.2 CPU 加载并输出 `[1,84,8400]`；与官方 PyTorch 结果对照见模型文档。

待验证：

- arm64 模拟器/真机加载原生库并执行真实推理。
- TaskPool `setCloneList` 传像素、任务内创建/关闭 session 的稳定性与内存。
- 相机/相册 EXIF 方向归一化与框对齐。
- `@ohos/onnxruntime` 动态 import 在目标 API 上的可用性；若不可用，Agent 2 必须在报告中给出替代加载方式。
- x86_64/armeabi-v7a 设备只能显示 `UNSUPPORTED_ABI`，当前依赖不提供对应 `liblibrary.so`。
