# 第一阶段 Agent 4 交接报告（数据与端云协同）

日期：2026-10-22（Asia/Shanghai）
角色：数据与端云协同负责人（Agent 4）
阶段范围：只建立数据约定与接口准备，不实现 RDB、JWT、HTTP 上传或云端查询；第一阶段仍为离线识别。

## 1. 交付物

| 文件 | 类型 | 说明 |
| --- | --- | --- |
| `docs/phase-1-data-contract.md` | 新增 | 记录/检测项标识、原始与编辑结果关系、字段语义、JSON 样例、RDB 与幂等上传最小要求、Agent 0/2/3 整合建议 |
| `docs/api-plan.md` | 修改 | 补充记录上传、查询、统计、错误响应规划；保留现有接口表与“当前仅实现 /health”的状态 |
| `docs/phase-1-agent-4-report.md` | 新增 | 本报告 |

未修改客户端共享类型、业务代码、后端代码或其他 agent 所有文件。

## 2. 核心约定摘要

### 2.1 标识

| 标识 | 生成时机 | 用途 | 关键约束 |
| --- | --- | --- | --- |
| `requestId` | 每次识别前由页面生成 | 丢弃过期异步结果 | 不是主键、不是幂等键；阈值重跑/切换图片产生新值 |
| `recordId` | 第一次保存前由客户端离线生成 | RDB 主键、上传幂等键 | UUID v4；重试复用，不得重新生成；已上传后不可复用 |
| `detectionId` | 保存时生成 | 单项追溯与幂等 upsert | `<recordId>:d<rawIndex>`；删除项仍保留 |
| `imageId` | 采集时生成 | 输入图片追溯 | 与记录不是一对一 |
| `deviceId`（后续） | 首次启动 | 鉴权主体/归属 | 不进入记录上传业务字段 |

### 2.2 原始结果与编辑结果

- `DetectionResult.boxes` 为只读原始结果；记录中保留全部原始框，包括删除项。
- 记录中的 `detections` 同时保留 `rawClassId/rawLabel` 与最终 `classId/label`；`classCorrected` 标记类别修正，`deleted` 标记误检删除。
- 类别修正不改几何和 `confidence`；`confidence` 始终是模型对原始类别的置信度。
- 删除项保留墓碑，最终视图与计数排除；`rawDetectionCount == detections.length`，`rawIndex` 连续。
- 分类计数从同一 `detections` 状态派生：最终计数按 `deleted=false` 的最终 `classId` 分组，原始计数可按 `rawClassId` 重建。
- 空结果与“编辑后清空”通过 `rawDetectionCount` 和 `deleted` 区分。

### 2.3 字段产生阶段

| 阶段 | 产生的字段 |
| --- | --- |
| 第一阶段（采集/推理/页面内存） | `requestId`、`imageId`、`capturedAtMs`、`imageWidth/imageHeight`、`isMirrored`、`imageOrigin`、原始框、`confidence`、`options`、`timing`、`modelId/sha256`、`recognizedAtMs`（页面记录）、最终类别/删除标记、派生的 `counts` |
| 本地保存（后续） | `recordId`、`detectionId`、`savedAtMs`、`editedAtMs` 最终值、`thumbnail`、`imagePath`（可选）、`schemaVersion`、`rawDetectionCount/edited` 持久化、同步初始状态 |
| 上传/云端（后续） | `uploadedAtMs`、`serverRevision`、重试与错误元数据；服务端重算计数并生成统计 |

## 3. 与 Agent 0/2/3 的对照

### 3.1 实际核对结果

- `models/ImageTypes.ets`、`models/DetectionTypes.ets`、`models/ModelConstants.ets` 已包含记录所需的图像、检测框、阈值、耗时、模型 ID/hash 和执行模式字段。
- `services/inference/` 已有 `RecognitionService.ets`、`InferenceEngine.ets`、`ModelLoader.ets`、`OnnxSessionWrapper.ets` 和 `tasks/InferenceTask.ets`；Agent 2 报告尚未生成。
- `components/recognition/` 已有 `EditableDetection.ets`、`BoxGeometry.ets`、`PreviewPixelMap.ets`；`pages/Index.ets` 目前是临时编译探针，页面集成尚未完成。
- `docs/phase-1-agent-2-report.md`、`docs/phase-1-agent-3-report.md` 尚未生成，最终集成核对需待交付后补做。

