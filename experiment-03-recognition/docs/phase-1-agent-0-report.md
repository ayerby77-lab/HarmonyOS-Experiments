# Agent 0｜架构与集成 交接报告

> 身份：Agent 0（架构、共享契约、兼容性准备与最终集成）。
> 范围：第一阶段共享契约与模型接入前提，对应任务第 1–7 项。
> 时间：2026-10-22（Asia/Shanghai）。构建与模型校验均在本机执行。

## 1. 结论

- 共享契约已冻结，`app/entry/src/main/ets/models/` 下 4 个共享类型文件可供 Agent 1/2/3 直接引用。
- YOLOv13n 官方权重已下载并导出为 ONNX，实际检查确认输出 `[1,84,8400]`、无 objectness、无 NMS。
- `@ohos/onnxruntime` 1.0.0 已加入依赖并打入 HAP，原生库仅支持 `arm64-v8a`。
- 最终状态（`Index.ets` 已还原、模型与全部共享类型就位）执行 `./scripts/build-app.sh` 成功，HAP 45 MB。
- 设备侧推理尚未执行，属于 Agent 2 的验证事项。

## 2. 修改与新增文件

| 文件 | 操作 | 说明 |
| --- | --- | --- |
| `app/entry/src/main/ets/models/ImageTypes.ets` | 新增 | `PixelFormat`、`ImageOrigin`、`ImageSource` |
| `app/entry/src/main/ets/models/DetectionTypes.ets` | 新增 | 检测框、结果、耗时、选项、状态、错误与初始化结果类型 |
| `app/entry/src/main/ets/models/ModelConstants.ets` | 新增 | 模型常量、默认阈值、COCO 80 类、`classLabel` |
| `app/entry/src/main/ets/models/RecognitionApi.ets` | 新增 | `ImageCaptureApi`、`RecognitionServiceApi`、错误转换入口 |
| `app/entry/oh-package.json5` | 修改 | 增加 `"@ohos/onnxruntime": "1.0.0"` |
| `app/entry/oh-package-lock.json5` | 生成 | `ohpm install --all` 产物，锁定 `@ohos/aki` 1.3.1 |
| `app/entry/oh_modules/` | 生成 | 本地依赖安装目录，不入库 |
| `app/entry/src/main/resources/rawfile/models/yolov13n.onnx` | 新增 | 导出模型，10,171,778 bytes（被 `.gitignore` 排除） |
| `docs/phase-1-contract.md` | 新增 | 共享契约 |
| `docs/phase-1-model.md` | 新增 | 模型、ABI、API 与兼容性记录 |
| `AGENTS.md` | 修改 | 六 agent 角色映射与文档/模块状态 |
| `docs/phase-1-agent-prompts.md` | 修改 | 六 agent 执行顺序；集成验收归入 Agent 0 |

未改动：`app/build-profile.json5`、`app/entry/src/main/module.json5`、`EntryAbility.ets`、`Index.ets`、后端代码。相机权限与文案仍归 Agent 1。

## 3. 导出接口

### 3.1 图像输入

```ts
enum PixelFormat { RGB_888 = 'rgb888', RGBA_8888 = 'rgba8888' }
enum ImageOrigin { CAMERA = 'camera', GALLERY = 'gallery' }

interface ImageSource {
  imageId: string;
  origin: ImageOrigin;
  width: number;         // 方向归一化后的像素宽
  height: number;        // 方向归一化后的像素高
  pixelFormat: PixelFormat;
  rowStride: number;     // data 长度必须等于 rowStride * height
  data: ArrayBuffer;     // 行优先 RGB/RGBA，未镜像
  isMirrored: boolean;
  exifOrientation: number; // 原始 EXIF 1-8，未知为 0
  capturedAtMs: number;
}
```

### 3.2 检测结果与配置

