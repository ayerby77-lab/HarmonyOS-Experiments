# 第二阶段 本地识别记录 共享契约

> 本阶段聚焦本地闭环：识别结果持久化、查询、分页、详情、删除。云端功能留到后续。
> Agent 0 制定并冻结。Agent 4（数据与端云协同）实现存储层，Agent 3 在 UI 中接入。
> 关联文档：[`phase-1-contract.md`](phase-1-contract.md)（DetectionResult 语义）。
> 实际代码参照：[ImageAssetStore.ets](../app/entry/src/main/ets/services/imaging/ImageAssetStore.ets)（Agent 1 已交付）。

## 1. 存储方案选择

### 1.1 为什么用 RDB（关系型数据库）

HarmonyOS `@ohos.data.relationalStore`（RDB）优于 `@ohos.data.preferences` 的核心理由：

| 需求 | Preferences | RDB |
| --- | --- | --- |
| 按时间范围查询（近 7 天、全部） | 需加载全部 JSON 后本地过滤 | SQL `WHERE created_at BETWEEN ?` |
| 按类别筛选（"所有含 cup 的记录"） | 需扫描 JSON 数组 | SQL 从 `edited_boxes_json` 扫描，或后续拆分 record_boxes |
| 分页展示（每页 N 条） | 全量加载后手动切片 | SQL `LIMIT ? OFFSET ?` |
| 计数（"今日共识别 N 次"） | 全量遍历 | SQL `SELECT COUNT(*)` |
| 多表关联（记录 → 检测框） | 单一 JSON blob | 自然支持 |
| 索引加速 | 无 | 可建 `created_at`、`source` 索引 |

**放弃 Preferences 的风险提醒**（来自历史经验）：Preferences 对复杂对象（对象数组、嵌套结构）的序列化不稳定，设备重启后可能丢失；且不支持查询。本阶段不使用 Preferences 做持久化。

### 1.2 存储初始化时机

必须在页面加载前完成初始化。顺序：**EntryAbility.onWindowStageCreate → RDB 初始化 → 推理服务 setContext → ImageAssetStore 初始化 → loadContent**。

- 初始化失败时记录日志但不崩溃，让页面以空列表启动。
- RDB 打开后立即执行一次孤儿图像目录清理（见 §5.3），最多处理 200 个目录避免阻塞。

## 2. 数据结构

### 2.1 recordId 生成规则

格式：`rec_{unix_ms}_{hex4}`，例如 `rec_1734235200000_a3f2`。

- `unix_ms` 取保存时的 `Date.now()`。
- `hex4` 为 4 位随机十六进制，防止同一毫秒内碰撞。
- 由存储层在保存时生成，调用方传入空字符串或不传。

### 2.2 RDB Schema

数据库文件名：`smart_item_records.db`，位于 `${context.databaseDir}/smart_item_records.db`。

#### records 表

| 列 | 类型 | 说明 |
| --- | --- | --- |
| `record_id` | TEXT PRIMARY KEY | `rec_{unix_ms}_{hex4}` |
| `created_at_ms` | INTEGER NOT NULL | 识别完成时间，Unix 毫秒 |
| `source` | TEXT NOT NULL | `'camera'` 或 `'gallery'` |
| `model_id` | TEXT NOT NULL | 来自 DetectionResult.modelId |
| `model_sha256` | TEXT NOT NULL | 来自 DetectionResult.modelSha256 |
| `image_path` | TEXT NOT NULL | 原图相对路径（契约 §3.2） |
| `thumbnail_path` | TEXT NOT NULL | 缩略图相对路径 |
| `image_width` | INTEGER NOT NULL | 原图像素宽 |
| `image_height` | INTEGER NOT NULL | 原图像素高 |
| `cold_start` | INTEGER NOT NULL | 1/0 |
| `total_ms` | INTEGER NOT NULL | 来自 InferenceTiming.totalMs |
| `execution_mode` | TEXT NOT NULL | `'sync'` 或 `'taskpool'` |
| `raw_boxes_json` | TEXT NOT NULL | 原始 DetectionBox[]，JSON 序列化 |
| `edited_boxes_json` | TEXT NOT NULL | 用户编辑后的 DetectionBox[]，JSON 序列化 |

**不单独建 boxes 表**，直接 JSON 存两条。理由：本阶段只做列表和详情，不做跨记录框查询。若后续做"所有记录中 cup 出现频次"，再拆分 record_boxes 表并触发迁移。

#### 索引

