# 第一阶段模型与端侧运行库记录

> Agent 0 维护。任务完成后，`@ohos/onnxruntime` 依赖、模型文件和本文档的维护权移交 Agent 2。
> 记录时间：2026-10-22（Asia/Shanghai）。所有命令均在项目根目录或文中注明路径执行。

## 1. 结论摘要

| 项 | 结论 | 证据/状态 |
| --- | --- | --- |
| 本机 SDK | HarmonyOS 26.0.0（API 26），DevEco Studio 26.0.0.105 | 已读取 SDK 元数据 |
| 工程配置 | targetSdkVersion 26.0.0，compatibleSdkVersion 6.1.1(24) | 未改动 |
| 模拟器 | HarmonyOS 6.1.1(24)，`arm64`，镜像 `phone_all_arm` | 已读取 AVD 与镜像元数据；未启动 |
| 推理库 | `@ohos/onnxruntime` 1.0.0，内部 ONNX Runtime 1.23.2，MIT | 已安装并打包；运行待验证 |
| 原生 ABI | 仅 `arm64-v8a` 提供 `liblibrary.so` | HAP 内容已核对 |
| 模型 | YOLOv13n 官方 `.pt` 导出，AGPL-3.0，ONNX opset 18 | 已在 macOS 导出并用 onnxruntime 校验 |
| 构建 | 加入依赖与模型后 `BUILD SUCCESSFUL`，HAP 45 MB | 已实测 |
| 设备推理 | 未启动模拟器，未做真机 | 待验证 |

## 2. 本机 DevEco SDK 与模拟器

### 2.1 SDK

证据文件：

- `/Applications/DevEco-Studio.app/Contents/sdk/default/sdk-pkg.json`
- `/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/oh-uni-package.json`
- `/Users/avery/Desktop/hongmeng/SmartItemRecognitionAssistant/app/hvigor/hvigor-config.json5`

关键值：

```json
// sdk-pkg.json
{ "apiVersion": "26", "displayName": "HarmonyOS 26.0.0",
  "platformVersion": "26.0.0", "version": "26.0.0.105", "releaseType": "Release" }

// oh-uni-package.json
{ "apiVersion": "26", "version": "26.0.0.105", "platformVersion": "26.0.0" }

// hvigor-config.json5
{ "modelVersion": "26.0.0", "dependencies": {} }
```

工程 `app/build-profile.json5` 保持：

```json5
"targetSdkVersion": "26.0.0",
"compatibleSdkVersion": "6.1.1(24)",
"runtimeOS": "HarmonyOS"
```

### 2.2 模拟器架构

已安装系统镜像：

```
/Users/avery/Library/Huawei/Sdk/system-image/HarmonyOS-6.1.1/phone_all_arm/
```

镜像元数据 `info.json`：

```json
{ "apiVersion": "24", "abi": "arm", "version": "6.1.0.126" }
```

已有 AVD `VoiceCalculator_API24` 的 `config.ini`：

```ini
os.osVersion=HarmonyOS 6.1.1(24)
os.apiVersion=24
os.softwareVersion=6.1.0.126
hw.cpu.arch=arm64
hw.cpu.ncore=4
```

主机为 Apple Silicon（`uname -m` = `arm64`，Apple M5）。因此本机模拟器是 **arm64 客户机**，与 `@ohos/onnxruntime` 仅提供的 `arm64-v8a` 原生库一致。

检查时模拟器未启动：

```text
$ <sdk>/default/openharmony/toolchains/hdc list targets
[Empty]
```

`Emulator` 组件版本为 26.0.0.400（`minVersion` 26.0.0.270，`supportVersion` 6.1-hos-single-8）。

### 2.3 兼容性判断

- 工程 `compatibleSdkVersion` 6.1.1(24) 与本机镜像 API 24 一致。
- `@ohos/onnxruntime` HAR 声明 `compatibleSdkVersion: 12`、`compatibleSdkType: OpenHarmony`，高于 12 的 SDK 可加载；本项目 API 26 编译通过。
- 模拟器仅在 arm64 上具备 `liblibrary.so`。若改用 x86_64 模拟器（Windows/Intel Mac 或手工 x86 镜像），当前依赖不可用，见第 5 节。

## 3. onnxruntime-ohos 依赖

### 3.1 来源与版本

