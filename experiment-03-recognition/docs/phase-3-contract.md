# 第三阶段 云端同步 接口契约（Agent 0 冻结 · 后端对齐版）

> 本阶段聚焦"记录上传 + 云端查询 + 模型更新"三条链路。
> 本文件基于 `backend/app/services/record_service.py`、`backend/app/schemas/` 实际实现对齐。
> 路径前缀统一为 `/api/...`（不含 `/v1`），请求体字段按 Pydantic `_StrictModel(extra="forbid")` 严格校验。
> Agent 0 冻结日期：2026-10-22。后端实现证据：24 pytest 通过（`docs/phase-3-agent-4-report.md` §8）。

## 1. 鉴权：JWT

### 1.1 设备登录与令牌换取

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| POST | `/api/auth/login` | 设备标识 + 密钥换取 access + refresh 令牌。首次接入自动登记设备 |
| POST | `/api/auth/refresh` | access 令牌过期（HTTP 401）时，用 refresh 令牌轮换一对新令牌 |

**首次接入语义**：`deviceId` 不存在且 `deviceSecret == 服务端 DEVICE_SECRET` 时，自动登记设备（存 `sha256(deviceId:deviceSecret)` 密钥哈希）并发令牌。已登记设备密钥必须匹配。

**令牌存储**：客户端存 Preferences，**密钥不进 RDB**。生产构建由 build profile `hvigorProperties` 注入（契约 §9）。

### 1.2 请求体

`POST /api/auth/login`：

```json
{
  "deviceId": "d4f3a2b1-...",
  "deviceSecret": "内置密钥，生产构建注入，开发环境默认 dev-device-secret-change-me"
}
```

`POST /api/auth/refresh`：

```json
{
  "refreshToken": "..."
}
```

### 1.3 响应体（TokenResponse）

```json
{
  "accessToken": "...",
  "refreshToken": "...",
  "tokenType": "Bearer",
  "expiresIn": 1800,
  "refreshExpiresIn": 604800
}
```

- `expiresIn`：access 令牌有效期（秒），默认 1800（30 分钟）
- `refreshExpiresIn`：refresh 令牌有效期（秒），默认 604800（7 天）

### 1.4 统一鉴权失败处理

客户端 `services/network/HttpClient` 负责：

| HTTP 状态 | 后端错误码 | 客户端行为 |
| --- | --- | --- |
| 401 | `TOKEN_MISSING` | 附带 Bearer 令牌重试一次 |
| 401 | `TOKEN_INVALID` / `TOKEN_EXPIRED` | 用 refresh 令牌轮换；仍 401 → 清空令牌，UI 提示"登录已过期，需要重新授权" |
| 401 | `DEVICE_AUTH_FAILED` | UI 提示"设备认证失败，请检查密钥" |
| 401 | `DEVICE_DISABLED` | 永久失败，UI 提示"设备已停用" |
| 403 | — | 视为 `FORBIDDEN`，UI 引导重新配置 |

## 2. 模型版本查询与下载

| 方法 | 路径 | 鉴权 | 说明 |
| --- | --- | --- | --- |
| GET | `/api/models/version` | Bearer | 返回当前模型版本、SHA-256、下载地址、opset 元信息 |
| GET | `/api/models/download` | Bearer | 返回模型文件流；文件缺失返回 404 `MODEL_NOT_FOUND` |

### 2.1 响应体（ModelVersionResponse）

```json
{
  "modelId": "yolov13n-coco-640-opset18",
  "version": "1.0.0",
  "sha256": "f39e5a3b1763423b1e60769e81b08a5da012677dce0248f4b4a95c5ad5cb799b",
  "fileName": "yolov13n.onnx",
  "sizeBytes": 11456896,
  "opset": 18,
  "inputWidth": 640,
  "inputHeight": 640,
  "classCount": 80,
  "releasedAtMs": 1739808000000,
  "downloadUrl": "/api/models/download"
}
```

> **下载路径**：`/api/models/download` 返回文件流。客户端需自行下载到 `cacheDir/models/{modelId}-{sha256}.downloading`，SHA-256 校验通过后 `fs.renameSync` 原子替换进 `filesDir/models/{modelId}.onnx`。替换完成后通知 `RecognitionService.dispose()` + `initialize()`。