```sql
CREATE INDEX IF NOT EXISTS idx_records_created_at ON records(created_at_ms DESC);
CREATE INDEX IF NOT EXISTS idx_records_source ON records(source);
```

### 2.3 文件布局（与 ImageAssetStore 对齐）

ImageAssetStore 已实现，以下以实际代码为准（[ImageAssetStore.ets](../app/entry/src/main/ets/services/imaging/ImageAssetStore.ets)）：

```
filesDir/records/{assetId}_original.jpg   原图副本（扁平命名，每 assetId 一组文件）
filesDir/records/{assetId}_thumb.jpg      缩略图
```

**ImageAssetStore 导出常量**：

| 常量 | 值 | 说明 |
| --- | --- | --- |
| `RECORDS_DIR_NAME` | `'records'` | 图像根目录（相对 filesDir） |
| `THUMBNAIL_MAX_EDGE` | `480` | 缩略图最长边（像素），等比不放大 |
| `THUMBNAIL_JPEG_QUALITY` | `80` | 缩略图 JPEG quality |
| `ORIGINAL_JPEG_QUALITY` | `90` | 原图 JPEG quality |
| `ORPHAN_GRACE_PERIOD_MS` | `600000`（10 分钟） | 孤儿清理 mtime 宽限 |
| `ORPHAN_CLEANUP_MAX_COUNT` | `200` | 单次孤儿清理上限 |

**assetId 格式**：`rec_{unix_ms}_{hex4}`，与 recordId 生成规则完全一致。

**路径语义**：
- `ImageAssetStore.persistCapturedImage` 返回的 `CapturedImageAssets.originalPath` / `.thumbnailPath` 是**绝对路径**（供立即使用）；
- 同时 `CapturedImageFile.relativePath` 存 `records/{assetId}_original.jpg` 格式的**相对路径**；
- RDB `image_path` / `thumbnail_path` 列存**相对路径**（应用重启后需重解析）；
- 读取时用 `ImageAssetStore.resolveAbsolutePath(context, relativePath)` 解析为绝对沙箱路径；
- ImageAssetStore 在 `checkImageFile` / `resolveAbsolutePath` 中校验：必须以 `records/` 开头、不含 `..`、后缀必须是 `_original.jpg` 或 `_thumb.jpg`。

**为什么原图也存 filesDir**：cacheDir 系统会自动清理，记录列表还在但图缺失；filesDir 生命周期与应用绑定，只有应用卸载或手动删除时才清空。

### 2.4 原图来源与所有权

| 场景 | 原图处理 |
| --- | --- |
| 相册选图 | Agent 1 GalleryImageService 解码出方向归一化 ImageSource → ImageAssetStore.persistCapturedImage 写原图 + 缩略图 |
| 相机拍照 | Agent 1 CameraCaptureService 解码出方向归一化 ImageSource → 同上 |

**责任链**：ImageAssetStore 只消费像素 buffer，不持有原始 JPEG/URI；相机/相册临时 URI 在 ImageDecoder 完成后立即释放。

## 3. 原始结果与编辑结果的关系

### 3.1 保存时

```
save(recordId, detectionResult, originalPath, thumbnailPath)
  写入 raw_boxes_json = detectionResult.boxes 的 JSON
  写入 edited_boxes_json = detectionResult.boxes 的 JSON  ← 首次保存两者相同
```

### 3.2 用户编辑后

```
updateEdited(recordId, editedBoxes)
  只更新 edited_boxes_json
  raw_boxes_json 永远不变，作为可追溯的基准
```

### 3.3 设计理由

- 满足"原始模型结果、可编辑结果、统计计数保持可追溯"的规则（AGENTS.md 公共执行规则）。
- 若未来需要"恢复原始"或"重新识别（换阈值）"，只需用 raw_boxes_json 重建界面。

## 4. 公共 API

### 4.1 ImageAssetStore API（Agent 1 已交付）

```ts
class ImageAssetStore {
  static getInstance(): ImageAssetStore;
  async persistCapturedImage(context, source: ImageSource): Promise<CapturedImageAssets>;
  async deleteImages(context, originalPath, thumbnailPath): Promise<void>;   // 幂等
  async listOrphanRecordImages(context, referencedAssetIds, gracePeriodMs?, maxCount?): Promise<string[]>;
  async cleanupOrphanRecordImages(context, referencedAssetIds, gracePeriodMs?, maxCount?): Promise<number>;
  resolveAbsolutePath(context, relativePath): string;
  async imageFileExists(context, absoluteOrRelativePath): Promise<boolean>;
}
interface CapturedImageAssets {
  assetId: string;
  originalPath: string;        // 绝对路径
  thumbnailPath: string;       // 绝对路径
  original: PersistedImageFile;
  thumbnail: PersistedImageFile;
}
interface PersistedImageFile {
  relativePath: string;        // records/{assetId}_original.jpg（存入 RDB 的值）
  width: number;
  height: number;
  format: string;
  byteSize: number;
}
```