```ts
interface DetectionBox {
  classId: number;   // 0-79，对应 COCO_CLASSES
  label: string;
  confidence: number; // 80 类分数最大值，不含 objectness
  left: number; top: number; right: number; bottom: number; // 原图像素坐标
}

interface InferenceTiming {
  preprocessMs: number; inferenceMs: number; postprocessMs: number;
  totalMs: number; coldStart: boolean; modelLoadMs: number;
}

interface InferenceOptions {
  confidenceThreshold: number; // (0,1]，默认 0.25
  iouThreshold: number;        // (0,1]，默认 0.7
  maxDetections: number;       // 1..300，默认 300
  executionMode: InferenceExecutionMode; // SYNC | TASK_POOL
}

interface DetectionResult {
  requestId: string; imageId: string;
  imageWidth: number; imageHeight: number;
  boxes: DetectionBox[]; timing: InferenceTiming;
  executionMode: InferenceExecutionMode;
  confidenceThreshold: number; iouThreshold: number;
  modelId: string; modelSha256: string;
}
```

### 3.3 状态、错误与初始化

- `RecognitionStatus`：`IDLE / INITIALIZING / READY / RUNNING / SUCCEEDED / EMPTY / ERROR / UNAVAILABLE`。
- `RecognitionErrorCode`：`MODEL_MISSING / MODEL_INVALID / UNSUPPORTED_ABI / IMAGE_INVALID / INFERENCE_FAILED / CANCELLED`。
- `RecognitionFailure extends Error`：带 `code / recoverable / detail`，`toRecognitionError()` 转为可跨线程的普通对象。
- `RecognitionError`、`RecognitionOutcome`、`RecognitionState`、`ModelInfo`、`InferenceAvailability`：均为可序列化普通对象。
- `RecognitionServiceApi`：`initialize()`、`getAvailability()`、`recognize(image, options, requestId)`、`cancel(requestId)`、`dispose()`。
- `ImageCaptureApi`：`pickFromGallery()`、`capturePhoto()`。

### 3.4 模型常量

`MODEL_ID`、`MODEL_ASSET_PATH`、`MODEL_SHA256`、`MODEL_INPUT_NAME/OUTPUT_NAME`、`MODEL_INPUT_WIDTH/HEIGHT`、`MODEL_CLASS_COUNT`、`MODEL_OPSET`、`MODEL_LETTERBOX_PAD_VALUE`、`MODEL_STRIDE`、默认阈值、`COCO_CLASSES`、`classLabel()`。

## 4. 兼容性证据

| 项 | 结论 | 状态 |
| --- | --- | --- |
| 本机 SDK | HarmonyOS 26.0.0（API 26），DevEco Studio 26.0.0.105 | 已读取元数据 |
| 工程配置 | targetSdkVersion 26.0.0，compatibleSdkVersion 6.1.1(24) | 未改动 |
| 模拟器 | HarmonyOS 6.1.1(24)，`hw.cpu.arch=arm64`，镜像 `phone_all_arm` | 已读取 AVD/镜像元数据；未启动 |
| 推理库 | `@ohos/onnxruntime` 1.0.0，内部 ONNX Runtime 1.23.2，MIT，维护方 `ohos_tpc` | 已安装并打包 |
| 原生 ABI | 仅 `arm64-v8a/liblibrary.so`；x86_64/armeabi-v7a 无 ONNX 运行时 | HAP 内容已核对 |
| TaskPool | 原生句柄不可序列化；像素用 `setCloneList` 复制；`SequenceRunner` 串行 | 依据 SDK d.ts |
| 模型加载 | ONNX Runtime 1.23.2 CPU 可加载并输出 `[1,84,8400]` | 已实测（主机） |

## 5. 模型记录摘要

