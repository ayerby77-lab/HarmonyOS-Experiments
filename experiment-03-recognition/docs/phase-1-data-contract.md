# 第一阶段数据契约：识别记录、检测项与端云边界

> 负责人：Agent 4（数据与端云协同）。状态：**提案**，共享 ArkTS 类型部分待 Agent 0 整合进 [`docs/phase-1-contract.md`](phase-1-contract.md)。
> 本阶段只定义数据约定，不实现 RDB、JWT、HTTP 上传或云端查询。第一阶段业务仍然只做离线识别与页面内编辑。
> 配套文档：[`docs/phase-1-contract.md`](phase-1-contract.md)、[`docs/phase-1-model.md`](phase-1-model.md)、[`docs/api-plan.md`](api-plan.md)。

## 1. 范围与数据流

本契约回答四个问题：

1. 一次识别、一次保存、一个检测项分别用什么标识。
2. 原始模型结果和用户编辑结果如何同时保留且不互相污染。
3. 记录里的时间、尺寸、缩略图、模型版本、阈值和耗时分别是什么语义、类型和单位。
4. 哪些字段第一阶段就有，哪些要等到本地保存或上传阶段才生成；后续 RDB 和幂等上传至少需要哪些字段。

数据流：

```text
ImageSource（Agent 1）
  imageId / 方向归一化像素 / capturedAtMs
        |
        v
DetectionResult（Agent 2，原始模型结果，不可变）
  requestId / boxes / timing / options / modelId / modelSha256
        |
        v
页面编辑态（Agent 3，内存）
  原始框 + 类别修正 + 删除标记 + 分类计数
        |
        | 第一阶段到此为止：不落库、不上传
        v
[后续] 本地保存：生成 recordId、detectionId、缩略图引用，写入 RDB
        |
        v
[后续] 幂等上传：以 recordId 为幂等键，批量提交记录快照
```

## 2. 标识策略

### 2.1 三类标识

| 标识 | 生成方 | 生成时机 | 唯一性 | 生命周期 | 是否持久化 | 用途 |
| --- | --- | --- | --- | --- | --- | --- |
| `requestId` | 页面/调用方（Agent 3） | 每次调用 `recognize` 前 | 应用会话内唯一即可，建议 `req-<毫秒>-<递增序号>` | 单次识别尝试；阈值变化、切换图片、重新识别都会产生新值 | 第一阶段不持久化；保存时仅作为诊断字段 | 丢弃过期结果，防止旧请求覆盖新页面 |
| `imageId` | 采集层（Agent 1） | 每次拍照/选图成功时 | 一次采集一个；由 Agent 1 保证 | 直到图片被替换或页面销毁 | 随记录保存，作为诊断关联 | 把记录与具体输入图片关联 |
| `recordId` | 保存层（后续） | 第一次成功保存前生成 | 全局唯一，推荐 UUID v4 | 永久；一条已保存记录从生成到删除都不改变 | 是，RDB 主键 | 记录主键、上传幂等键、云端定位 |
| `detectionId` | 保存层（后续） | 保存时按原始框下标生成 | 记录内唯一，推荐全局唯一 | 记录生命周期内不变；删除误检也不删除该 ID | 是，RDB 主键 | 单项编辑、云端单项追溯、幂等重传 |
| `deviceId`（后续） | 应用首次启动 | 首次启动时 | 安装实例唯一 | 卸载重装后变化 | 是，应用偏好设置 | 鉴权主体、服务端记录归属 |
| `serverRevision`（后续） | 服务端 | 首次上传成功后 | 服务端定义，不透明 | 服务端更新时变化 | 是，本地同步元数据 | 冲突检测与增量同步 |

### 2.2 强制规则

1. **`requestId` 不是记录主键，也不是幂等键。** 它只解决“这次异步结果是否还属于当前页面”。同一次识别被取消、被替换或阈值重跑都会产生新 `requestId`，不能用于数据库唯一约束。
2. **`recordId` 必须在离线状态下由客户端生成。** 不能等上传成功后再由服务端分配主键，否则断网时无法建立稳定身份，也无法安全重传。
3. **一次保存操作生成一个 `recordId`。** 保存失败后重试必须复用同一个 `recordId` 和同一份载荷；用户对同一结果再次点击保存，视为新记录，必须生成新 `recordId`。界面应避免无提示地重复保存。
4. **`detectionId` 建议采用确定性格式：`<recordId>:d<rawIndex>`。** `rawIndex` 是该框在 `DetectionResult.boxes` 中的下标（按置信度降序、NMS 后的稳定顺序，从 0 开始）。这样重传时 ID 稳定，服务端可以直接 upsert，不需要客户端保存另一套随机 ID 映射。
5. **删除误检不删除 `detectionId`。** 记录中保留该项并置 `deleted=true`，以保留“模型原本检出了什么”的证据；最终视图和分类计数排除它。
6. **标识按不透明字符串处理。** 除 `detectionId` 的文档化格式外，任何业务逻辑不得解析 ID 内部结构；长度上限建议 `recordId` ≤ 64 字符、`detectionId` ≤ 96 字符。
7. **`imageId` 与 `recordId` 不是一对一。** 同一张图片可以用不同阈值识别多次，但只有用户选择保存的那一次结果进入记录；第一阶段的记录与已保存结果一一对应。

## 3. 记录结构

### 3.1 顶层字段