**调用约定**（Agent 3 / UI 侧）：
- `persistCapturedImage` 返回的 `CapturedImageAssets.original.relativePath` 和 `.thumbnail.relativePath` 是**存入 RDB 的值**（相对路径）。
- 立即展示可直接用 `.originalPath` / `.thumbnailPath`（绝对路径），不必再解析。
- 孤儿清理调用方传 `referencedAssetIds`（RDB 中全部 record_id 集合），ImageAssetStore 内部按文件名提取 assetId 做差集。

### 4.2 RecordServiceApi（Agent 4 实现）

```ts
interface RecordServiceApi {
  initialize(): Promise<{ initialized: boolean; error?: string }>;

  // ---- 写入 ----
  save(modelResult, source, originalPath, thumbnailPath): Promise<string>;  // 返回 recordId
  updateEdited(recordId, editedBoxes): Promise<RecordDetail>;
  delete(recordId): Promise<{ deleted: boolean }>;

  // ---- 查询 ----
  list(page, pageSize, sourceFilter?): Promise<RecordPage>;
  getDetail(recordId): Promise<RecordDetail | null>;
  listByClass(classId, limit?): Promise<RecordSummary[]>;
  countByTimeRange(fromMs, toMs): Promise<number>;

  dispose(): Promise<void>;
}
```

**查询契约**：

| 方法 | SQL 实现 | 返回 |
| --- | --- | --- |
| `list(page=1, pageSize=20, sourceFilter?)` | `SELECT ... FROM records [WHERE source=?] ORDER BY created_at_ms DESC LIMIT ? OFFSET ?`；`hasMore = EXISTS(同一条件 OFFSET (page+1)*pageSize)` | `RecordPage` |
| `getDetail(recordId)` | `SELECT ... WHERE record_id=?`；反序列化 JSON 为 `rawBoxes` / `editedBoxes` | `RecordDetail \| null` |
| `listByClass(classId, limit=50)` | 扫描 `edited_boxes_json`（或后续加 raw）的 JSON 数组，筛选含 `classId` 的记录，返回摘要（按时间降序，limit 截断） | `RecordSummary[]` |
| `countByTimeRange(fromMs, toMs)` | `SELECT COUNT(*) FROM records WHERE created_at_ms BETWEEN ? AND ?` | `number` |

**注意**：`listByClass` 需要 JSON 扫描，性能有限。本阶段用 ArkTS 侧循环解析即可（记录量 < 1000 条），不拆 boxes 表。若设备上明显慢，后续迁移。

### 4.3 UI 侧调用示例（Agent 3）

```ts
// 识别后保存
async function onRecognized(result: DetectionResult, source: ImageSource): Promise<void> {
  const assetStore = ImageAssetStore.getInstance();
  const assets = await assetStore.persistCapturedImage(context, source);
  // RDB 存相对路径（可重启后重解析）
  const originalRel = assets.original.relativePath;
  const thumbRel = assets.thumbnail.relativePath;
  try {
    await RecordService.getInstance().save(
      result, source, originalRel, thumbRel);
  } catch (e) {
    // RDB 写入失败 → 回滚图片文件（避免孤儿）
    assetStore.deleteImages(context, assets.originalPath, assets.thumbnailPath);
    throw e;
  }
}

// 分页加载
async function loadPage(page: number): Promise<RecordPage> {
  return RecordService.getInstance().list(page, 20);
}

// 编辑后保存
async function onBoxEdited(recordId: string, edited: DetectionBox[]): Promise<void> {
  await RecordService.getInstance().updateEdited(recordId, edited);
}

// 删除
async function onDelete(recordId: string): Promise<void> {
  const detail = await RecordService.getInstance().getDetail(recordId);
  await RecordService.getInstance().delete(recordId);       // RDB 级联删除
  if (detail) {
    await ImageAssetStore.getInstance().deleteImages(
      context, detail.imagePath, detail.thumbnailPath);      // 文件清理（幂等）
  }
}
```

## 5. 边界条件与策略

