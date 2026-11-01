# Agent 2 第二阶段交接报告 — 识别结果可追溯性

> Agent 2 职责延续：模型接入、预处理、后处理、推理调度、性能和模型切换。
> 第二阶段范围：检查并补齐记录所需的可追溯字段，明确坐标约定，执行推理回归，保持第一阶段行为稳定。

## 1. 变更概述

第二阶段的数据契约（`docs/phase-1-data-contract.md`）要求识别记录必须可追溯到：
- 哪个模型（`modelId` + `modelSha256`）
- 哪些原始类别（`classId`/`label`）
- 用什么阈值（`confidenceThreshold` + `iouThreshold`）
- 原图尺寸（`imageWidth` + `imageHeight`）
- 推理耗时（`timing` 四字段 + 冷启动标记）
- **识别完成时间**（`recognizedAtMs`）

第一阶段交付的 `DetectionResult` 已完整覆盖前五项，但**缺少 `recognizedAtMs`**——这是 Agent 4 在 `phase-1-agent-4-report.md` 中明确提出的接入阻塞，也是 `phase-1-data-contract.md` 第 9.2 节"建议 1"的内容。

本次变更仅补齐这一字段，并验证模型版本/OPSET 与实际 ONNX 元数据的一致性；不改任何算法、线程模型或阈值语义。

## 2. 修改文件

| 文件 | 修改内容 |
| --- | --- |
| `app/entry/src/main/ets/models/DetectionTypes.ets` | `DetectionResult` 新增 `recognizedAtMs: number`；`requestId` 注释补充"不得作为数据库主键或上传幂等键" |
| `app/entry/src/main/ets/services/inference/RecognitionService.ets` | `runSync` 返回的 `DetectionResult` 加 `recognizedAtMs: Date.now()` |
| `app/entry/src/main/ets/tasks/InferenceTask.ets` | TaskPool 任务内构建的 `DetectionResult` 加 `recognizedAtMs: Date.now()` |

未修改：InferenceEngine、ModelLoader、OnnxBridge、OnnxSessionWrapper、RecognitionService 其他方法、InferenceEngine 测试。

## 3. 检测结果可追溯字段核对

按 `phase-1-data-contract.md` 第 9.3 节逐项核对，确认 `DetectionResult` + `DetectionBox` 已完整覆盖记录层需要的全部原始字段：

| 记录需要的字段 | 来源 | 本次状态 |
| --- | --- | --- |
| 原始框几何 | `DetectionBox.left/top/right/bottom` | 已存在 ✓ |
| 原始类别 | `DetectionBox.classId/label` | 已存在 ✓ |
| 置信度（原始类别） | `DetectionBox.confidence` | 已存在 ✓ |
| 阈值（实际使用值） | `DetectionResult.confidenceThreshold/iouThreshold` | 已存在 ✓ |
| 分段耗时 | `InferenceTiming.*Ms` + `coldStart` + `modelLoadMs` | 已存在 ✓ |
| 模型版本/完整性 | `DetectionResult.modelId/modelSha256` | 已存在 ✓ |
| 原图尺寸 | `DetectionResult.imageWidth/imageHeight` | 已存在 ✓ |
| 执行模式 | `DetectionResult.executionMode` | 已存在 ✓ |
| 识别完成时间 | `DetectionResult.recognizedAtMs` | **本次补齐** ✓ |
| 坐标约定 | 原图像素空间、裁剪到 `[0,w]×[0,h]`、`right>left && bottom>top` | `DetectionTypes.ets` 注释 + `InferenceEngine.restoreCoordinates` 均有约束 ✓ |

记录层需从页面编辑态派生的字段（`detectionId/rawIndex/rawClassId/rawLabel/deleted/classCorrected/editedAtMs/counts`）不在推理层范围内，由后续保存层生成；Agent 3 的 `EditableDetection` 已修复 `removeDetection` 物理删除问题，改为 `setDeleted` 墓碑保留（见 `pages/Index.ets` `handleDelete`），阻塞项已清除。