| 字段 | 类型 | 单位/取值 | 必填 | 产生阶段 | 语义 |
| --- | --- | --- | --- | --- | --- |
| `schemaVersion` | integer | `1` | 保存/上传 | 保存 | 记录结构版本；结构不兼容变更时递增 |
| `recordId` | string | UUID v4，小写 | 保存/上传 | 保存 | 记录唯一标识与幂等键 |
| `requestId` | string | 不透明字符串 | 是 | 第一阶段 | 该结果对应的识别尝试；仅诊断/追溯 |
| `imageId` | string | 不透明字符串 | 是 | 第一阶段 | 输入图片标识；仅追溯 |
| `capturedAtMs` | integer | Unix 毫秒 | 是 | 第一阶段 | 拍照完成或相册图片解码完成的时间 |
| `recognizedAtMs` | integer | Unix 毫秒 | 是 | 第一阶段 | 识别结果返回调用方的时间；不是耗时 |
| `savedAtMs` | integer | Unix 毫秒 | 保存/上传 | 保存 | 本地记录创建完成的时间 |
| `editedAtMs` | integer \| null | Unix 毫秒 | 是 | 第一阶段/保存 | 最后一次编辑时间；未编辑为 `null` |
| `imageWidth` | integer | 像素，> 0 | 是 | 第一阶段 | 方向归一化后的原图宽，也是检测框坐标空间宽 |
| `imageHeight` | integer | 像素，> 0 | 是 | 第一阶段 | 方向归一化后的原图高，也是检测框坐标空间高 |
| `isMirrored` | boolean | `true`/`false` | 是 | 第一阶段 | 像素是否已水平镜像；第一阶段静态图恒为 `false` |
| `imageOrigin` | string | `camera` / `gallery` | 是 | 第一阶段 | 图片来源 |
| `thumbnail` | object | 见 3.2 | 保存时必填 | 保存 | 本地缩略图引用；上传载荷不含本地路径，缩略图二进制通道后续定义 |
| `imagePath` | string \| null | 沙箱相对路径 | 否 | 保存 | 可选的原图副本；第一阶段和最小保存方案不要求 |
| `model` | object | 见 3.3 | 是 | 第一阶段 | 产生该结果的模型版本与完整性信息 |
| `options` | object | 见 3.4 | 是 | 第一阶段 | 本次结果实际使用的推理参数 |
| `timing` | object | 见 3.5 | 是 | 第一阶段 | 本次识别的分段耗时 |
| `rawDetectionCount` | integer | ≥ 0 | 保存/上传 | 保存（第一阶段可派生） | 原始模型框数量；第一阶段恒等于 `detections.length` |
| `edited` | boolean | `true`/`false` | 保存/上传 | 第一阶段可派生 | 是否存在类别修正或删除 |
| `detections` | array | 见 3.6 | 是 | 第一阶段/保存 | 全部检测项，包含已删除项；按 `rawIndex` 升序 |
| `counts` | array | 见 3.7 | 保存/上传 | 第一阶段可派生 | 最终分类计数快照；服务端应重新计算校验 |

时间语义：

- 所有时间戳都是 **Unix epoch 毫秒（UTC 绝对时间）**，JSON 中用整数，ArkTS/RDB 中用 `number`/`INTEGER`。界面按设备本地时区展示，不改写存储值。
- `capturedAtMs` 来自 `ImageSource.capturedAtMs`；`recognizedAtMs` 是识别 Promise 完成并被页面接受的时间；`savedAtMs` 是记录事务提交前的时间。
- 正常时钟下应满足 `capturedAtMs ≤ recognizedAtMs ≤ savedAtMs`，但系统时钟回拨时不得因此拒绝上传，只记录诊断日志。
- **耗时用 `timing.*Ms` 表示，不能用时间戳相减代替。** 时间戳包含排队、渲染和用户操作延迟，不代表推理耗时。

### 3.2 `thumbnail`

| 字段 | 类型 | 单位 | 必填 | 语义 |
| --- | --- | --- | --- | --- |
| `relativePath` | string | 沙箱相对路径 | 是 | 相对应用 `filesDir`，如 `records/<recordId>/thumb.jpg`；禁止绝对路径、`..` 和外部 URI |
| `width` | integer | 像素 | 是 | 缩略图像素宽，> 0 |
| `height` | integer | 像素 | 是 | 缩略图像素高，> 0 |
| `format` | string | `jpeg` / `png` | 是 | 建议 `jpeg`；第一阶段只要求可解码 |
| `byteSize` | integer | 字节 | 是 | 文件大小，> 0 |

缩略图约束：

- 缩略图必须来自**方向归一化后的同一像素空间**。若 `isMirrored=true`，缩略图也必须采用同样的镜像，保证框与图对齐。
- 建议最长边 320 px、JPEG 质量 80；这是保存层实现参数，不是模型输入，也不得改变 `imageWidth/imageHeight`。
- `thumbnail` 是保存记录的必填项。生成或写入失败时不得插入“有记录无缩略图”的半成品记录。
- 本地路径不进入上传载荷的字段语义；后续如需上传缩略图，由独立二进制通道处理。

### 3.3 `model`

| 字段 | 类型 | 必填 | 语义 |
| --- | --- | --- | --- |
| `modelId` | string | 是 | 模型语义版本标识，第一阶段为 `yolov13n-coco-640-opset18`，与 `MODEL_INFO.modelId` 一致 |
| `sha256` | string | 是 | 模型文件 SHA-256，64 位小写十六进制，与 `DetectionResult.modelSha256` 一致 |

- 第一阶段**不引入独立的 `modelVersion` 字段**，避免与 `modelId` 重复。云端“最新模型版本”返回的版本标识也应能映射到 `modelId`；真正的文件完整性始终以 `sha256` 为准。
- 记录保存当时的 `label` 快照，因此后续模型类别表变化不会改变历史记录的可读性；`classId` 的解释以该记录的 `modelId/sha256` 为准。
- 模型输入尺寸、opset、类别数由模型注册表按 `modelId` 解析，最小记录不重复存储。

### 3.4 `options`

| 字段 | 类型 | 取值范围 | 语义 |
| --- | --- | --- | --- |
| `confidenceThreshold` | number | `(0, 1]` | 本次结果实际使用的置信度阈值；过滤发生在 NMS 之前 |
| `iouThreshold` | number | `(0, 1]` | 本次结果实际使用的按类别 NMS IoU 阈值 |
| `maxDetections` | integer | `1..300` | NMS 后最多保留的框数 |
| `executionMode` | string | `sync` / `taskpool` | 本次执行方式 |

- 阈值和 `executionMode` 必须记录**实际使用值**，不能记录页面当前控件值或默认值。
- `edited` 不改变 `options`；用户修正类别或删除项不会重新推理，也不会改变阈值。
- 改变阈值会重新识别，产生新的 `requestId` 和新原始结果；旧结果及其编辑不得合并进新记录。

### 3.5 `timing`

| 字段 | 类型 | 单位 | 语义 |
| --- | --- | --- | --- |
| `preprocessMs` | number | 毫秒 | 颜色转换、letterbox、归一化、NCHW 拷贝 |
| `inferenceMs` | number | 毫秒 | `OnnxSession.Run` 前后墙钟时间 |
| `postprocessMs` | number | 毫秒 | 解码、阈值过滤、NMS、逆变换和裁剪 |
| `totalMs` | number | 毫秒 | 端到端耗时；冷启动时包含 `modelLoadMs` |
| `coldStart` | boolean | - | 本次是否新建 ONNX session |
| `modelLoadMs` | number | 毫秒 | 新建 session 耗时；复用为 0 |

约束：

- 所有耗时 ≥ 0，允许小数；RDB 用 `REAL`，JSON 用 `number`。展示层可四舍五入，但持久化保留原始精度。
- 热启动时通常有 `totalMs ≈ preprocessMs + inferenceMs + postprocessMs`，差额是调度开销；冷启动时 `totalMs` 包含 `modelLoadMs`，不能用三段之和反推。
- 记录直接复制 `DetectionResult.timing`，不得重新计算或覆盖。
- 后续如需统计性能，应分别聚合三段耗时与 `totalMs`，并单列冷启动样本。