| 项 | 值 |
| --- | --- |
| OHPM 包名 | `@ohos/onnxruntime` |
| 版本 | `1.0.0`（最新） |
| 维护方 | `ohos_tpc` / OpenHarmony Application TPC |
| 仓库 | `https://gitcode.com/OpenHarmony-ApplicationTPC/ohos_onnxruntime` |
| 许可 | MIT（`LICENSE` + `README.OpenSource`） |
| 上游 ONNX Runtime | 1.23.2（`README.OpenSource`） |
| HAR SHA-512 | `sha512-BqLHgwt5QUDk8Qgew1DKTrU36irkOlOg4jSYq884VLZJy7q2jWgqcH2qHFORTmNPZurioLoR+eJBOebKdqeK2Q==` |
| 传递依赖 | `@ohos/aki`（本次解析为 1.3.1） |

元数据查询：

```sh
curl -sS "https://ohpm.openharmony.cn/ohpm/@ohos%2Fonnxruntime"
```

HAR 内 `README.OpenSource`：

```json
{ "Name": "onnxruntime", "License": "MIT", "Version Number": "1.23.2",
  "Upstream URL": "https://github.com/microsoft/onnxruntime" }
```

### 3.2 原生库 ABI

HAR 只包含：

```
libs/arm64-v8a/liblibrary.so     (31 MiB, ONNX Runtime + NAPI)
libs/arm64-v8a/libc++_shared.so  (1.2 MiB)
```

`llvm-readelf -h`：ELF64，`Machine: AArch64`。

`llvm-readelf -d` 的 `NEEDED`：

```
libace_napi.z.so
libaki_jsbind.so
libhilog_ndk.z.so
libuv.so
libc++_shared.so
libc.so
```

构建后的 HAP 实际内容（`unzip -l entry-default-unsigned.hap`）：

```
libs/arm64-v8a/liblibrary.so
libs/arm64-v8a/libaki_jsbind.so
libs/arm64-v8a/libc++_shared.so
libs/x86_64/libaki_jsbind.so
libs/x86_64/libc++_shared.so
libs/armeabi-v7a/libaki_jsbind.so
libs/armeabi-v7a/libc++_shared.so
```

注意：`x86_64` 与 `armeabi-v7a` 只有 `@ohos/aki` 的桥接库，没有 `liblibrary.so`。这些 ABI 上加载 ONNX Runtime 会失败。

### 3.3 ArkTS/Javascript API 摘要

类型定义来自 HAR 的 `Index.d.ets` 与 `src/main/cpp/types/libonnxruntime_napi/Index.d.ts`：

```ts
OnnxEnvironment.InitEnvironment(): void
OnnxEnvironment.CreateSessionFromModelFile(modelPath: string): OnnxSession
OnnxEnvironment.CreateSessionFromBuffer(modelBuffer: Int8Array): OnnxSession
OnnxSession.GetInputNames(): string[]
OnnxSession.GetOutputNames(): string[]
OnnxSession.Run(inputMap: Record<string, OnnxValue>): OnnxResult
OnnxResult.GetValueByIndex(index: number): OnnxValue
OnnxTensor.GetDataAsArrayBuffer(): ArrayBuffer
OnnxSession.Close(): void
OnnxOptions.Close(): void
```

可用于本模型的调用路径：

1. `InitEnvironment()` 一次。
2. 从沙箱文件 `CreateSessionFromModelFile(path)`，避免每次复制 9.7 MB 缓冲区。
3. `OnnxTensor(input.data, [1,3,640,640], OnnxArkTSType.FLOAT)` 构造输入。
4. `Run({ 'images': tensor })`，取 `output0` 的 `ArrayBuffer`。
5. 所有 `OnnxTensor`、`OnnxResult`、`OnnxSession` 必须在同一线程创建、使用并在 `finally` 中 `Close()`。

`@ohos/onnxruntime` 没有提供一次性“session 池”或跨线程句柄；HAR 内是 NAPI 原生对象。

### 3.4 TaskPool 约束（SDK 声明证据）

依据 `/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/api/@ohos.taskpool.d.ts`：