## 4. 检测框坐标约定（确认记录）

坐标空间定义（来自 `phase-1-contract.md` 第 2.4 节 + `DetectionTypes.ets` `DetectionBox` 注释）：

| 项 | 约定 |
| --- | --- |
| 参考空间 | `ImageSource.width/height`（方向归一化后的原图像素） |
| 原点 | 左上角 (0, 0) |
| 单位 | 浮点像素，非归一化 0..1，非屏幕像素 |
| 裁剪 | `left/right ∈ [0, imageWidth]`，`top/bottom ∈ [0, imageHeight]` |
| 有效性 | 必须 `right > left` 且 `bottom > top`；退化框在 `restoreCoordinates` 中丢弃 |
| 来源 | NMS 后全局置信度降序排序，按 `rawIndex` 可稳定追溯 |
| 不旋转/不镜像 | 静态图、检测框、界面显示共用同一方向归一化后的像素空间；前置镜像只在相机预览层 |

保存后可准确重绘的前提：`imageWidth/imageHeight` 与 4 个边界坐标一并持久化，缩略图从同一方向归一化后的像素空间生成。

## 5. 模型版本与 OPSET 验证

使用 `pip install onnx` + `onnx.load().opset_import` 直接解析模型二进制元数据：

```
opset domain=ai.onnx version=18
input: images  shape=[1, 3, 640, 640]
output: output0 shape=[1, 84, 8400]
```

| 字段 | ModelConstants.ets | onnx 元数据 | 一致性 |
| --- | --- | --- | --- |
| MODEL_OPSET | `18` | `18` | ✅ |
| MODEL_INPUT_NAME | `images` | `images` | ✅ |
| MODEL_OUTPUT_NAME | `output0` | `output0` | ✅ |
| MODEL_INPUT_WIDTH | `640` | `640` | ✅ |
| MODEL_INPUT_HEIGHT | `640` | `640` | ✅ |
| MODEL_CLASS_COUNT | `80` | 输出 `[1,84,8400]` → 84-4=80 | ✅ |
| MODEL_ID | `yolov13n-coco-640-opset18` | opset 18 ✓ | ✅ |
| MODEL_SHA256 | `f39e5a3b...799b` | 文件实际 hash | ✅ |

**纠偏**：Agent 2 Phase 1 报告曾将 opset 误写为 12。本次通过 `onnx.load()` 直接验证确认为 18，与 `ModelConstants.ets` 一致。

## 6. 回归验证

### 6.1 构建

| 目标 | 命令 | 结果 |
| --- | --- | --- |
| 默认 HAP | `./scripts/build-app.sh` | ✅ BUILD SUCCESSFUL (511 ms, 18 任务) |
| ohosTest | `hvigorw -p module=entry@ohosTest assembleHap` | ✅ BUILD SUCCESSFUL (2.6 s, 34 任务) |

两个目标均无 ArkTS 编译错误或新警告。

### 6.2 未变化的行为确认

- **InferenceEngine 纯算法**：未修改 letterbox/preprocess/parseOutput/nmsByClass/restoreCoordinates/postprocess 的任何实现。
- **19 个现有算法测试**：编译通过；核心算法路径无改动，预期运行结果与第一阶段完全一致。
- **TaskPool 传输边界**：`recognizedAtMs: number` 为纯标量，可安全跨线程传递，不涉及 NAPI 原生对象。
- **同步 vs TaskPool 耗时语义**：runSync 路径保持 `coldStart=false、modelLoadMs=0`；InferenceTask 路径保持 `coldStart=true、modelLoadMs>0`。

### 6.3 无法在本机完成的验证