### 3.6 `detections` 项

数组包含**全部原始模型框**，包括用户删除的项；顺序按 `rawIndex` 升序。第一阶段满足：

```text
detections.length == rawDetectionCount
detections[i].rawIndex == i
```

| 字段 | 类型 | 单位/取值 | 语义 |
| --- | --- | --- | --- |
| `detectionId` | string | `<recordId>:d<rawIndex>` | 记录内唯一、删除后仍保留 |
| `rawIndex` | integer | `0..rawDetectionCount-1` | 在原始 `DetectionResult.boxes` 中的下标 |
| `rawClassId` | integer | `0..79` | 模型原始类别 ID，不可变 |
| `rawLabel` | string | COCO 英文类名 | 模型原始类别名，不可变 |
| `classId` | integer | `0..79` | 当前最终类别 ID；未修正时等于 `rawClassId` |
| `label` | string | COCO 英文类名 | 当前最终类别名；由 `classId` 对应类表生成，不存中文翻译 |
| `confidence` | number | `0..1` | 模型对 **`rawClassId`** 的置信度；修正类别后仍保留原值 |
| `left/top/right/bottom` | number | 原图像素，浮点 | 检测框坐标；第一阶段编辑不移动、不缩放 |
| `deleted` | boolean | - | 用户是否删除该误检；删除项不展示、不计数 |
| `classCorrected` | boolean | - | `classId != rawClassId`；用于统计修正率 |
| `editedAtMs` | integer \| null | Unix 毫秒 | 该项最后一次被修正或删除的时间；未编辑为 `null` |

检测项约束：

- 坐标空间与 `ImageSource`、`DetectionResult` 完全一致：方向归一化后的原图像素，原点左上，`left < right`、`top < bottom`，且裁剪到 `[0, imageWidth] × [0, imageHeight]`。
- `label` 必须是该模型类别表中 `classId` 的名字。类别修正只能改 `classId/label`；`confidence` 保持模型对原始类别的置信度，界面应提示“已修正”，不能把该置信度解释为最终类别的正确概率。
- 删除项保留原始类别；若删除前已修正，最终类别字段可保留修正值，但计数仍排除该项。
- 第一阶段只允许“修正类别”和“删除/恢复误检”，不允许新增框、拖拽框或修改置信度。未来若支持，必须新增来源字段并升级 `schemaVersion`。

### 3.7 `counts`

| 字段 | 类型 | 语义 |
| --- | --- | --- |
| `classId` | integer | 最终类别 ID |
| `label` | string | 最终类别名 |
| `count` | integer | 该类别下 `deleted=false` 的检测项数量，> 0 |

计数规则：

1. 最终计数按 `detections` 中 `deleted=false` 的项，以 `classId` 分组。
2. `counts` 按 `count` 降序、`classId` 升序排列；同一 `classId` 只能出现一次。
3. `sum(counts[].count) == detections.filter(d => !d.deleted).length`。
4. 空结果或全部删除时 `counts=[]`。
5. 原始计数可由 `detections` 按 `rawClassId` 分组（包含已删除项）随时重建，不单独持久化。
6. 页面不得维护独立的可变计数器；每次修正/删除后都从同一 `detections` 状态重算，避免框、列表、计数三者漂移。
7. 服务端统计以服务端根据 `detections` 重算的最终计数为准，客户端 `counts` 仅作校验和展示快照。

## 4. 原始结果与编辑结果的关系

### 4.1 不可变原始结果

- `DetectionResult.boxes` 是识别完成瞬间的原始模型结果，页面接收后视为**只读**。契约 [`phase-1-contract.md`](phase-1-contract.md) 已要求编辑只修改页面副本。
- 记录中的 `rawClassId/rawLabel/confidence/left/top/right/bottom/rawIndex` 均来自原始结果，保存后不可变。
- 原始结果可完全重建：把 `detections` 按 `rawIndex` 排序，读取原始类别、置信度和几何字段，即得到原始框集合；原始分类计数按 `rawClassId` 分组得到。
- 原始结果不因用户修正或删除而丢失，这是后续统计“模型准确率/人工修正率”的基础。

### 4.2 编辑操作

第一阶段的编辑只有两类，均在保存前完成：

| 操作 | 写入字段 | 计数影响 | 可追溯信息 |
| --- | --- | --- | --- |
| 修正类别 | `classId`、`label`、`classCorrected=true`、`editedAtMs` | 从旧类别计数减 1，新类别加 1 | `rawClassId/rawLabel` 保留原值 |
| 删除误检 | `deleted=true`、`editedAtMs` | 该类别计数减 1 | 项本身、原始类别与框均保留 |
| 恢复误检（保存前） | `deleted=false`、`editedAtMs` | 重新计入当前类别 | 仍保留原始类别与修正历史字段 |
| 恢复原始类别（保存前） | `classId/rawLabel` 同步回原始值、`classCorrected=false` | 计数回到原始类别 | 原始值未丢失 |

编辑状态一致性：

- `edited = 任一 detection.classCorrected || 任一 detection.deleted`。
- `editedAtMs`：未编辑为 `null`；否则取所有已编辑项中最新的 `editedAtMs`。
- 重新识别（切换图片、改变阈值、改变执行模式）会得到新原始结果和新 `requestId`，**必须清空旧编辑状态**；不得把旧删除/修正套到新框上。
- 空结果分两种：
  - 模型空结果：`rawDetectionCount=0`、`detections=[]`、`edited=false`；
  - 编辑后清空：`rawDetectionCount>0`、`detections` 全部 `deleted=true`、`edited=true`、`counts=[]`。
  两者可通过 `rawDetectionCount` 和 `deleted` 区分，不能只用一个“空”标志。

### 4.3 保存后修改

第一阶段不做保存后编辑。后续阶段遵循：

- 记录尚未上传（`sync_state=pending`）时，用户修改可在同一 `recordId` 下更新载荷，并保持 `detectionId` 不变。
- 记录已上传后，**不得原地改写已上传内容**。需要修改时生成新 `recordId` 和新版本记录，或在后续阶段引入显式版本协商；否则幂等键会指向不同内容，导致服务端冲突。
- 任何情况下都不得复用 `recordId` 表示另一张图片或另一次识别。

## 5. JSON 样例

以下样例是**保存后/上传前的记录快照**，因此包含 `recordId`、`detectionId`、`savedAtMs` 和 `thumbnail`。第一阶段内存态还没有这些字段，见第 8 节。数值仅用于说明结构。