| 项 | 值 |
| --- | --- |
| 官方仓库 | `https://github.com/iMoonLab/yolov13` |
| 权重 | `yolov13n.pt`，10,570,688 bytes，SHA-256 `6653035017b0f111f80ec11ed914874ea85699b104aeac1e46e517d16889d6b7` |
| 许可证 | AGPL-3.0 |
| ONNX 大小/SHA-256 | 10,171,778 bytes / `f39e5a3b1763423b1e60769e81b08a5da012677dce0248f4b4a95c5ad5cb799b` |
| 导出 | `ultralytics 8.3.63`，`imgsz=640`、`opset=18`、`simplify=True`、batch 1、静态输入 |
| 输入 | `images`，float32，`[1,3,640,640]`，RGB、0..1、NCHW |
| 输出 | `output0`，float32，`[1,84,8400]`，4 框 + 80 类，无 objectness、无 NMS |
| 阈值/NMS | conf 0.25、class-wise IoU 0.7、最多 300，置信度降序 |
| 数值对照 | `bus.jpg`：PyTorch 6 框，ONNX 5 框，bus 置信度 0.940/0.939，位置一致 |

完整来源、导出命令与证据见 `docs/phase-1-model.md`。

## 6. 验证命令与结果

```sh
./scripts/build-app.sh
# BUILD SUCCESSFUL in 2 s 797 ms

shasum -a 256 app/entry/src/main/resources/rawfile/models/yolov13n.onnx
# f39e5a3b1763423b1e60769e81b08a5da012677dce0248f4b4a95c5ad5cb799b

unzip -l app/entry/build/default/outputs/default/entry-default-unsigned.hap
# libs/arm64-v8a/liblibrary.so            32,481,152 bytes
# resources/rawfile/models/yolov13n.onnx  10,171,778 bytes
```

已知构建警告：依赖 HAR 与本模块重复声明 `page_show` 字符串资源，Hvigor 取先声明者，不影响构建。

## 7. 移交 Agent 2 的文件

推理依赖与模型相关文件的维护权自本报告起移交 Agent 2：

| 文件 | 移交内容 |
| --- | --- |
| `app/entry/oh-package.json5` | `@ohos/onnxruntime` 版本与新增推理依赖声明 |
| `app/entry/oh-package-lock.json5` | 锁定版本；升级依赖时同步 |
| `app/entry/src/main/resources/rawfile/models/yolov13n.onnx` | 模型文件本体、替换与校验 |
| `app/entry/src/main/ets/models/ModelConstants.ets` | 模型 ID、文件名、SHA-256、输入输出名/形状、opset、类别表、默认阈值 |
| `docs/phase-1-model.md` | 模型来源、导出步骤、IO 元数据、ABI 兼容性与设备验证记录 |

边界：

- `ImageTypes.ets`、`DetectionTypes.ets`、`RecognitionApi.ets` 的接口语义仍由 Agent 0 冻结；Agent 2 不得私改字段或枚举，需要变更时写入交接报告。
- `ModelConstants.ets` 中仅模型相关常量与 `COCO_CLASSES` 随模型更换而更新；默认阈值变更需在报告中说明。
- `.gitignore` 排除 `*.onnx`，模型不入库。新环境需按 `docs/phase-1-model.md` 第 4.2 节重新导出，或由 Agent 2 提供等价的分发方式并更新文档。

## 8. 尚待验证（Agent 2 / 设备阶段）

- arm64 模拟器或真机加载 `liblibrary.so`、创建 session、完成单张图片真实推理。
- `libace_napi.z.so`、`libuv.so` 在目标系统的实际加载结果。
- TaskPool 内按任务创建/关闭 session 的稳定性、冷启动耗时与内存峰值。
- 动态 `import('@ohos/onnxruntime')` 在 API 24/26 上的可用性；不可用时需给出替代加载方式。
- 相机/相册 EXIF 方向归一化后的真实像素与检测框对齐。
- x86_64/armeabi-v7a 设备仅能显示 `UNSUPPORTED_ABI`，当前依赖不提供对应原生库。

## 9. 已知限制

- 当前依赖无法覆盖 x86_64 模拟器；若必须使用，需要维护方提供 `libs/x86_64/liblibrary.so` 或自建 HAR。
- 同步模式在 UI 线程执行会阻塞界面，页面必须显示识别中并禁用重复触发。
- 模型缺失时工程可构建、可安装，但识别服务返回 `MODEL_MISSING`，界面显示识别不可用。
- 首次真实推理尚未发生，第一阶段完成声明仍缺少设备侧证据。