### 3.2 提交给 Agent 0 的整合建议

已写入 `docs/phase-1-data-contract.md` 第 9.2 节，未直接修改共享类型：

1. 在 `DetectionResult` 增加必填字段 `recognizedAtMs: number`，由推理服务在结果完成时写入；若不采纳，保存层用页面在 Promise 完成时记录的 `Date.now()`。
2. 新增 `models/RecordTypes.ets`，建议类型为 `ThumbnailRef`、`RecordModelRef`、`RecordDetection`、`ClassCount`、`RecordBase`、`LocalRecord`、`UploadRecord`。
3. 在 `docs/phase-1-contract.md` 登记新类型并链接本数据契约。
4. 保持 `DetectionBox/InferenceOptions` 不变，记录层通过 `rawIndex` 对齐原始框。
5. 在 `requestId` 注释中明确“不得作为数据库主键或上传幂等键”。

### 3.3 与 Agent 2/3 的实际核对

Agent 2（已核对代码）：

- `InferenceEngine` 在按类别 NMS 后做全局置信度降序排序并截断，`boxes` 下标可作为稳定 `rawIndex`，符合。
- `runSync` 的 `timing` 为 `coldStart=false/modelLoadMs=0`；`InferenceTask` 每个 TaskPool 任务新建 session，`coldStart=true/modelLoadMs>0`，`totalMs` 从任务开始计并包含模型加载，符合契约语义。
- `DetectionResult` 必填字段均已填充，但**没有 `recognizedAtMs`**；需 Agent 0 采纳建议 1，或由页面在 Promise 完成时补记。
- Agent 2 尚未提供设备侧推理证据和交接报告。

Agent 3（已核对组件，页面仍在集成）：

- `buildEditableDetections` 复制原始框，不修改 `DetectionResult.boxes`，符合。
- `applyClassChange` 保留 `originalClassId` 和 `confidence`，只改最终类别，符合；但没有 `editedAtMs`。
- **`removeDetection` 直接 `filter` 移除被删项，不符合**：保存层无法重建原始结果和修正率，必须先改为删除标记或保留 `removedItems`。
- `countByClass` 从同一数组统计并按数量降序、类别升序排序，符合。
- 重新识别清空编辑、空结果展示依赖页面集成，当前无法验证。

待确认：

- Agent 3 最终页面是否会改为保留全部原始项的删除标记。
- Agent 2/3 报告中的设备验证结论与最终字段说明。

## 4. 验证记录

### 4.1 后端健康接口

未修改 `backend/app/main.py`。在 `backend/` 用现有 `.venv` 临时启动：

```sh
.venv/bin/python -m uvicorn app.main:app --host 127.0.0.1 --port 8010
curl -i http://127.0.0.1:8010/health
curl -o /dev/null -w '%{http_code}' http://127.0.0.1:8010/docs
```

实际结果：

```text
HTTP/1.1 200 OK
content-type: application/json

{"status":"ok"}
docs_status=200
```

与 README（`/health`、`/docs`）及 `docs/api-plan.md`（当前仅实现 `GET /health`）一致。健康接口保持公开且可运行。

### 4.2 JSON 样例校验

用 Python 解析 `docs/phase-1-data-contract.md` 与 `docs/api-plan.md` 的全部 JSON 代码块，并检查：

- JSON 语法全部通过；
- `rawDetectionCount == detections.length`；
- `rawIndex` 从 0 连续；
- `detectionId` 后缀与下标一致；
- `classCorrected == (classId != rawClassId)`；
- `counts` 与未删除项的最终类别分组一致且总数相等；
- `edited` 与任一修正/删除一致。

结果：数据契约 3 个样例、接口规划 3 个代码块全部通过。

### 4.3 未执行的验证