### 5.1 正常结果（未编辑）

```json
{
  "schemaVersion": 1,
  "recordId": "5d0f6b9e-2c1a-4e8b-9f7d-3a6c2b8e4f10",
  "requestId": "req-1792630992345-003",
  "imageId": "img-1792630992345-01",
  "capturedAtMs": 1792630992345,
  "recognizedAtMs": 1792631000781,
  "savedAtMs": 1792631004000,
  "editedAtMs": null,
  "imageWidth": 810,
  "imageHeight": 1080,
  "isMirrored": false,
  "imageOrigin": "gallery",
  "thumbnail": {
    "relativePath": "records/5d0f6b9e-2c1a-4e8b-9f7d-3a6c2b8e4f10/thumb.jpg",
    "width": 240,
    "height": 320,
    "format": "jpeg",
    "byteSize": 18422
  },
  "imagePath": null,
  "model": {
    "modelId": "yolov13n-coco-640-opset18",
    "sha256": "f39e5a3b1763423b1e60769e81b08a5da012677dce0248f4b4a95c5ad5cb799b"
  },
  "options": {
    "confidenceThreshold": 0.25,
    "iouThreshold": 0.7,
    "maxDetections": 300,
    "executionMode": "taskpool"
  },
  "timing": {
    "preprocessMs": 18.4,
    "inferenceMs": 126.7,
    "postprocessMs": 9.2,
    "totalMs": 154.3,
    "coldStart": false,
    "modelLoadMs": 0
  },
  "rawDetectionCount": 3,
  "edited": false,
  "detections": [
    {
      "detectionId": "5d0f6b9e-2c1a-4e8b-9f7d-3a6c2b8e4f10:d0",
      "rawIndex": 0,
      "rawClassId": 41,
      "rawLabel": "cup",
      "classId": 41,
      "label": "cup",
      "confidence": 0.9123,
      "left": 101.4,
      "top": 220.8,
      "right": 288.6,
      "bottom": 402.1,
      "deleted": false,
      "classCorrected": false,
      "editedAtMs": null
    },
    {
      "detectionId": "5d0f6b9e-2c1a-4e8b-9f7d-3a6c2b8e4f10:d1",
      "rawIndex": 1,
      "rawClassId": 41,
      "rawLabel": "cup",
      "classId": 41,
      "label": "cup",
      "confidence": 0.8741,
      "left": 430.2,
      "top": 190.5,
      "right": 601.7,
      "bottom": 379.4,
      "deleted": false,
      "classCorrected": false,
      "editedAtMs": null
    },
    {
      "detectionId": "5d0f6b9e-2c1a-4e8b-9f7d-3a6c2b8e4f10:d2",
      "rawIndex": 2,
      "rawClassId": 67,
      "rawLabel": "cell phone",
      "classId": 67,
      "label": "cell phone",
      "confidence": 0.8034,
      "left": 355.6,
      "top": 620.2,
      "right": 402.8,
      "bottom": 760.9,
      "deleted": false,
      "classCorrected": false,
      "editedAtMs": null
    }
  ],
  "counts": [
    {
      "classId": 41,
      "label": "cup",
      "count": 2
    },
    {
      "classId": 67,
      "label": "cell phone",
      "count": 1
    }
  ]
}
```

### 5.2 空结果

```json
{
  "schemaVersion": 1,
  "recordId": "a3b1c7d2-8e4f-4a6b-b2c9-7d5e1f0a6c33",
  "requestId": "req-1792635302114-001",
  "imageId": "img-1792635302114-02",
  "capturedAtMs": 1792635302114,
  "recognizedAtMs": 1792635302903,
  "savedAtMs": 1792635305200,
  "editedAtMs": null,
  "imageWidth": 810,
  "imageHeight": 1080,
  "isMirrored": false,
  "imageOrigin": "gallery",
  "thumbnail": {
    "relativePath": "records/a3b1c7d2-8e4f-4a6b-b2c9-7d5e1f0a6c33/thumb.jpg",
    "width": 240,
    "height": 320,
    "format": "jpeg",
    "byteSize": 15907
  },
  "imagePath": null,
  "model": {
    "modelId": "yolov13n-coco-640-opset18",
    "sha256": "f39e5a3b1763423b1e60769e81b08a5da012677dce0248f4b4a95c5ad5cb799b"
  },
  "options": {
    "confidenceThreshold": 0.25,
    "iouThreshold": 0.7,
    "maxDetections": 300,
    "executionMode": "taskpool"
  },
  "timing": {
    "preprocessMs": 12.1,
    "inferenceMs": 76.8,
    "postprocessMs": 7.3,
    "totalMs": 96.2,
    "coldStart": false,
    "modelLoadMs": 0
  },
  "rawDetectionCount": 0,
  "edited": false,
  "detections": [],
  "counts": []
}
```

### 5.3 编辑后结果（删除一项、修正一项）

原始结果有 4 项：3 个 `cup`、1 个误检 `chair`。用户删除 `chair`，并把一个 `cup` 修正为 `bottle`。

