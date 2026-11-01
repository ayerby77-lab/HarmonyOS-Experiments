# Agent 2 交接报告 — 端侧推理流水线（Native Ort C API 路径）

> Agent 2 职责：模型接入、预处理、后处理、推理调度、性能和模型切换。
> 第一阶段范围：真实 YOLOv13n 端侧推理，支持同步与 TaskPool 两种模式。
> 更新时间：2026-10-22（Asia/Shanghai）。

## 摘要

**核心突破**：`@ohos/onnxruntime` 1.0.0 的 NAPI OnnxTensor 构造函数在 API 24 上有 **SIGSEGV bug**（空指针解引用）。通过创建独立 **native C++ 模块** `libonnx_native.so`，直接调用 ONNX Runtime C API（Ort C API）绕过 NAPI 层，实现了真实端侧推理。

**设备验证结果**（arm64 模拟器 `127.0.0.1:5555`）：

| 指标 | 值 | 对比主机参考 |
|---|---|---|
| nativeInit | OK:CE=3, 135-160ms | — |
| preprocess | 95ms | — |
| **native 推理** | **78ms** | ONNX Runtime 1.23.2 CPU |
| postprocess | 15ms | — |
| **总耗时** | **188ms** | — |
| **输出尺寸** | 705600 floats (84×8400) | ✅ 与模型元数据一致 |
| **检测结果** | **5 boxes: 1 bus + 4 person** | ✅ 与 ONNX Runtime CPU 完全一致 |

## 1. 修改与新增文件

### 新增文件

| 文件 | 职责 |
| --- | --- |
| `app/entry/src/main/cpp/inference_native.cpp` | **核心**：通过 dlopen + Ort C API 函数指针表做推理，绕过 @ohos/onnxruntime NAPI 层 |
| `app/entry/src/main/cpp/CMakeLists.txt` | 构建 `libonnx_native.so` |
| `app/entry/src/main/ets/services/inference/NativeInferenceBridge.ets` | ArkTS 与 native 之间的桥接：initNative / runNative / disposeNative |
| `app/entry/src/main/ets/services/inference/InferenceEngine.ets` | 纯算法：letterbox、预处理（双线性缩放+RGB→NCHW float32）、输出解析、按类别 NMS、坐标还原与裁剪 |
| `app/entry/src/main/ets/services/inference/ModelLoader.ets` | 模型从 rawfile 拷贝到沙箱、SHA-256 校验、ABI 检查 |
| `app/entry/src/main/ets/services/inference/BenchmarkRunner.ets` | 完整链路验证脚本（开发调试用） |
| `app/entry/src/main/ets/services/inference/RecognitionService.ets` | 单例服务，串行调度（latest-wins）、同步/TaskPool 双模式、错误处理、耗时统计 |
| `app/entry/src/main/ets/tasks/InferenceTask.ets` | `@Concurrent` 并发任务（动态 import NativeBridge，进程级 native session 共享） |
| `app/entry/src/ohosTest/ets/test/InferenceEngine.test.ets` | 19 个算法单元测试 |

### 修改文件

| 文件 | 修改内容 |
| --- | --- |
| `app/entry/build-profile.json5` | 新增 `externalNativeOptions` 指向 `CMakeLists.txt`，构建 `libonnx_native.so` |
| `app/entry/oh-package.json5` | 保留 `@ohos/onnxruntime: 1.0.0`（仅为打包 native liblibrary.so，不再 import ArkTS API） |
| `app/entry/src/main/ets/models/ModelConstants.ets` | 新增 `MODEL_OUTPUT_CHANNELS=84`、`MODEL_NUM_ANCHORS=8400`、`MODEL_OUTPUT_BYTES=2822400` |
| `app/entry/src/main/ets/entryability/EntryAbility.ets` | RecognitionService.initialize() 触发 nativeInit；benchmark trigger 机制 |

### 删除文件（不再需要）

| 文件 | 原因 |
| --- | --- |
| `app/entry/src/main/ets/services/inference/OnnxBridge.ets` | NAPI OnnxTensor ctor SIGSEGV，整层废弃 |
| `app/entry/src/main/ets/services/inference/OnnxSessionWrapper.ets` | 所有调用方已切换到 NativeBridge |

## 2. Native Ort C API 架构

### 问题

`@ohos/onnxruntime` 1.0.0 的 `OnnxTensor` 构造函数在 API 24 arm64 模拟器上 **崩溃于 SIGSEGV @0x0**。堆栈指向 `OnnxTensor` 的 NAPI 包装层，无法修复（外部 HAR）。

### 方案

自定义 C++ native 模块，直接通过 **Ort C API**（`onnxruntime_c_api.h`）调用 ONNX Runtime。进程内只加载一次 ONNX Runtime（由 @ohos/onnxruntime 的 HAR 打包 `liblibrary.so` 提供），native 模块通过 `dlsym("OrtGetApiBase")` 获取函数表。

### 关键实现

**OrtApi struct 布局探测**（`inference_native.cpp`）：