## 3. 记录批量上传（幂等）

| 方法 | 路径 | 鉴权 | 说明 |
| --- | --- | --- | --- |
| POST | `/api/records` | Bearer | 逐条幂等；每批最多 50 条；响应逐条返回 `created` / `duplicate` / `conflict` / `invalid` |

### 3.1 请求体（RecordBatchRequest，schemaVersion = 1）

```json
{
  "schemaVersion": 1,
  "records": [
    {
      "schemaVersion": 1,
      "recordId": "rec_1792630992345_a3f2",
      "requestId": "b47e9a12-...",
      "imageId": "rec_1792630992345_a3f2",
      "capturedAtMs": 1792630992345,
      "recognizedAtMs": 1792631000781,
      "savedAtMs": 1792631001012,
      "editedAtMs": null,
      "imageWidth": 810,
      "imageHeight": 1080,
      "isMirrored": false,
      "imageOrigin": "gallery",
      "model": {
        "modelId": "yolov13n-coco-640-opset18",
        "sha256": "f39e5a3b1763423b1e60769e81b08a5da012677dce0248f4b4a95c5ad5cb799b"
      },
      "options": {
        "confidenceThreshold": 0.25,
        "iouThreshold": 0.45,
        "maxDetections": 100,
        "executionMode": "taskpool"
      },
      "timing": {
        "preprocessMs": 3.2,
        "inferenceMs": 128.5,
        "postprocessMs": 2.1,
        "totalMs": 154.3,
        "coldStart": false,
        "modelLoadMs": 0.0
      },
      "rawDetectionCount": 5,
      "edited": true,
      "detections": [
        {
          "detectionId": "det-01",
          "rawIndex": 0,
          "rawClassId": 0,
          "rawLabel": "person",
          "classId": 0,
          "label": "person",
          "confidence": 0.937,
          "left": 12.3, "top": 45.6,
          "right": 89.1, "bottom": 489.2,
          "deleted": false,
          "classCorrected": false,
          "editedAtMs": null
        },
        {
          "detectionId": "det-02",
          "rawIndex": 1,
          "rawClassId": 41,
          "rawLabel": "cup",
          "classId": 41,
          "label": "cup",
          "confidence": 0.712,
          "left": 312.0, "top": 620.5,
          "right": 401.3, "bottom": 712.8,
          "deleted": true,
          "classCorrected": false,
          "editedAtMs": 1792631000900
        },
        {
          "detectionId": "det-03",
          "rawIndex": 2,
          "rawClassId": 0,
          "rawLabel": "person",
          "classId": 0,
          "label": "person",
          "confidence": 0.688,
          "left": 150.0, "top": 200.0,
          "right": 250.0, "bottom": 500.0,
          "deleted": false,
          "classCorrected": true,
          "editedAtMs": 1792631000800
        }
      ],
      "counts": [
        { "classId": 0, "label": "person", "count": 2 }
      ]
    }
  ]
}
```

### 3.2 后端校验不变量（`_validate_item`，`record_service.py:37-58`）

| 不变量 | 后端行为 |
| --- | --- |
| `schemaVersion == 1` | 否则 `SCHEMA_VERSION_UNSUPPORTED` → 单条 invalid |
| `rawDetectionCount == len(detections)` | **关键！** 否则 `RECORD_INVALID` |
| 所有 `rawIndex` 唯一 | 否则 `RECORD_INVALID` |
| 所有 `detectionId` 唯一 | 否则 `RECORD_INVALID` |
| 每条框 `right >= left` 且 `bottom >= top` | 否则 `RECORD_INVALID` |

### 3.3 误检删除语义（墓碑机制）

**用户删除误检后的上传行为**：

1. **客户端**：`detections` 数组上传**全部原始检测框**（含用户标记为 `deleted=true` 的墓碑），**不移除**任何原始框
2. **`rawDetectionCount`**：**必须等于 `detections.length`**（全部原始框总数，包括被删的）
3. **`counts`**：**仅统计 `deleted=false` 的框**的最终 `classId`；`classCorrected=true` 表示用户改了类别
4. **后端重算**：服务端**不信任客户端 counts**，按 `deleted=false` 的最终 `classId` 重新分组计数（count 降序、classId 升序）