```json
{
  "schemaVersion": 1,
  "recordId": "c8e4f1a2-6b3d-4f7e-8a1c-2d9e5b7f0c64",
  "requestId": "req-1792635761507-002",
  "imageId": "img-1792635761507-03",
  "capturedAtMs": 1792635761507,
  "recognizedAtMs": 1792635762066,
  "savedAtMs": 1792635768900,
  "editedAtMs": 1792635767777,
  "imageWidth": 1080,
  "imageHeight": 810,
  "isMirrored": false,
  "imageOrigin": "camera",
  "thumbnail": {
    "relativePath": "records/c8e4f1a2-6b3d-4f7e-8a1c-2d9e5b7f0c64/thumb.jpg",
    "width": 320,
    "height": 240,
    "format": "jpeg",
    "byteSize": 21045
  },
  "imagePath": null,
  "model": {
    "modelId": "yolov13n-coco-640-opset18",
    "sha256": "f39e5a3b1763423b1e60769e81b08a5da012677dce0248f4b4a95c5ad5cb799b"
  },
  "options": {
    "confidenceThreshold": 0.25,
    "iouThreshold": 0.7,
    "maxDetections": 300,
    "executionMode": "taskpool"
  },
  "timing": {
    "preprocessMs": 16.9,
    "inferenceMs": 118.4,
    "postprocessMs": 10.1,
    "totalMs": 145.4,
    "coldStart": false,
    "modelLoadMs": 0
  },
  "rawDetectionCount": 4,
  "edited": true,
  "detections": [
    {
      "detectionId": "c8e4f1a2-6b3d-4f7e-8a1c-2d9e5b7f0c64:d0",
      "rawIndex": 0,
      "rawClassId": 41,
      "rawLabel": "cup",
      "classId": 41,
      "label": "cup",
      "confidence": 0.931,
      "left": 96.2,
      "top": 210.4,
      "right": 240.8,
      "bottom": 398.6,
      "deleted": false,
      "classCorrected": false,
      "editedAtMs": null
    },
    {
      "detectionId": "c8e4f1a2-6b3d-4f7e-8a1c-2d9e5b7f0c64:d1",
      "rawIndex": 1,
      "rawClassId": 41,
      "rawLabel": "cup",
      "classId": 41,
      "label": "cup",
      "confidence": 0.8872,
      "left": 410.1,
      "top": 205.7,
      "right": 556.3,
      "bottom": 392.0,
      "deleted": false,
      "classCorrected": false,
      "editedAtMs": null
    },
    {
      "detectionId": "c8e4f1a2-6b3d-4f7e-8a1c-2d9e5b7f0c64:d2",
      "rawIndex": 2,
      "rawClassId": 56,
      "rawLabel": "chair",
      "classId": 56,
      "label": "chair",
      "confidence": 0.6421,
      "left": 702.4,
      "top": 300.5,
      "right": 861.2,
      "bottom": 520.8,
      "deleted": true,
      "classCorrected": false,
      "editedAtMs": 1792635767412
    },
    {
      "detectionId": "c8e4f1a2-6b3d-4f7e-8a1c-2d9e5b7f0c64:d3",
      "rawIndex": 3,
      "rawClassId": 41,
      "rawLabel": "cup",
      "classId": 39,
      "label": "bottle",
      "confidence": 0.5602,
      "left": 250.5,
      "top": 560.1,
      "right": 360.7,
      "bottom": 700.9,
      "deleted": false,
      "classCorrected": true,
      "editedAtMs": 1792635767777
    }
  ],
  "counts": [
    {
      "classId": 41,
      "label": "cup",
      "count": 2
    },
    {
      "classId": 39,
      "label": "bottle",
      "count": 1
    }
  ]
}
```

## 6. 后续 RDB 与缩略图持久化要求

### 6.1 最小表结构

以下仅作为后续阶段的最小字段需求，不在第一阶段创建。字段名使用 snake_case，类型按 SQLite/RDB 习惯。

`records`：

| 列 | 类型 | 约束 | 来源 |
| --- | --- | --- | --- |
| `record_id` | TEXT | PRIMARY KEY | 保存生成 |
| `schema_version` | INTEGER | NOT NULL | 保存 |
| `request_id` | TEXT | NOT NULL | 第一阶段 |
| `image_id` | TEXT | NOT NULL | 第一阶段 |
| `captured_at_ms` | INTEGER | NOT NULL | 第一阶段 |
| `recognized_at_ms` | INTEGER | NOT NULL | 第一阶段 |
| `saved_at_ms` | INTEGER | NOT NULL | 保存 |
| `edited_at_ms` | INTEGER | NULL | 第一阶段/保存 |
| `image_width` | INTEGER | NOT NULL, > 0 | 第一阶段 |
| `image_height` | INTEGER | NOT NULL, > 0 | 第一阶段 |
| `is_mirrored` | INTEGER | NOT NULL, 0/1 | 第一阶段 |
| `image_origin` | TEXT | NOT NULL, `camera`/`gallery` | 第一阶段 |
| `thumbnail_path` | TEXT | NOT NULL | 保存 |
| `image_path` | TEXT | NULL | 保存（可选） |
| `model_id` | TEXT | NOT NULL | 第一阶段 |
| `model_sha256` | TEXT | NOT NULL | 第一阶段 |
| `confidence_threshold` | REAL | NOT NULL | 第一阶段 |
| `iou_threshold` | REAL | NOT NULL | 第一阶段 |
| `max_detections` | INTEGER | NOT NULL | 第一阶段 |
| `execution_mode` | TEXT | NOT NULL | 第一阶段 |
| `preprocess_ms` | REAL | NOT NULL | 第一阶段 |
| `inference_ms` | REAL | NOT NULL | 第一阶段 |
| `postprocess_ms` | REAL | NOT NULL | 第一阶段 |
| `total_ms` | REAL | NOT NULL | 第一阶段 |
| `cold_start` | INTEGER | NOT NULL, 0/1 | 第一阶段 |
| `model_load_ms` | REAL | NOT NULL | 第一阶段 |
| `raw_detection_count` | INTEGER | NOT NULL | 保存（可派生） |
| `edited` | INTEGER | NOT NULL, 0/1 | 保存（可派生） |
| `sync_state` | TEXT | NOT NULL DEFAULT `pending` | 同步层 |
| `upload_attempts` | INTEGER | NOT NULL DEFAULT 0 | 同步层 |
| `next_attempt_at_ms` | INTEGER | NULL | 同步层 |
| `last_error_code` | TEXT | NULL | 同步层 |
| `last_error_at_ms` | INTEGER | NULL | 同步层 |
| `uploaded_at_ms` | INTEGER | NULL | 同步层 |
| `server_revision` | TEXT | NULL | 同步层 |

`detections`：

| 列 | 类型 | 约束 | 来源 |
| --- | --- | --- | --- |
| `detection_id` | TEXT | PRIMARY KEY | 保存生成 |
| `record_id` | TEXT | NOT NULL, 外键 `records(record_id)`，级联删除 | 保存 |
| `raw_index` | INTEGER | NOT NULL, `UNIQUE(record_id, raw_index)` | 第一阶段 |
| `raw_class_id` | INTEGER | NOT NULL | 第一阶段 |
| `raw_label` | TEXT | NOT NULL | 第一阶段 |
| `class_id` | INTEGER | NOT NULL | 编辑/第一阶段 |
| `label` | TEXT | NOT NULL | 编辑/第一阶段 |
| `confidence` | REAL | NOT NULL | 第一阶段 |
| `left` | REAL | NOT NULL | 第一阶段 |
| `top` | REAL | NOT NULL | 第一阶段 |
| `right` | REAL | NOT NULL | 第一阶段 |
| `bottom` | REAL | NOT NULL | 第一阶段 |
| `deleted` | INTEGER | NOT NULL, 0/1 | 编辑 |
| `class_corrected` | INTEGER | NOT NULL, 0/1 | 编辑 |
| `edited_at_ms` | INTEGER | NULL | 编辑 |

索引要求：

- `records(captured_at_ms DESC)`：按时间倒序历史列表。
- `records(recognized_at_ms)`：按识别时间统计。
- `records(sync_state, saved_at_ms)`：待传队列扫描。
- `detections(record_id)`：详情加载。
- `detections(record_id, deleted)`：最终计数。
- `detections(class_id)`：按类别筛选；必要时与 `records` 联合查询。