### 5.1 重复保存（同一帧多次触发识别）

| 场景 | 策略 |
| --- | --- |
| 用户快速连点"开始识别"10 次 | 推理层 latest-wins（第一阶段已实现），只有最后一次结果走保存流程 |
| 用户对同一图分别用 sync 和 taskpool 模式识别 | 保存两条独立记录，`recordId` 不同、`execution_mode` 不同 |
| 用户对同一张图换阈值再识别 | 同上，独立记录。阈值变化是一次新的识别尝试 |

**不**做"同图片去重"。每次识别都是独立实验。

### 5.2 保存失败回滚

保存流程：`ImageAssetStore.persistCapturedImage`（写 JPEG）→ `RecordService.save`（写 RDB）。

| 失败点 | 行为 |
| --- | --- |
| ImageAssetStore 内部失败 | 不会产生半成品（内部 try/finally 清理 tempDir 和 target imageDir）；直接 reject |
| JPEG 写入成功但 RDB 写入失败 | **立即调用** `ImageAssetStore.deleteImages(context, originalPath, thumbnailPath)` 清理。若清理也失败 → 文件留在磁盘 → **启动时孤儿清理兜底** |

RDB 打开失败、`save()` 抛 `DB_WRITE_FAILED` 时 UI 提示"保存失败，请重试"；重试会再次走完整流程（重新编码 + 重新写 DB），不依赖已有半成品。

### 5.3 孤儿清理

**孤儿定义**：`filesDir/records/` 目录下文件名 `{assetId}_original.jpg` / `{assetId}_thumb.jpg` 的 assetId 不在 RDB 的 `record_id` 列中，且 mtime 早于宽限期（保护正在保存、尚未写入 RDB 的新文件）。

| 时机 | 操作 | 上限 |
| --- | --- | --- |
| RDB 初始化成功后 | 读取全部 record_id，调用 `ImageAssetStore.cleanupOrphanRecordImages(context, referencedAssetIds)` 删除 | 每次启动最多 200 个文件 |
| 调用方主动清理保存失败后的文件 | `deleteImages` 立即删除（幂等，缺文件不报错） | 无限制（单张） |
| 删除记录时 | 先删 RDB 行，再删图片文件（幂等） | 无限制（单张） |

**事务性**：文件与 DB 不在同一事务。删除记录时"先 DB 后文件"——若 DB 删成功但文件删失败 → 孤儿，下次启动清理。

**宽限机制**：mtime < (now - ORPHAN_GRACE_PERIOD_MS) 的文件才会被清理；避免把进行中的保存流程（JPEG 写完但 RDB 未 commit）误删。宽限默认 10 分钟，可传参覆盖。

### 5.4 查询契约

| 方法 | 分页参数 | 返回语义 |
| --- | --- | --- |
| `list(page, pageSize)` | `page >= 1`；`pageSize ∈ [1, 50]`，clamp 到这个范围 | `hasMore = OFFSET page*pageSize 仍有行`；`items` 按 `created_at_ms DESC` |
| `listByClass(classId, limit)` | `limit` 默认 50，最大 200；`classId ∈ [0, 79]` | 只看 `editedBoxes`（用户编辑后的结果），未编辑时 `editedBoxes === rawBoxes`，所以逻辑覆盖全部 |
| `countByTimeRange(fromMs, toMs)` | `fromMs <= toMs` | 包括两端 |
| `getDetail(recordId)` | — | 找不到返回 `null`，不抛错 |

查询失败统一抛 `RecordErrorCode.DB_WRITE_FAILED`（读也用这个 code，因为 RDB 读写都走同一个 API）。

### 5.5 并发安全

- RDB 内部自带锁（SQLite mutex），跨线程调用安全。
- `save()` 不应同时保存同一张图——由 UI 的串行交互自然避免。
- 文件操作（写 JPEG / 删目录）与 RDB 操作不在同一事务。

## 6. 与第一阶段的契约衔接

### 6.1 共用类型

| 第一阶段类型 | 第二阶段用法 |
| --- | --- |
| `DetectionBox` | `raw_boxes_json` 和 `edited_boxes_json` 的 JSON 结构 |
| `DetectionResult.modelId` / `.modelSha256` | records 表对应列 |
| `InferenceTiming.totalMs`、`.coldStart` | 记录推理元信息 |
| `InferenceExecutionMode` | records.execution_mode |
| `ImageOrigin` | records.source |

### 6.2 需要新增的共享类型（RecordTypes.ets，Agent 0 冻结）