**可追溯链路**：
- `rawClassId` / `rawLabel`：模型原始输出（永远不变）
- `classId` / `label`：用户编辑后的最终类别
- `deleted`：`true` = 用户删除的误检（墓碑保留，服务端计数时排除）
- `classCorrected`：`true` = 用户改了类别（`rawClassId != classId`）
- `rawIndex`：模型原始 NMS 前的索引（用于还原 NMS 后顺序）
- `editedAtMs`：首次编辑该框的时间戳

**示意**：模型输出 5 个检测框，用户删除 2 个误检，改了 1 个类别：
- `rawDetectionCount = 5`
- `detections.length = 5`（2 条 `deleted=true` 墓碑保留）
- 后端 `counts` = 按 3 条 `deleted=false` 的最终类别重算

### 3.4 幂等语义

| 场景 | 服务端判定 | 响应状态 |
| --- | --- | --- |
| `(deviceId, recordId)` 不存在 | 新写入 | `created` |
| `(deviceId, recordId)` 存在 + 规范化载荷相同 | 完全重复 | `duplicate`（视为成功，返回 `serverRevision`） |
| `(deviceId, recordId)` 存在 + 载荷不同 | 冲突（不覆盖） | `conflict`（客户端标记"冲突待用户确认"） |
| 不变量校验失败 | 单条 invalid | `invalid`（不影响同批其他条） |

**规范化载荷**：`json.dumps(item.model_dump(mode="json"), sort_keys=True, separators=(",", ":"), ensure_ascii=False)` 的 SHA-256。

### 3.5 三种 ID 关系

| 字段 | 格式 | 生成方 | 唯一性 | 说明 |
| --- | --- | --- | --- | --- |
| `recordId` | `rec_{unix_ms}_{hex4}` | 客户端 | 全局唯一 | 本地 RDB 主键 + 云端主键，保存后即固定 |
| `requestId` | UUID v4 | 客户端（每次上传） | 本次批次内唯一 | 每次批量上传的幂等标识，用于日志追踪；当前 `SyncQueue.enqueue(recordId)` 未用到，保留字段 |
| `imageId` | = `recordId` | 客户端 | 同 recordId | 本地 ImageAssetStore assetId；等于 recordId，为后续多图场景预留 |

当前实现中 `requestId` 和 `imageId` **都取 recordId**（Agent 4 上传层 `assembleUploadItem` 默认值），服务端不校验格式。

### 3.6 客户端 services/sync/ 队列接口

```ts
// services/sync/SyncQueue.ets（Agent 4）
interface SyncQueueApi {
  enqueue(recordId: string): void;          // 入队；幂等（同 recordId 多次只入队一次）
  flush(): Promise<string[]>;                // 手动触发上传；返回成功的 recordId 列表
  getStatus(recordId: string): SyncStatus;
  requeueStale(): void;                      // 启动时扫描 RDB 未上传记录入队
  snapshot(): SyncEntry[];                   // UI 展示
}

enum SyncStatus { PENDING, UPLOADED, CONFLICT, FAILED }

// services/sync/SyncManager.ets（Agent 4）
class SyncManager {
  static getInstance(): SyncManager;
  configure(baseUrl: string, clientKey?: string): void;
  initialize(context?: common.Context): Promise<void>;
  onRecordSaved(recordId: string): void;
  syncNow(): Promise<string[]>;
  snapshot(): SyncEntry[];
  dispose(): void;
}
```

**触发时机**：`RecordService.save()` 成功 → `onRecordSaved(recordId)` 自动入队并尝试 flush；用户点"同步" → `syncNow()`；应用启动 → `initialize()` 内自动 flush 一次（requeueStale 语义，因为队列持久化在 Preferences）。

**重试策略**：每条最多 3 次，指数退避（5s / 30s / 5min）；3 次失败转 FAILED；断网时跳过不消耗重试次数。