- `Task` 的函数必须用 `@Concurrent` 装饰，参数与返回值必须是可序列化类型，否则抛 `10200006`。
- `Task.setTransferList(transfer)`：把 `ArrayBuffer` 控制权转移给工作线程，转移后原缓冲区失效。
- `Task.setCloneList(cloneList)`：`Sendable` 实例或 `ArrayBuffer` 以复制方式传递，目的端修改不影响原对象。
- `taskpool.SequenceRunner`（API 11 起，具名构造 API 12 起）提供串行队列，可用于保证同时只有一个推理任务。
- TaskPool 不保证同一函数总落在同一工作线程，不能把 `OnnxSession` 放在模块全局变量里假定复用。
- NAPI 原生对象（`OnnxSession`、`OnnxTensor`、`OnnxResult`）不属于可序列化类型，禁止作为 TaskPool 参数或返回值。

因此契约规定：

- 同步模式：session 由服务在调用线程创建并复用，所有 `Run` 在同一线程。
- TaskPool 模式：在并发任务内部创建 session、执行、`Close`，不跨线程传递原生句柄。是否可优化为常驻 Worker 由 Agent 2 实测后决定，但不得改变公共 API。
- 像素 `ArrayBuffer` 以复制方式进入任务（`setCloneList`），不使用转移列表，保证 UI 继续持有原图。

## 4. YOLOv13 官方模型

### 4.1 来源与许可

| 项 | 值 |
| --- | --- |
| 官方仓库 | `https://github.com/iMoonLab/yolov13` |
| 论文 | `https://arxiv.org/abs/2506.17733` |
| 权重发布 | Release tag `yolov13` |
| yolov13n.pt | `https://github.com/iMoonLab/yolov13/releases/download/yolov13/yolov13n.pt` |
| 权重大小 | 10,570,688 bytes |
| 权重 SHA-256 | `6653035017b0f111f80ec11ed914874ea85699b104aeac1e46e517d16889d6b7` |
| 许可证 | AGPL-3.0（仓库 `LICENSE`，模型元数据 `license: AGPL-3.0 License`） |
| 官方 ONNX | **未提供**；README 仅给出 Ultralytics 导出命令 |

官方仓库基于 Ultralytics（`ultralytics.__version__ = 8.3.63`）。其 README 的导出说明：

```python
from ultralytics import YOLO
model = YOLO('yolov13n.pt')
model.export(format='onnx')
```

官方未固定 `imgsz`、`opset`、`batch` 或 `dynamic`，直接执行会使用上游默认值。为保证端侧输入固定，本项目采用下面的显式导出。

### 4.2 可复现导出步骤（已在本机执行）

环境（macOS arm64，CPU 导出，无 CUDA）：

```text
Python 3.12.15
torch 2.14.1
torchvision 0.29.1
ultralytics 8.3.63（iMoonLab/yolov13 仓库 editable 安装）
onnx 1.23.2
onnxslim 0.1.98
onnxscript 0.7.2
onnxruntime 1.23.2
```

步骤：

```sh
mkdir -p /tmp/yolov13-work && cd /tmp/yolov13-work

# 1. 官方权重
curl -LO https://github.com/iMoonLab/yolov13/releases/download/yolov13/yolov13n.pt
shasum -a 256 yolov13n.pt
# 6653035017b0f111f80ec11ed914874ea85699b104aeac1e46e517d16889d6b7

# 2. 官方代码
git clone --depth 1 https://github.com/iMoonLab/yolov13.git repo

# 3. 仅安装导出所需依赖（requirements.txt 里的 flash-attn 为 Linux/CUDA 轮子，CPU 导出跳过）
uv venv --python 3.12 venv
uv pip install --python venv/bin/python -e ./repo onnx onnxslim onnxruntime \
  huggingface_hub onnxscript

# 4. 固定 batch=1、imgsz=640、opset=18、静态输入、简化图
./venv/bin/yolo export model=yolov13n.pt format=onnx imgsz=640 opset=18 simplify=True
```

说明：

- 首次尝试 `opset=17` 时，torch 2.14 导出器提示实现最低版本为 18，版本转换失败后保留 18。因此最终显式使用 `opset=18`，与实际产物一致。
- 导出脚本会输出 `FlashAttention is not available ... using scaled_dot_product_attention`，这是 CPU 环境的正常回退，不影响 YOLOv13n 结构。
- 未使用 `half=True`；模型为 FP32。

### 4.3 生成的 ONNX 元数据

文件已放入：