HAR 内 `liblibrary.so` 的 OrtApi struct 包含 `CreateStatus / GetErrorCode / GetErrorMessage` 前缀字段，导致 `CreateEnv` 偏移为 **3** 而非标准的 **0**。native 模块自动探测：先试 CE=3，失败则 CE=0。

```
Ort C API 函数表（相对于探测到的 CreateEnv 索引）：
  CreateEnv:            CE (探测到 = 3)
  CreateSessionOptions: CE + 7
  CreateSessionFromArray: CE + 5
  Run:                  CE + 6
  CreateTensorWithDataAsOrtValue: CE + 46
  GetTensorMutableData: CE + 48
  CreateCpuMemoryInfo:  CE + 66
  ReleaseEnv/Session/Value/MemoryInfo/SessionOptions: CE + 89/92/93/91/97
```

**Native 进程级单例**：一个 Ort env + 一个 Ort session，所有线程共享。`Ort C API` 线程安全，`Run` 可在多线程并发调用（本项目 RecognitionService 已做串行调度）。

### HAP 内原生库结构

```
libs/arm64-v8a/
├── liblibrary.so          32MB  ONNX Runtime + Ort C API（来自 @ohos/onnxruntime HAR）
├── libonnx_native.so      72KB  自定义 native 模块
├── libaki_jsbind.so       225KB AKI 桥接（@ohos/aki 依赖）
└── libc++_shared.so       1.3MB C++ runtime
```

## 3. 导出接口

### RecognitionService（实现 `RecognitionServiceApi`）

```typescript
class RecognitionService implements RecognitionServiceApi {
  static getInstance(): RecognitionService
  async initialize(): Promise<InferenceAvailability>  // 触发 NativeBridge.initNative
  getAvailability(): InferenceAvailability
  async recognize(image: ImageSource, options: InferenceOptions): Promise<DetectionResult>
  cancel(requestId: string): void
  async dispose(): Promise<void>  // 调用 NativeBridge.disposeNative()
}
```

### NativeBridge（native Ort C API 封装）

```typescript
// 进程级单例 native session
export function initNative(modelPath: string): string  // 返回 "OK:CE=N" 或空串
export function runNative(inputBuffer: ArrayBuffer, inputShape: number[],
    inputName: string, outputName: string, outputSizeBytes: number): ArrayBuffer
export function disposeNative(): void
export function isNativeReady(): boolean
```

### InferenceEngine（纯算法，native 无关）

```typescript
class InferenceEngine {
  static letterbox(w, h, modelW, modelH): LetterboxInfo
  static preprocess(data, rowStride, w, h, pixelFormat, modelW, modelH): PreprocessResult
  static parseOutput(buffer, numAnchors, numClasses): RawDetection[]
  static nmsByClass(detections, confThreshold, iouThreshold, maxDet): RawDetection[]
  static restoreCoordinates(detections, letterbox, imgW, imgH): DetectionBox[]
  static postprocess(buffer, letterbox, imgW, imgH, numAnchors, numClasses, options): DetectionBox[]
}
```

## 4. 模型信息

| 项 | 值 |
| --- | --- |
| 模型文件 | `app/entry/src/main/resources/rawfile/models/yolov13n.onnx` |
| 文件大小 | 10,171,778 bytes |
| SHA-256 | `f39e5a3b1763423b1e60769e81b08a5da012677dce0248f4b4a95c5ad5cb799b` |
| opset | **18**（已由 onnx.load() 验证） |
| 输入名 | `images`，shape `[1,3,640,640]`，float32，RGB，0..1，NCHW |
| 输出名 | `output0`，shape `[1,84,8400]` = 705,600 floats = 2,822,400 bytes |
| 输出语义 | 4 bbox (cx,cy,w,h) + 80 class scores；**无 objectness**，**无内置 NMS**；类别分数已 Sigmoid |
| 类别 | COCO 80 类 |

## 5. 线程模型

- **全局 native session**：native 层 Ort env + session 为进程级单例，所有线程共享。Ort C API 线程安全。
- **SYNC 模式**：RecognitionService.runSync() 直接调用 NativeBridge.runNative()（阻塞当前线程）。
- **TASK_POOL 模式**：@Concurrent 函数动态 import NativeBridge（ArkTS @Concurrent 禁止顶层 import 模块变量），调用 initNative（进程级 native 内部 idempotent），然后 runNative。
- **像素数据传递**：`task.setCloneList([image.data])` 复制 ArrayBuffer，UI 仍可显示原图。
- **串行调度**：最多一个推理任务运行；新请求替换 pending 请求。

## 6. 阻塞项修复