## 4. 云端历史查询

| 方法 | 路径 | 鉴权 | 说明 |
| --- | --- | --- | --- |
| GET | `/api/records` | Bearer | 时间/类别/来源筛选 + 分页；按 `recognizedAtMs DESC, recordId DESC` 稳定排序 |

### 4.1 查询参数

| 参数 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `fromMs` | int | null | `recognizedAtMs` 下界，闭区间（≥） |
| `toMs` | int | null | `recognizedAtMs` 上界，闭区间（≤） |
| `classId` | int | null | 最终类别，**仅匹配 `deleted=false` 的框** |
| `source` | `"camera"` / `"gallery"` | null | 图像来源筛选 |
| `page` | int | 1 | 页码（1-based） |
| `pageSize` | int | 20 | 每页条数，上限 100 |

`fromMs > toMs` → HTTP 400 `VALIDATION_ERROR`。

### 4.2 响应体（RecordPage）

```json
{
  "items": [
    {
      "recordId": "rec_1792630992345_a3f2",
      "recognizedAtMs": 1792631000781,
      "savedAtMs": 1792631001012,
      "imageOrigin": "gallery",
      "imageWidth": 810,
      "imageHeight": 1080,
      "modelId": "yolov13n-coco-640-opset18",
      "executionMode": "taskpool",
      "totalMs": 154.3,
      "rawDetectionCount": 5,
      "edited": true,
      "counts": [
        { "classId": 0, "label": "person", "count": 2 },
        { "classId": 41, "label": "cup", "count": 1 }
      ]
    }
  ],
  "page": 1,
  "pageSize": 20,
  "total": 1,
  "hasMore": false
}
```

> **counts 重算规则**：服务端按 `deleted=false` 的最终 `classId` 重算，count 降序、classId 升序。客户端不信任自身计数。

## 5. 客户端模块边界

| 路径 | 所有者 | 职责 |
| --- | --- | --- |
| `services/network/AuthStore.ets` | Agent 4 | deviceId 生成持久化、token 存取、login/refresh/ensureValidToken；裸 HTTP 调 `/api/auth/*` |
| `services/network/HttpClient.ets` | Agent 4 | Bearer 附加、401 → refresh 重试一次（并发去重）、统一 `NetworkFailure` 错误码映射 |
| `services/sync/SyncQueue.ets` | Agent 4 | 上传队列：Preferences 持久化、enqueue 幂等、退避重试、状态标记 |
| `services/sync/UploadService.ets` | Agent 4 | 串行 flush、组装 `RecordUploadItem`、调 `POST /api/records`、逐记录更新队列状态 |
| `services/sync/SyncManager.ets` | Agent 4 | 统一调度：initialize 注入 context + register 网络监听 + 启动即 flush、`onRecordSaved`、`syncNow` |
| `components/recognition/ModelUpdate.ets` | Agent 3 | UI 侧端口 `ModelUpdatePort` + `ModelUpdateRegistry` 静态注册表 |
| `components/recognition/CloudQuery.ets` | Agent 3 | UI 侧端口 `CloudRecordPort` + `CloudRecordRegistry` 静态注册表 + 错误映射 |

**端口注册点（已接入，2026-11-01）**：

```ts
// EntryAbility.onWindowStageCreate 中 SyncManager.initialize 之后：
ModelClient.getInstance().initialize(this.context);
CloudRecordRegistry.register(RecordClient.getInstance());
ModelUpdateRegistry.register(ModelClient.getInstance());
```

模拟器实测：`CloudRecordPort available=true, ModelUpdatePort available=true`。

## 6. 统一错误码