- 未运行客户端构建：本次没有修改 ArkTS、资源或构建配置。
- 未验证真机缩略图生成、相册 URI 生命周期、离线保存和补传：采集层（`services/camera/`）目前仍只有 `.gitkeep`，这些属于后续阶段实现。
- 未验证 Agent 2/3 的运行时行为：Agent 2 已有推理代码但无设备运行证据和报告；Agent 3 页面仍在集成、报告未生成。

## 5. 第一阶段调用方如何使用

1. **页面（Agent 3）**：按 `docs/phase-1-data-contract.md` 第 8.1 节维护 `DetectionResult` 只读原始框和页面编辑状态；修正/删除后从同一状态重算计数；删除必须保留墓碑或 `removedItems`，不能物理丢弃原始项；切换图片或阈值时生成新 `requestId` 并清空编辑；第一阶段不生成 `recordId`、不显示保存/同步状态。
2. **推理层（Agent 2）**：继续按 `docs/phase-1-contract.md` 输出 `DetectionResult`；记录直接复制 `boxes/timing/options/modelId/modelSha256`；建议补 `recognizedAtMs`。
3. **保存/同步层（后续）**：在保存时生成 `recordId/detectionId/thumbnail`；保存前把图片复制到应用沙箱；上传只发 JSON，不发本地路径和同步元数据；以 `recordId` 幂等重试。
4. **后端（后续）**：业务接口接入 JWT；`/api/v1/records/batch` 按“设备 + recordId”幂等；服务端从 `detections` 重算计数；`/health` 保持公开。

## 6. 后续阶段仍需实现

1. Agent 0 整合共享类型与契约，冻结 `recognizedAtMs` 和 `RecordTypes`。
2. RDB 建表、事务、缩略图生成、相对路径管理、目录清理。
3. 按时间/类别查询与索引验证。
4. 设备注册、JWT 获取/刷新、Bearer 鉴权、401 处理。
5. 待传队列、批量上传、`recordId` 幂等、409 冲突处理、联网重传。
6. 模型版本检查/下载与 `modelId` 映射。
7. 云端筛选、分页、统计和统一错误码。
8. 真机验证相册临时 URI、缩略图、离线补传、时钟回拨与批量部分成功。

## 7. 风险与待确认项

| 风险/待确认 | 影响 | 处理建议 |
| --- | --- | --- |
| Agent 2/3 尚未完成交付 | 设备侧字段和页面最终编辑行为未验证 | 交付后按第 3.3 节逐项核对 |
| `recognizedAtMs` 未在共享类型中 | 页面补记会增加排队/渲染延迟 | Agent 0 采纳建议 1；否则保存层注明精度差异 |
| 页面物理删除误检（已在组件中确认） | 无法重建原始模型结果和修正率 | 改为 `deleted` 墓碑，或保留 `removedItems` 并在保存时合并 |
| 相册 URI 过期 | 延迟保存时无法生成缩略图 | 保存时立即复制；失败提示重新选图 |
| 已上传后修改载荷 | 同 `recordId` 内容冲突 | 新记录或显式版本协商；服务端 409，不静默覆盖 |
| `confidence` 被误解为最终类别概率 | 修正后展示语义错误 | 界面标记“已修正”，文档明确 confidence 属于原始类别 |
| 计数漂移 | 列表、框、统计不一致 | 单一状态源重算；服务端以明细为权威 |
| 重复保存同一结果 | 云端重复记录 | 保存成功禁用按钮；每次保存生成新 `recordId` |

## 8. 结论

第一阶段数据契约与接口规划已完成，覆盖标识、原始/编辑关系、字段语义、正常/空/编辑后样例、RDB 与幂等上传最小要求。共享类型改动建议已提交 Agent 0，未越权修改。后端健康接口保持可运行且与文档一致。当前有一个接入保存前的阻塞项：Agent 3 的 `removeDetection` 物理删除误检项，需改为墓碑或保留被删项，否则原始结果无法追溯。RDB、鉴权、上传队列、模型更新和云端统计留待后续阶段。