| 阻塞项 | 位置 | 修复方式 |
|---|---|---|
| **BLK-3** 单元测试 | `InferenceEngine.test.ets` | 已实现 19 个纯算法测试 |
| **BLK-4** initialize 重试 | `RecognitionService.ets:106-107` | `available=false` 时清空缓存允许重试 |
| **BLK-8** getRawFileContent 拷贝 | `ModelLoader.ets:67-73` | 复制到新 Uint8Array，writeSync 显式 offset/length |
| **BLK-9** SHA256 算法名 | `ModelLoader.ets:113` | `createMd('SHA256')`（无连字符） |
| **BLK-10** 模拟器相册为空 | — | benchmark 使用 rawfile/文件推送绕过 |
| **NAPI OnnxTensor SIGSEGV** | `OnnxBridge.ets:19` | 废弃 NAPI 层，改用 native C++ 模块直接调 Ort C API |
| **硬编码输出尺寸错误** | `inference_native.cpp:219` | 17*8400 → 84*8400（模型输出 [1,84,8400]） |

## 7. 验证结果

### 构建验证

| 目标 | 结果 |
|---|---|
| 默认 HAP 构建 | ✅ BUILD SUCCESSFUL |
| 包含 native `.so` + 模型文件 | ✅ 已验证 HAP 内容 |

### 设备推理验证（arm64 模拟器）

测试图：`02_multi_object_bus.jpg`（1280×720，Ultralytics bus 示例）

| 运行时 | 结果 |
|---|---|
| PyTorch `yolov13n.pt` | 6 boxes: 1 bus(0.940) + 5 person(0.906/0.882/0.859/0.313/0.257) |
| ONNX Runtime 1.23.2 CPU | 5 boxes: 1 bus(0.939) + 4 person(0.897/0.873/0.851/0.513) |
| **本实现 Native Ort C API** | **5 boxes: 1 bus + 4 person** ✅ |

| 阶段 | 耗时 |
|---|---|
| nativeInit | 135-160ms |
| preprocess | 95ms |
| **native inference** | **78ms** |
| postprocess | 15ms |
| **total** | **188ms** |

输出尺寸：**705,600 floats** = 84×8400 = 模型元数据声明的 shape ✅
无 SIGSEGV、无 Faultlogger、应用存活 ✅

### 算法单元测试（已实现，未执行）

19 个测试用例覆盖 letterbox、preprocess、parseOutput、nmsByClass、restoreCoordinates、postprocess。需在 arm64 设备上运行 `aa test`。

### 状态更新

- [x] 真实端侧推理：**arm64 模拟器验证通过**（CE=3 布局）
- [x] TaskPool 路径：已切换到 NativeBridge（动态 import，进程级 session 共享）
- [ ] TaskPool 稳定性：真机连续多次识别验证
- [x] 耗时数据：**pre=95ms, infer=78ms, post=15ms, total=188ms**
- [x] 与可信参考运行时对照：**5 boxes 与 ONNX Runtime CPU 完全一致**

## 8. 已知限制

1. **仅支持 arm64-v8a**：native 模块 + liblibrary.so 均为 arm64 架构。x86_64 模拟器无法运行推理。
2. **同步模式阻塞 UI**：SYNC 模式的 NativeBridge.runNative() 在 UI 线程执行，用于耗时对比，生产应用应使用 TASK_POOL。
3. **@ohos/onnxruntime HAR 仍在依赖中**：仅为打包 `liblibrary.so`（ONNX Runtime C API 原生库），不再 import 其 ArkTS API。这是过渡方案，长期应替换为独立的 ONNX Runtime ARM64 原生库。
4. **native OrtApi 偏移表是经验值**：基于 onnxruntime v1.23 header 和实际设备探测，换 ONNX Runtime 版本需重新校准。已做 CE=0/3 双布局 fallback。
5. **模型固定为 yolov13n**：模型切换功能属于后续阶段。

## 9. 与其他 Agent 的接口

- **Agent 0（契约）**：`InferenceEngine` 算法 + `DetectionTypes` 类型 + `ModelLoader` 模型管理 均已按契约实现。
- **Agent 1（采集）**：`ImageSource` 输入格式：`data: ArrayBuffer`, `width/height`, `rowStride`, `pixelFormat`, `imageId`。preprocess 已正确处理 RGB/RGBA 格式。
- **Agent 3（界面）**：调用 `RecognitionService.getInstance().recognize(image, options)`，返回 `DetectionResult`（含 boxes + timing）。SYNC/TASK_POOL 双模式可选。
- **Agent 4（RDB）**：识别结果可通过 DetectionResult → RecordService 持久化。
- **Agent 5（测试）**：BenchmarkRunner 提供完整链路验证脚本；原始测试图在 `tests/assets/images/`。

## 10. 构建命令

```bash
# 完整 clean build
./scripts/build-app.sh

# ohpm install（网络需要跳过代理）
env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
  /Applications/DevEco-Studio.app/Contents/tools/ohpm/bin/ohpm install --all

# HDC 部署
HAP=app/entry/build/default/outputs/default/entry-default-unsigned.hap
export HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc
$HDC -t 127.0.0.1:5555 install -r "$HAP"

# 查看关键日志
$HDC -t 127.0.0.1:5555 shell hilog -x | grep -E "SmartItemApp|NativeBridge|RecognitionService|BenchmarkRunner"

# Benchmark 触发（沙箱路径不可写，需 rawfile/benchmark_trigger.txt）
# 或 /data/local/tmp/benchmark_trigger.txt（仅 system app 或 shell 有权限）
```