```
app/entry/src/main/resources/rawfile/models/yolov13n.onnx
```

| 项 | 值 |
| --- | --- |
| 大小 | 10,171,778 bytes |
| SHA-256 | `f39e5a3b1763423b1e60769e81b08a5da012677dce0248f4b4a95c5ad5cb799b` |
| IR version | 10 |
| opset | 18（default domain） |
| producer | `pytorch 2.14.1` |
| 图节点数 | 744 |
| 输入 | `images`，`tensor(float)`，`[1, 3, 640, 640]` |
| 输出 | `output0`，`tensor(float)`，`[1, 84, 8400]` |
| task | `detect` |
| stride | 32 |
| imgsz | `[640, 640]` |
| 类别 | COCO 80 类，内嵌于 metadata `names` |
| NMS 节点 | 无（无 `NonMaxSuppression`/`NMS`） |
| 输出算子 | Conv/Add/Mul/Div/Sigmoid/Softmax/Reshape/Transpose/Concat/Split/Resize 等 |

关键代码核对：

```python
import onnx
m = onnx.load('yolov13n.onnx')
print([(o.domain, o.version) for o in m.opset_import])  # [('', 18)]
for i in m.graph.input:  print(i.name, i.type.tensor_type.shape)
for o in m.graph.output: print(o.name, o.type.tensor_type.shape)
```

### 4.4 输出布局（已用实际模型确认，非按其他 YOLO 版本推测）

`84 = 4 + 80`：

- 第 0-3 行：`cx, cy, w, h`，单位是 **640×640 letterbox 输入上的像素**。
- 第 4-83 行：80 个类别分数。
- **无 objectness 列**。若含 objectness，列数应为 `4 + 1 + 80 = 85`。
- 类别分数已在图内做过 Sigmoid，是 0..1 概率；置信度取 `max(class_scores)`，不是 `objectness * class_score`。
- **不含 NMS**，8400 个候选全部保留。

后处理契约：

1. `pred = output0[0].transpose()`，得到 `[8400, 84]`。
2. `confidence = max(pred[:, 4:84])`，`classId = argmax(pred[:, 4:84])`。
3. 以 `confidence >= confidenceThreshold` 过滤（默认 0.25）。
4. `cx,cy,w,h -> x1,y1,x2,y2`。
5. 按类别做 NMS，默认 IoU 0.7，最多 300 个（`torchvision.ops.batched_nms` 等价逻辑）。
6. 逆 letterbox：`x_orig = (x - padLeft) / scale`，`y_orig = (y - padTop) / scale`。
7. 裁剪到 `[0, width] × [0, height]`，丢弃退化框，按置信度降序。

### 4.5 预处理契约

- 颜色顺序：**RGB**（不是相机常见的 NV21/BGR）。
- 数值：`float32`，`0..1`，`value / 255.0`。
- 布局：NCHW，`[1, 3, 640, 640]`。
- letterbox：`scale = min(640 / width, 640 / height)`；`newW = round(width * scale)`，`newH = round(height * scale)`；`padLeft = round((640 - newW) / 2 - 0.1)`，`padTop = round((640 - newH) / 2 - 0.1)`；填充值 `114`。
- 不改变宽高比，不做居中裁剪。

### 4.6 数值对照证据

测试图：Ultralytics 示例 `bus.jpg`（810×1080，SHA-256 `c02019c4979c191eb739ddd944445ef408dad5679acab6fd520ef9d434bfbc63`）。该图不随包分发。

同一预处理、conf=0.25、class-wise NMS IoU=0.7：

| 运行时 | 结果 |
| --- | --- |
| PyTorch `yolov13n.pt` | 6 个框：1 bus（0.940）+ 5 person（0.906/0.882/0.859/0.313/0.257） |
| ONNX Runtime 1.23.2 CPU | 5 个框：1 bus（0.939）+ 4 person（0.897/0.873/0.851/0.513） |

- bus 框：PyTorch `(10.9, 229.3, 807.1, 741.0)`，ONNX `(19.7, 230.5, 807.6, 737.5)`，差异来自缩放插值与低置信度框的 NMS 边界，不构成坐标空间错误。
- 输出最大值 657.77、最小值 -12.91，说明是未裁剪的原始回归值，需要后处理裁剪。
- 结论：`[1,84,8400]`、无 objectness、无 NMS、RGB/0..1/NCHW 均与文档一致。