| code | HTTP 状态 | 场景 | 客户端对应 |
| --- | --- | --- | --- |
| `TOKEN_MISSING` | 401 | 缺少 Bearer | 上传层重新登录 |
| `TOKEN_INVALID` | 401 | 签名/类型/主体错误 | 重新登录 |
| `TOKEN_EXPIRED` | 401 | access 过期 | 用 refresh 续期 |
| `DEVICE_AUTH_FAILED` | 401 | 设备密钥错误 | 提示重新配置 |
| `DEVICE_DISABLED` | 401 | 设备停用 | 永久失败 |
| `RECORD_CONFLICT` | 单条状态 | recordId 相同、载荷不同 | 转 CONFLICT 状态，用户确认后重试 |
| `RECORD_INVALID` | 单条状态 | rawDetectionCount ≠ detections.length / rawIndex/detectionId 重复 / 框坐标非法 | 丢弃该条，标记 FAILED |
| `SCHEMA_VERSION_UNSUPPORTED` | 422 | 批次或单条 schemaVersion 不支持 | 升级客户端 |
| `MODEL_NOT_FOUND` | 404 | 模型文件缺失 | 提示模型不可用 |
| `VALIDATION_ERROR` | 400/422 | 参数格式或语义非法（如 fromMs > toMs） | 修正请求 |
| `STORAGE_WRITE_FAILED` | 单条状态 | 数据库写入异常 | 标记 FAILED，用户重试 |
| `SERVICE_UNAVAILABLE` | 503 | 数据库不可用 | 标记 FAILED |

错误响应统一格式：`{"code": "...", "message": "...", "detail": "..."}`。

## 7. 构建安全

- 客户端密钥 **不进源码**，由 build profile 的 `hvigorProperties` 注入，打包时写入 HAP native 配置或加密进 Preferences 默认值
- 开发默认密钥 `dev-device-secret-change-me` 硬编码在 `AuthStore.DEV_CLIENT_KEY`，生产构建必须替换
- 后端 `/docs` 仅开发环境可用（`APP_ENV=development`）
- 模型下载接口需本地文件存在，CI/新环境需先放置 ONNX

## 8. 待实现项（已知缺口）

| 项 | 当前状态 | 建议 |
| --- | --- | --- |
| `ModelUpdatePort` 实现 | **已实现**（2026-11-01） | `services/network/ModelClient.ets`：`/api/models/version` 比对 + `HttpClient.getBinary` 下载 → SHA-256 校验 → 原子替换 → `RecognitionService.replaceModel` 热更新。版本检查已在模拟器 E2E 验证；下载成功路径因后端仅有同 hash 版本，待补充第二个模型文件后验证 |
| `CloudRecordPort` 实现 | **已实现**（2026-11-01） | `services/network/RecordClient.ets`：`/api/records` 分页筛选 + `/api/statistics` 统计 + `reauthenticate`。模拟器 E2E 已验证 list/statistics/字段映射/鉴权 |
| 后端 `/api/statistics` | **已实现**（2026-11-01） | `GET /api/statistics?fromMs&toMs` 返回 `CloudStatistics` 形状（totalRecords/totalDetections/counts），按 deleted=false 最终类别聚合，pytest 覆盖 |
| 客户端 RDB v2 增列 | 当前 RDB v1 不含 threshold/timing 分段 | 上传时暂时用默认值 + 0，标记 TODO 后续替换 |

---

## 附录 A：与旧契约（`/api/v1/...` 前缀）的主要差异

| 旧契约 | 本契约（后端实际） | 变更原因 |
| --- | --- | --- |
| `POST /api/v1/auth/token` + `{deviceId, clientKey}` | `POST /api/auth/login` + `{deviceId, deviceSecret}` | 后端实际路径与字段名 |
| `POST /api/v1/auth/refresh` | `POST /api/auth/refresh` | 去掉 `/v1` 前缀 |
| `GET /api/v1/models/latest` | `GET /api/models/version` | 后端实际路径 |
| `GET /api/v1/models/{version}/download` | `GET /api/models/download`（当前版本） | 后端只提供当前版本下载 |
| `POST /api/v1/records/batch` + 扁平 `boxes` | `POST /api/records` + 嵌套 `detections[]`（含 rawIndex/deleted/classCorrected） | 后端 schema 含墓碑字段与模型/选项/耗时分组 |
| 无误检删除语义 | §3.3 明确墓碑机制 | 后端 `record_service.py:44` 强制 `rawDetectionCount == len(detections)` |
| 无三种 ID 关系 | §3.5 明确 recordId/requestId/imageId | 后端 schema 含这三个字段 |