```ts
// 列表项（摘要）
interface RecordSummary {
  recordId: string;
  createdAtMs: number;
  source: ImageOrigin;
  thumbnailPath: string;      // 相对路径
  imageWidth: number;
  imageHeight: number;
  editedBoxCount: number;
  editedTopClassLabel: string;
  editedTopConfidence: number;
  executionMode: InferenceExecutionMode;
  totalMs: number;
}

// 详情项（含原始和编辑检测框）
interface RecordDetail {
  recordId: string;
  createdAtMs: number;
  source: ImageOrigin;
  modelId: string;
  modelSha256: string;
  imagePath: string;          // 相对路径
  thumbnailPath: string;     // 相对路径
  imageWidth: number;
  imageHeight: number;
  rawBoxes: DetectionBox[];
  editedBoxes: DetectionBox[];
  coldStart: boolean;
  totalMs: number;
  executionMode: InferenceExecutionMode;
}

// 分页结果
interface RecordPage {
  items: RecordSummary[];
  page: number;           // 1-based
  pageSize: number;
  hasMore: boolean;
}
```

### 6.3 DetectionResult → 保存的数据流

```
Agent 1 采集
  → ImageSource（像素 buffer）

Agent 2 推理
  → DetectionResult（boxes + timing + model 信息）

Agent 3 UI（保存按钮）
  → ImageAssetStore.persistCapturedImage(context, source)
    返回 CapturedImageAssets { assetId, originalPath(绝对), thumbnailPath(绝对), original/thumbnail.relativePath(相对) }
  → RecordService.save(detectionResult, source, original.relativePath, thumbnail.relativePath)
    返回 recordId
  → save 失败 → ImageAssetStore.deleteImages(context, originalPath(绝对), thumbnailPath(绝对)) 回滚
```

## 7. 错误码

```ts
export enum RecordErrorCode {
  RECORD_NOT_FOUND = 'RECORD_NOT_FOUND',
  DB_INIT_FAILED = 'DB_INIT_FAILED',
  DB_WRITE_FAILED = 'DB_WRITE_FAILED',
  IMAGE_COPY_FAILED = 'IMAGE_COPY_FAILED',    // 映射 ImageAssetError.io-failed
  THUMBNAIL_FAILED = 'THUMBNAIL_FAILED',      // 映射 ImageAssetError.encode-failed
  UNKNOWN = 'RECORD_UNKNOWN'
}
```

UI 侧错误映射：
- DB_INIT_FAILED → "识别历史不可用"（页面降级，其他功能正常）
- RECORD_NOT_FOUND → 详情页提示"记录已删除"
- DB_WRITE_FAILED / IMAGE_COPY_FAILED → Toast "保存失败，请重试"

## 8. 文件边界

| 范围 | 所有者 | 说明 |
| --- | --- | --- |
| `docs/phase-2-contract.md` | Agent 0 | 本契约 |
| `app/entry/src/main/ets/models/RecordTypes.ets` | Agent 0 | 第二阶段共享类型 |
| `app/entry/src/main/ets/services/imaging/ImageAssetStore.ets` | Agent 1 | 已交付；Agent 4 通过相对路径消费，不改 |
| `app/entry/src/main/ets/services/storage/` | Agent 4 | RDB 打开、CRUD、孤儿清理、dispose |
| `app/entry/src/main/ets/components/recognition/RecordList.ets`、`RecordDetail.ets` | Agent 3 | 历史列表、分页、详情、编辑、删除 UI |
| `app/entry/src/main/ets/entryability/EntryAbility.ets` | Agent 0 | 存储初始化前置（RDB + ImageAssetStore） |

## 9. 验证状态

已确认：
- ImageAssetStore 已交付，文件布局、缩略图参数、相对路径语义均已固化。
- 本契约的 RDB 方案未在设备上实测，Agent 4 需在实现后做真机验证。
- 时间范围 + 类别筛选用 JSON 扫描实现，< 1000 条记录应可接受；若性能差后续迁移 record_boxes 表。

待验证：
- RDB 在 API 24/26 上的 `@ohos.data.relationalStore` 可用性与 API 兼容性。
- 1000+ 条记录下的分页查询性能（应 < 100 ms）。
- `listByClass` 的 JSON 扫描耗时。
- 删除记录时文件清理的原子性（DB 成功但文件失败时走孤儿清理）。
- 孤儿清理在应用重启时的执行时间（应 < 1 s，最多处理 200 条）。