`counts` 不单独建表。按类别查询时由 `detections` 过滤 `deleted=0` 聚合；若后续出现性能问题，可增加派生缓存表，但必须在同一事务内维护，且服务端仍以明细为权威。

### 6.2 保存事务与文件顺序

1. 页面仍在内存中持有 `ImageSource` 和最终 `detections` 状态；保存开始后不再接受该图片的识别请求。
2. 保存层生成一次 `recordId`，按 `rawIndex` 生成 `detectionId`，生成缩略图到临时目录。
3. 把临时缩略图移动到 `filesDir/records/<recordId>/thumb.jpg`；相对路径写入记录。文件必须关闭后再提交数据库。
4. 开启 RDB 事务，插入 `records` 与全部 `detections`（包括 `deleted=1` 的项），提交。
5. 数据库失败时回滚并删除刚创建的记录目录；重试复用同一 `recordId` 和载荷。
6. 成功提交后释放缩略图生成用的 `PixelMap`/临时缓冲；不得把 `ArrayBuffer` 存入 RDB。
7. 删除记录时先删数据库行（级联删除 `detections`），再删除记录目录；目录缺失不应阻止删除。启动时可扫描无主目录并清理。

一致性要求：

- `detections` 中的项与 `records.raw_detection_count` 必须同一事务写入。
- `edited`、`edited_at_ms`、`counts` 可由明细派生；若缓存，必须与明细同事务。
- 同一 `record_id` 不允许对应不同图片或不同 `requestId`。

### 6.3 图片 URI 生命周期与保存前处理

| 资源 | 来源/生命周期 | 持久化要求 |
| --- | --- | --- |
| 相册选择 URI / 临时读权限 | 由系统选择器授予，通常只在当前会话/有限时间内可读 | **禁止直接持久化**。必须在权限有效期内解码为 `ImageSource`；保存时立即生成本地副本/缩略图 |
| 相机临时文件或缓冲区 | Camera Kit/应用临时目录，重启或清理后可能消失 | 保存时复制到应用沙箱；临时文件由采集层释放 |
| `ImageSource.data`（`ArrayBuffer`） | 页面持有，推理层只读；图片替换后失效 | 不写 RDB、不上传、不跨进程缓存；缩略图生成完成后即可释放 |
| 缩略图文件 | 应用 `filesDir/records/<recordId>/` | 持久化；只存相对路径；随记录删除 |
| 原图副本（可选） | 应用沙箱 | 仅在产品需要时保存；同样使用相对路径 |
| 上传二进制 | 后续独立通道 | 第一阶段不上传；不上传本地绝对路径 |

保存前处理要求：

- 缩略图必须从**方向归一化后**的像素生成；若 `isMirrored=true`，镜像状态必须一致。
- 不在 RDB 中存 BLOB 或 base64 大字段；大图缩放和 JPEG 编码在保存线程执行，避免阻塞 UI。
- 相册 URI 的读取权限可能在页面切换后失效，因此“以后再说”的延迟保存不可靠；若保存时图片已不可用，应提示重新选择，而不是写入无缩略图记录。
- 绝对沙箱路径会随应用数据迁移/备份变化，**记录只保存相对路径**。
- 记录删除、应用清理和异常恢复都必须考虑目录与数据库行的一致性；缺失缩略图视为记录损坏，应在日志和界面中明确提示。

## 7. 幂等上传的最小字段与语义

### 7.1 上传载荷

- 使用第 3 节记录结构，`schemaVersion` 与 `recordId` 必须存在。
- 必传业务字段：`recordId`、`schemaVersion`、`capturedAtMs`、`recognizedAtMs`、`savedAtMs`、`editedAtMs`、`imageWidth`、`imageHeight`、`isMirrored`、`imageOrigin`、`model`、`options`、`timing`、`rawDetectionCount`、`edited`、`detections`、`counts`。
- `requestId`、`imageId` 可传，用于服务端日志和问题定位，但不是服务端主键。
- **不传本地字段**：`thumbnail.relativePath`、`imagePath`、`sync_state`、`upload_attempts`、`next_attempt_at_ms`、`last_error_*`、`uploaded_at_ms`、`server_revision`、绝对路径、设备密钥。
- 缩略图/原图二进制第一阶段不上传；后续通过独立端点或 multipart 通道传输，并与 `recordId` 关联。

### 7.2 幂等规则

1. 服务端以 `(认证设备身份, recordId)` 作为唯一键；第一阶段无鉴权时该接口不开放。
2. 首次收到 `recordId`：创建记录，返回 `created`。
3. 再次收到相同 `recordId` 且规范化载荷相同：返回 `duplicate`/成功，不重复计数、不重复创建明细。
4. 相同 `recordId` 但载荷不同：返回冲突（建议 HTTP 409），不得静默覆盖；客户端应停止重试并记录诊断。
5. 客户端重试必须复用原 `recordId`，不得重新生成；网络错误、超时、5xx 可重试，401 先刷新令牌再重试，409/422 不自动重试。
6. 服务端以自身收到的 `detections` 重算最终计数和统计，不信任客户端 `counts`；但可回传校验差异用于诊断。

### 7.3 本地待传队列最小字段

- 队列直接使用 `records` 表的同步列，不另建不必要的队列表：
  - `sync_state`：`pending`（已保存、等待上传）/ `uploading` / `uploaded` / `blocked`（永久失败，如 409/422）。
  - `upload_attempts`、`next_attempt_at_ms`、`last_error_code`、`last_error_at_ms`、`uploaded_at_ms`、`server_revision`。
- 扫描条件：`sync_state='pending' AND next_attempt_at_ms <= now`，按 `saved_at_ms` 升序取批量。
- 上传中崩溃：启动时把超时的 `uploading` 重置为 `pending`；因为服务端幂等，重复提交安全。
- 批量大小建议 ≤ 50；逐条返回结果，只把确认成功的记录标记为 `uploaded`，失败项保留并更新重试信息。
- 网络恢复/应用启动时触发队列；必须串行或有限并发，避免重复批次同时上传同一记录。

### 7.4 云端记录与统计的最小语义

- 云端记录保留原始类别字段和最终类别字段，才能计算修正率；云端最终计数只统计 `deleted=false` 的项。
- 时间筛选以 `recognizedAtMs` 为主，`capturedAtMs` 为辅；离线补传记录按 `recognizedAtMs` 落入历史。
- 类别筛选以最终 `classId` 为准；原始类别筛选作为后续可选能力。
- 分页必须使用稳定排序（`recognizedAtMs DESC, recordId DESC`），避免同一时间戳下重复/漏项。
- 空结果记录是合法记录，应参与总数统计，但不产生类别计数。