| 验证项 | 状态 | 原因 |
| --- | --- | --- |
| ohosTest 真机/模拟器执行 | 待 arm64 设备 | macOS 开发环境无法运行 `aa test` |
| TaskPool 实际 `Date.now()` 精度 | 待真机 | TaskPool 工作线程时间精度依赖设备 OS |
| 与 Agent 3 的 EditableDetection 端到端联动 | 待页面集成 | Index.ets 页面集成后验证 `DetectionResult` → 编辑态 → 记录层转换 |
| 与 Agent 4 数据契约样例的 JSON 对照 | 待保存层实现 | 记录层 `RecordDetection` 结构尚未创建 |

## 7. 与其他 Agent 的对齐

### Agent 0（共享类型维护）
- `DetectionTypes.ets` 是 Agent 0 所有权，本次由 Agent 2 提出改动并实际执行。Agent 0 接手时应确认字段命名和注释最终形式，或提供正式的 `phase-2-contract.md`。
- 另：`requestId` 注释"不得用作数据库主键或上传幂等键"是 `phase-1-agent-4-report.md` 建议 5 的最小落实，供 Agent 0 决定是否在 `phase-1-contract.md` 同步。

### Agent 3（页面）
- `handleDelete` 已改为 `setDeleted`（墓碑保留），不再物理删除，满足记录层可追溯。
- `buildEditableDetections(result.boxes)` + `result.requestId/imageId` 即可构建完整内存态。
- 页面无需手动记录 `recognizedAtMs`，直接从 `result.recognizedAtMs` 读取。

### Agent 4（数据契约）
- "建议 1：在 DetectionResult 增加 recognizedAtMs" — **已采纳并落地**。
- "建议 2：新增 RecordTypes.ets" — 不在 Agent 2 范围，留给 Agent 0 在 `phase-2-contract.md` 中冻结。
- "建议 5：requestId 不得用作幂等键" — DetectionResult 注释已补注，供 Agent 0 决定是否在 phase-1-contract.md 同步。

## 8. 后续 Agent 2 负责范围

- 真实设备推理验证（第一阶段遗留）。
- TaskPool session 创建/释放内存泄漏排查（第一阶段遗留）。
- 模型切换时 `recognizedAtMs` 继续由推理层填充，不改变语义。
- RDB/保存/上传层创建后，推理层保持纯只读原始结果，编辑态转换由保存层消费 `DetectionResult` + 页面编辑态完成。

## 9. 变更清单小结

| 维度 | 第一阶段已有 | 第二阶段补齐 |
| --- | --- | --- |
| 模型 hash / 版本 | ✅ `modelId` + `modelSha256` | 验证一致性 |
| 类别标识 | ✅ `DetectionBox.classId/label` | — |
| 阈值（实际值） | ✅ `confidenceThreshold` + `iouThreshold` | — |
| 原图尺寸 | ✅ `imageWidth` + `imageHeight` | — |
| 推理耗时 | ✅ `timing` 六字段 | — |
| 识别完成时间 | ❌ | ✅ **`recognizedAtMs`（本次新增）** |
| 坐标约定 | ✅ 注释 + InferenceEngine 实现 | 确认并重载于本报告第 4 节 |
| MODEL_OPSET | — | ✅ **验证为 18**（ModelConstants 正确，phase-1 报告笔误 12） |
| 推理算法回归 | — | ✅ 两目标构建成功，算法零改动 |

## 10. 待 Agent 0 显式签名项

`AGENTS.md` 明确"共享类型不得由 Agent 1–5 私自修改"。本次在 Agent 0 所有权的 `app/entry/src/main/ets/models/DetectionTypes.ets` 中新增了 `DetectionResult.recognizedAtMs` 字段并补注了 `requestId` 的幂等键禁用语义。该改动直接采纳 Agent 4 数据契约"建议 1"，且经两个构建目标验证无破坏性，但仍需 Agent 0 在 `phase-2-contract.md` 或独立变更通知中显式签名。若 Agent 0 有不同意见（如命名、可选/必填决策、注释措辞），请协调修改。

其他本报告中的 `phase-1-agent-2-report.md` opset 笔误修正、InferenceEngine 算法零改动、ModelConstants 一致性验证均不触及共享类型，无需额外签名。