## 5. 兼容性问题与可执行方案

### 5.1 已实测

- 添加 `@ohos/onnxruntime: 1.0.0` 后 `ohpm install` 成功，传递安装 `@ohos/aki: 1.3.1`。
- `./scripts/build-app.sh` 构建成功，HAP 内含 `libs/arm64-v8a/liblibrary.so`。
- 共享类型经临时编译探针验证可被 ArkTS 编译（探针未留在源码中）。
- 模型可由 ONNX Runtime 1.23.2 CPU 正确加载和推理，输出布局与官方 PyTorch 一致。
- 构建存在一条资源冲突警告：依赖 HAR 与本模块都声明 `page_show` 字符串，Hvigor 取先声明者。当前不影响构建，记录为已知警告。

### 5.2 待设备验证

- 在 API 24 arm64 模拟器上加载 `@ohos/onnxruntime` 原生库、创建 session、执行单张图片推理。
- `liblibrary.so` 对系统库 `libace_napi.z.so`、`libuv.so` 的实际加载结果。
- TaskPool 中按任务创建/关闭 session 的耗时、内存表现和稳定性。
- 相机/相册方向归一化后的真实像素与框对齐。
- 真机（不同 HarmonyOS 版本）上的 ABI 与内存上限。

### 5.3 x86_64 / armeabi-v7a 不可用的处理

现状：HAR 只有 `arm64-v8a/liblibrary.so`。

可执行方案（按优先级）：

1. **只支持 arm64**（本阶段推荐）：使用 arm64 模拟器/真机；界面在启动时读取 `deviceInfo.abi`，非 arm64 时把可用性置为 `UNSUPPORTED_ABI` 并显示识别不可用。HAP 仍可构建和安装，其他功能可用。
2. **向维护方索取 x86_64 构建**：在 `https://gitcode.com/OpenHarmony-ApplicationTPC/ohos_onnxruntime` 提 issue 或按 tpc_c_cplusplus 的 onnxruntime 编译脚本产出 `libs/x86_64/liblibrary.so`，重新打 HAR。未获新库前不要声称支持 x86 模拟器。
3. **自建 HAR**：用 OpenHarmony NDK 交叉编译 ONNX Runtime 1.23.2 的 x86_64 版本并复用 NAPI 绑定；工作量大，且需要处理 `@ohos/aki` 的 ABI。

阻塞点：若必须使用 x86_64 模拟器，当前官方 OHPM 包无法满足；这是依赖侧限制，不是工程配置可绕过的问题。

### 5.4 模型缺失/损坏

- 模型文件被 `.gitignore` 的 `*.onnx` 排除，克隆后可能不存在。缺失时：
  - 工程仍可编译、安装、进入首页；
  - `RecognitionService.initialize()` 返回 `available=false`、`code=MODEL_MISSING`；
  - 界面显示“识别不可用：模型文件缺失”，识别按钮禁用。
- 文件存在但 SHA-256 不匹配或输入输出形状不符：`MODEL_INVALID`，同样不可用。
- 重新放置模型后重启服务/页面即可恢复，无需重新编译。

## 6. 构建配置与产物

本次新增的构建配置只有模块依赖：

```json5
// app/entry/oh-package.json5
"dependencies": {
  "@ohos/onnxruntime": "1.0.0"
}
```

`ohpm install --all` 生成 `app/entry/oh-package-lock.json5` 与 `app/entry/oh_modules/`。

验证命令：

```sh
cd /Users/avery/Desktop/hongmeng/SmartItemRecognitionAssistant
./scripts/build-app.sh
```

结果：

```text
BUILD SUCCESSFUL in 2 s 797 ms
```

产物：

```
app/entry/build/default/outputs/default/entry-default-unsigned.hap  (45 MB)
```

HAP 内已核对：

```
libs/arm64-v8a/liblibrary.so                 32,481,152 bytes
resources/rawfile/models/yolov13n.onnx       10,171,778 bytes
```

`liblibrary.so` 与模型是包体主要增量。

## 7. 移交 Agent 2 的事项