## 8. 第一阶段调用方如何使用

### 8.1 页面（Agent 3）

第一阶段不保存、不上传，但仍应按本契约维护内存状态，保证后续接入保存层时无需重做：

1. 保存最近一次 `DetectionResult` 和对应的 `requestId`、`imageId`，只读使用 `boxes`。
2. 为每个框维护页面编辑状态，至少包含 `rawIndex`、`classId`、`label`、`deleted`、`editedAtMs`；几何与置信度直接引用原始 `boxes`，不要复制后修改。
3. 每次修正/删除后从同一数组重算分类计数，禁止维护独立计数器。
4. 切换图片、改变阈值、改变执行模式或重新识别时，生成新 `requestId` 并清空旧编辑状态。
5. 分类计数、检测框和列表必须来自同一状态源；旧结果只有在 `requestId` 与 `imageId` 都匹配时才可写入。
6. 第一阶段不显示“已保存/已同步”状态，也不生成 `recordId`；`recordId` 只属于保存层。
7. 接收识别结果时记录 `recognizedAtMs = Date.now()`（若 Agent 2 后续在结果中提供该字段，则直接使用服务端返回值）。

### 8.2 推理层（Agent 2）

- 现有 `DetectionResult` 字段已覆盖记录需要的原始结果、耗时、阈值和模型信息。
- `timing` 必须按 [`phase-1-contract.md`](phase-1-contract.md) 第 3 节语义填写，尤其是冷启动 `totalMs`。
- `options.executionMode` 与 `DetectionResult.executionMode` 应一致；记录以 `options.executionMode` 为准。
- 建议在 `DetectionResult` 增加 `recognizedAtMs`（见第 9 节），由服务在结果完成时写入，避免页面等待/调度时间污染识别时间。

### 8.3 保存与同步层（后续）

- 只有保存层生成 `recordId`、`detectionId`、`savedAtMs` 和缩略图引用。
- 保存前必须完成图片到沙箱的复制/缩略图生成；不得持久化相册临时 URI。
- 上传层只消费不可变记录快照；任何已上传内容的修改都走新记录或显式版本协商。
- 第一阶段代码不得提前实现 RDB/HTTP/队列；本节是后续接手边界。

## 9. 与 Agent 0、Agent 2、Agent 3 的对照及整合建议

### 9.1 已核对的实际状态

核对时间：2026-10-22（Asia/Shanghai）。

| 项 | 实际状态 | 与本契约的关系 |
| --- | --- | --- |
| `app/entry/src/main/ets/models/ImageTypes.ets` | 已存在 `ImageSource`，含 `imageId/origin/width/height/pixelFormat/rowStride/data/isMirrored/exifOrientation/capturedAtMs` | 覆盖记录所需的图片来源、时间、尺寸和镜像语义 |
| `app/entry/src/main/ets/models/DetectionTypes.ets` | 已存在 `DetectionBox/DetectionResult/InferenceTiming/InferenceOptions/RecognitionError` 等 | 覆盖原始框、耗时、阈值、模型 ID/hash、执行模式 |
| `app/entry/src/main/ets/models/ModelConstants.ets` | `MODEL_ID`、`MODEL_SHA256` 与 `MODEL_INFO` 已存在 | 与样例中的模型字段一致 |
| `app/entry/src/main/ets/services/camera/` | 仅有 `.gitkeep`，采集层尚未交付 | 相册 URI/相机临时文件生命周期按第 6.3 节约定，待 Agent 1 实现验证 |
| `app/entry/src/main/ets/services/inference/` | 已有 `RecognitionService.ets`、`InferenceEngine.ets`、`ModelLoader.ets`、`OnnxSessionWrapper.ets` 和 `tasks/InferenceTask.ets`；Agent 2 报告尚未生成 | 按实际代码核对了 `DetectionResult` 字段、排序与耗时；运行验证仍待设备 |
| `app/entry/src/main/ets/components/recognition/` | 已有 `EditableDetection.ets`、`BoxGeometry.ets`、`PreviewPixelMap.ets`；`pages/Index.ets` 目前是临时编译探针 | 可核对编辑辅助函数；页面集成与最终行为仍在实现中 |
| `docs/phase-1-agent-2-report.md`、`docs/phase-1-agent-3-report.md` | 尚未生成 | 集成验证需等两位 agent 交付后补做 |

### 9.2 提交给 Agent 0 的整合建议

以下建议只修改 Agent 0 所有的共享类型/契约，不涉及第一阶段业务实现。

**建议 1：在 `DetectionResult` 增加 `recognizedAtMs`。**

```ts
export interface DetectionResult {
  // ...现有字段
  /** 识别完成、即将返回调用方的时间，Unix 毫秒。 */
  recognizedAtMs: number;
}
```

- 由 `RecognitionService.recognize` 在结果完成时写入；页面直接复制。
- 若 Agent 0 暂不采纳，保存层必须使用页面在 Promise 完成时记录的 `Date.now()`，并在文档中注明精度差异。

**建议 2：新增 `app/entry/src/main/ets/models/RecordTypes.ets`（由 Agent 0 创建/维护）。**

建议最小类型如下，字段语义与第 3 节一致：

```ts
import { ImageOrigin } from './ImageTypes';
import { InferenceOptions, InferenceTiming } from './DetectionTypes';

export interface ThumbnailRef {
  relativePath: string;
  width: number;
  height: number;
  format: string;
  byteSize: number;
}

export interface RecordModelRef {
  modelId: string;
  sha256: string;
}

export interface RecordDetection {
  detectionId: string;
  rawIndex: number;
  rawClassId: number;
  rawLabel: string;
  classId: number;
  label: string;
  confidence: number;
  left: number;
  top: number;
  right: number;
  bottom: number;
  deleted: boolean;
  classCorrected: boolean;
  editedAtMs: number | null;
}

export interface ClassCount {
  classId: number;
  label: string;
  count: number;
}

export interface RecordBase {
  schemaVersion: number;
  requestId: string;
  imageId: string;
  capturedAtMs: number;
  recognizedAtMs: number;
  imageWidth: number;
  imageHeight: number;
  isMirrored: boolean;
  imageOrigin: ImageOrigin;
  model: RecordModelRef;
  options: InferenceOptions;
  timing: InferenceTiming;
  rawDetectionCount: number;
  edited: boolean;
  editedAtMs: number | null;
  detections: RecordDetection[];
  counts: ClassCount[];
}

export interface LocalRecord extends RecordBase {
  recordId: string;
  savedAtMs: number;
  thumbnail: ThumbnailRef;
  imagePath?: string | null;
}

export interface UploadRecord extends RecordBase {
  recordId: string;
  savedAtMs: number;
}
```