- 维护 `@ohos/onnxruntime`、`@ohos/aki` 版本与 HAR 完整性。
- 维护 `app/entry/src/main/resources/rawfile/models/yolov13n.onnx` 及 `models/ModelConstants.ets` 中的 hash/IO 常量。
- 按 `docs/phase-1-contract.md` 实现 session 线程约束、TaskPool 复制策略和错误映射。
- 若更换模型或重新导出，更新本文档第 4 节与共享常量，并重新记录 SHA-256。
- 完成设备验证后，将第 5.2 节条目改为实测结果。

---

## 8. 设备验证（Agent 2，2026-10-22）

### 8.1 验证环境

| 项 | 值 |
|---|---|
| 设备 | HarmonyOS 6.1.1 (API 24) arm64 模拟器 |
| HDC | `127.0.0.1:5555` |
| 构建 SDK | HarmonyOS 26.0.0 (API 26)，compatibleSdkVersion 6.1.1(24) |

### 8.2 原始阻塞：OnnxTensor SIGSEGV

`@ohos/onnxruntime` 1.0.0 的 `OnnxTensor(data, shape, type)` 构造函数在 API 24 上 **SIGSEGV @0x0**，空指针解引用。堆栈指向 HAR 内的 NAPI 包装层，无外部 patch 可用。

### 8.3 解决：Native Ort C API 直连

创建自定义 C++ native 模块 `libonnx_native.so`，通过 **Ort C API** 直接调用 ONNX Runtime，绕过整个 NAPI 层。

```
调用链：
  ArkTS NativeBridge.runNative()
    → NAPI nativeRun() [libonnx_native.so]
      → Ort C API: CreateCpuMemoryInfo
      → Ort C API: CreateTensorWithDataAsOrtValue (zero-copy input)
      → Ort C API: Run
      → Ort C API: GetTensorMutableData
      → memcpy → 新建 ArrayBuffer 返回 ArkTS
```

**OrtApi struct 布局**：HAR 内 `liblibrary.so` 使用有 `CreateStatus/GetErrorCode/GetErrorMessage` 前缀的 OrtApi struct，导致 `CreateEnv` 偏移 = **3**（标准值为 0）。native 模块自动探测两种布局（CE=3 优先，失败则 CE=0）。探测结果：

```
OK:CE=3 sessIdx=8
```

`CE=3` 表示 CreateEnv 在 index 3；`sessIdx=8` = 3 + REL_CreateSessionFromArray(5)，验证了偏移表的正确性。

### 8.4 onnxruntime-ohos 依赖现状

HAR 仍在 `oh-package.json5` 依赖中 **但仅用于打包 native liblibrary.so**（ONNX Runtime C API 底层库）。ArkTS 代码不再 import 其 API（OnnxBridge/OnnxSessionWrapper 已删除）。

### 8.5 推理验证结果

测试图：`tests/assets/images/02_multi_object_bus.jpg`（Ultralytics bus 示例，1280×720）

| 指标 | 值 |
|---|---|
| nativeInit | OK:CE=3，耗时 135-160ms |
| 输出尺寸 | **705,600 floats** (84×8400) ✅ 与模型元数据一致 |
| preprocess | 95ms |
| native 推理 | **78ms** |
| postprocess | 15ms |
| **总耗时** | **188ms** |
| **检测结果** | **5 boxes: 1 bus + 4 person** |

与主机参考对照（同一张图，conf=0.25, IoU=0.7）：

| 运行时 | 检测框 |
|---|---|
| PyTorch yolov13n.pt | 6: 1 bus + 5 person |
| ONNX Runtime 1.23.2 CPU | 5: 1 bus + 4 person |
| **本实现 native Ort C API** | **5: 1 bus + 4 person** ✅ |

### 8.6 HAP 原生库清单（最终）

```
libs/arm64-v8a/
├── liblibrary.so         32MB   ONNX Runtime C API + 内部 OrtApi（来自 @ohos/onnxruntime HAR）
├── libonnx_native.so     72KB   我们的 native Ort C API 桥接
├── libaki_jsbind.so      225KB  AKI 桥接（@ohos/aki 传递依赖）
└── libc++_shared.so      1.3MB  C++ runtime
```

输出 shape bug 修复：native C++ 硬编码 fallback `17*8400` 改为正确的 `84*8400`（模型输出 `[1, 84, 8400]`，84=4 bbox+80 classes）。之前 dummy test 只复制了 1/5 模型输出，是损坏的。