说明：

- `RecordDetection` 与 `DetectionBox` 的几何字段同名，保存时从原始框复制；原始框本身不改。
- `UploadRecord` 不含缩略图路径、原图路径和同步元数据，避免把本地字段发到服务端。
- 若 Agent 0 认为类型过多，可只冻结 `RecordBase/RecordDetection/ClassCount/ThumbnailRef`，`LocalRecord/UploadRecord` 由保存与网络模块在后续阶段组合；但字段语义不得改变。

**建议 3：在 `docs/phase-1-contract.md` 增加“数据契约”链接**，指向本文件，并在共享类型清单中登记新类型（若采纳建议 2）。

**建议 4：保持现有 `DetectionBox/InferenceOptions` 不变。** 记录层通过 `rawIndex` 与 `DetectionResult.boxes` 对齐，不需要给 `DetectionBox` 增加 ID 或编辑字段，避免影响推理层和 TaskPool 传输。

**建议 5：明确 `requestId` 只用于页面丢弃旧结果。** 现有契约已如此规定，建议在类型注释中补一句“不得用作数据库主键或上传幂等键”。

### 9.3 与 Agent 2 的字段对照

| 记录需要 | Agent 2 现有契约字段 | 结论 |
| --- | --- | --- |
| 原始框几何 | `DetectionBox.left/top/right/bottom` | 直接复制 |
| 原始类别 | `DetectionBox.classId/label` | 直接复制为 `rawClassId/rawLabel` |
| 置信度 | `DetectionBox.confidence` | 直接复制；修正类别后不变 |
| 阈值与模式 | `DetectionResult.confidenceThreshold/iouThreshold/...`、`options` | 使用实际结果值 |
| 分段耗时 | `InferenceTiming` | 直接复制 |
| 模型版本 | `DetectionResult.modelId/modelSha256` | 直接复制 |
| 识别完成时间 | **缺失** | 建议 1；否则页面补记 |
| 空结果 | `boxes=[]` | 生成 `rawDetectionCount=0` 的合法记录 |

已验证：

- `InferenceEngine` 在 NMS 后对保留框做全局置信度降序排序，再截断到 `maxDetections`；因此 `boxes` 的下标可作为稳定的 `rawIndex`。
- `runSync` 的 `timing` 为 `coldStart=false、modelLoadMs=0`；`InferenceTask` 每个任务新建 session，`coldStart=true` 且 `modelLoadMs>0`，`totalMs` 从任务开始计，包含模型加载。
- `DetectionResult` 的 `requestId/imageId/imageWidth/imageHeight/boxes/timing/executionMode/confidenceThreshold/iouThreshold/modelId/modelSha256` 均已填充。

未解决：

- `DetectionResult` 没有 `recognizedAtMs`，同步与 TaskPool 两条路径都未记录完成时间；需采纳建议 1 或由页面补记。
- TaskPool 模式每次都是 `coldStart=true`，性能统计不能把该模式的 `totalMs` 直接与同步模式的复用 session 结果比较；记录层只如实保存，不修正语义。
- Agent 2 尚未提供设备侧真实推理证据与交接报告。

### 9.4 与 Agent 3 的编辑行为对照

| 记录规则 | 对 Agent 3 的要求 | 核对结果（2026-10-22 09:35） |
| --- | --- | --- |
| 原始框只读 | 不修改 `DetectionResult.boxes` | `buildEditableDetections` 复制原始框，符合；页面集成仍待完成 |
| 修正类别 | 只改最终 `classId/label`，保留原类别 | `applyClassChange` 保留 `originalClassId` 和 `confidence`，符合；未记录 `editedAtMs` |
| 删除误检 | 用 `deleted` 标记而非从数组物理删除（保存时） | **不满足**：`removeDetection` 使用 `filter` 直接移除项，丢失被删项的原始框和类别 |
| 计数一致 | 框、列表、计数同源重算 | `countByClass` 从同一数组统计，排序为数量降序、类别升序，符合 |
| 重新识别清空编辑 | 新 `requestId` 对应新原始结果 | 页面尚未集成，待验证 |
| 空结果 | 识别成功但无框，不是错误 | 页面尚未集成，待验证 |

`EditableDetection` 当前字段为 `id/classId/originalClassId/label/confidence/left/top/right/bottom`，缺少 `deleted`、`rawLabel`、`editedAtMs`。删除即物理移除会导致保存层无法重建原始模型结果和修正率，这是接入保存/上传前的**必须修复项**。建议：

1. 页面保留全部原始项，删除只置 `deleted=true`，列表/框/计数过滤显示；或
2. 删除时把被删项移入页面状态中的 `removedItems`，保存时与当前项合并回 `detections` 并补 `deleted=true`。

另外，页面局部 `ClassCount` 与建议的共享 `ClassCount` 同名同形；若 Agent 0 冻结共享类型，Agent 3 应改用共享类型或显式重命名，避免 import 冲突。

## 10. 验证、边界与后续

### 10.1 本阶段验证

- 本文件为数据约定，未新增或修改客户端业务代码、RDB 或网络实现。
- 已按实际代码核对 Agent 2 的 `DetectionResult` 字段、排序和耗时语义，以及 Agent 3 的编辑辅助函数；发现 `removeDetection` 物理删除误检项的接入阻塞（见 9.4）。
- 后端 `GET /health` 与 README、`docs/api-plan.md` 一致，实测返回 `200 {"status":"ok"}`；未改动后端代码。
- JSON 样例已做语法和内部一致性检查（计数、`rawDetectionCount`、`detectionId`）。

### 10.2 后续阶段仍需实现

1. `models/RecordTypes.ets` 共享类型由 Agent 0 冻结。
2. RDB 建表、事务、缩略图生成、目录清理与按时间/类别查询。
3. 设备注册、JWT 获取/刷新、Bearer 鉴权与 401 处理。
4. 本地待传队列、批量上传、`recordId` 幂等、冲突处理、联网重传。
5. 模型版本检查与下载（版本标识需能映射到 `modelId`）。
6. 云端筛选、分页、统计接口与错误码统一。
7. 真机验证相册 URI 生命周期、缩略图生成、离线保存/补传和时钟回拨场景。

### 10.3 版本演进规则

- 新增可选字段不提升 `schemaVersion`；语义改变、字段删除或类型变化必须提升。
- 服务端必须拒绝不支持的更高 `schemaVersion`，客户端不得把新结构伪装成旧版本上传。
- 计数、编辑标记等派生字段的服务端权威性不变：服务端始终能从 `detections` 重建。
