# Agent 4 第二阶段交接报告 — 本地记录存储

> 负责人：Agent 4（数据与端云协同）。日期：2026-10-22 (Asia/Shanghai)。
> 范围：HarmonyOS RDB 本地持久化层，实现 Agent 0 冻结的 `RecordServiceApi`
>（`app/entry/src/main/ets/models/RecordTypes.ets`），依据
> [`docs/phase-2-contract.md`](phase-2-contract.md) 第 2–7 节。

## 1. 修改 / 新增文件

### 新增

| 文件 | 职责 |
| --- | --- |
| `app/entry/src/main/ets/services/storage/RecordDatabase.ets` | RDB 打开、版本迁移（SQLite user_version 递增）、建表 DDL、事务工具 `runInTransaction`、`recordId` 生成器 |
| `app/entry/src/main/ets/services/storage/RecordService.ets` | 单例服务，实现 `RecordServiceApi` 全部 8 个公开方法 + 2 个内部方法（ensureStore、cleanupOrphans） |

### 修改

| 文件 | 变更 |
| --- | --- |
| `app/entry/src/main/ets/services/imaging/ImageAssetStore.ets` | 修正 3 处编译错误：`captured.data/width/height`（字段名修正）、`image.createPixelMapSync` 静态调用名 |

### 未触碰

`models/**`（Agent 0）、`pages/**`、`components/**`、`services/camera/**`、`services/inference/**`、`services/imaging/**` 其余部分、`backend/**`、`EntryAbility.ets`。

## 2. 数据结构

### RDB Schema（单表 records）

数据库文件 `${context.databaseDir}/smart_item_records.db`，version=1，`@kit.ArkData.relationalStore`。

| 列 | 类型 | 约束 | 说明 |
| --- | --- | --- | --- |
| `record_id` | TEXT | PRIMARY KEY | `rec_{unix_ms}_{hex4}` |
| `created_at_ms` | INTEGER | NOT NULL | 保存时刻 `Date.now()`（契约 2.2 要求识别完成时间，`DetectionResult.recognizedAtMs` 已由 Agent 2 补齐） |
| `source` | TEXT | NOT NULL | `'camera'` / `'gallery'` |
| `model_id` | TEXT | NOT NULL | |
| `model_sha256` | TEXT | NOT NULL | |
| `image_path` | TEXT | NOT NULL | 相对 `filesDir` 路径（`toRelativePath` 归一化后入库） |
| `thumbnail_path` | TEXT | NOT NULL | 同上 |
| `image_width` | INTEGER | NOT NULL | |
| `image_height` | INTEGER | NOT NULL | |
| `cold_start` | INTEGER | NOT NULL | 1/0 |
| `total_ms` | INTEGER | NOT NULL | 四舍五入为整数 |
| `execution_mode` | TEXT | NOT NULL | `'sync'` / `'taskpool'` |
| `raw_boxes_json` | TEXT | NOT NULL | 首次保存时与下一列相同 |
| `edited_boxes_json` | TEXT | NOT NULL | 用户编辑后覆盖；`updateEdited` 只写此列，raw 永远不变 |

### 索引

```sql
CREATE INDEX IF NOT EXISTS idx_records_created_at ON records(created_at_ms DESC);
CREATE INDEX IF NOT EXISTS idx_records_source    ON records(source);
```

### 版本迁移

```ts
current = store.version;     // SQLite user_version，新建库为 0
if current < 1 { CREATE TABLE + 两个 INDEX }
// 后续版本：if current < 2 { ALTER / CREATE NEW TABLE / DATA MIGRATE }
store.version = RECORD_DB_VERSION;  // 1
```

所有 DDL 在 `runInTransaction` 内执行，失败回滚并恢复 user_version。

## 3. 导出接口

### RecordService（实现 `RecordServiceApi`，单例）

```ts
RecordService.getInstance(): RecordService
initialize(context?: common.Context): Promise<{ initialized: boolean; error?: string }>
save(modelResult, source, originalPath, thumbnailPath): Promise<string>   // 返回 recordId
updateEdited(recordId, editedBoxes): Promise<RecordDetail>
list(page, pageSize, sourceFilter?): Promise<RecordPage>
getDetail(recordId): Promise<RecordDetail | null>
delete(recordId): Promise<{ deleted: boolean }>
listByClass(classId, limit?): Promise<RecordSummary[]>
countByTimeRange(fromMs, toMs): Promise<number>
dispose(): Promise<void>
```

### RecordDatabase（静态工具）

```ts
RecordDatabase.open(context): Promise<RdbStore>
RecordDatabase.runInTransaction<T>(store, fn): Promise<T>
RecordDatabase.generateRecordId(nowMs): string
```

### 辅助类型（RecordService.ets 内）

```ts
export class RecordFailure extends Error {
  code: RecordErrorCode;     // 冻结值，来自 RecordTypes.ets
  detail: string;
}
export interface RecordSaveInput { boxes, modelId, modelSha256, imageWidth, imageHeight, coldStart, totalMs, executionMode }
```

## 4. 关键实现决策

### 4.1 初始化时机与容错

`RecordServiceApi.initialize` 无参；实际支持：
- EntryAbility 可传 `UIAbility.context`；
- 未显式传参时 `getContext()` 兜底（ArkTS 全局应用上下文）；
- 并发调用共享同一 `initPromise` 去重；
- 失败重置 `initPromise=null`，下次可重试；
- 内部失败不抛，仅 `initialized=false` + 日志。

### 4.2 save 的 recordId 策略与幂等

优先从 `originalPath` 文件名提取 `assetId`（Agent 1 `ImageAssetStore` 使用 `rec_{ms}_{hex4}_original.jpg` 命名），使记录行与图像文件 id 同名：
1. **同文件重复保存**（同一持久化产物被提交两次）→ INSERT 主键冲突 → 查 `getDetail(pathId)` → 存在即幂等返回原 id，不产生重复行；
2. **冲突但查询为空**（异常中间态）→ 放弃 pathId，后续重试回退到 `RecordDatabase.generateRecordId()` 自生成；
3. **自生成 id 冲突**（理论极低）→ 换 id 重试最多 `SAVE_ID_RETRY=3` 次，失败回滚图像文件。

写入失败回滚：`ImageAssetStore.deleteImages(originalPath, thumbnailPath)`，尽力而为不阻塞。

### 4.3 相对路径入库

RDB 存相对 `filesDir` 的路径：`toRelativePath(context, absolutePath)` 剥离 `${filesDir}/` 前缀。重启后仍可重建绝对路径解码；也避免应用迁移沙箱时绝对路径失效。

### 4.4 列表分页与稳定排序

```sql
ORDER BY created_at_ms DESC, record_id DESC LIMIT (? + 1) OFFSET ?
```
- 多取一行判定 `hasMore`（契约 4.1），省一次 `SELECT COUNT(*)`；
- 同毫秒记录用 `record_id DESC` 二次排序，翻页稳定；
- `sourceFilter` 用参数化 WHERE 拼接；
- `pageSize` 钳位到 `[1, 50]`，负数或 NaN 回退 20。

### 4.5 updateEdited 只改 edited_boxes_json

契约 3.2 约束：`updateEdited` 事务内先校验记录存在（查 `record_id`），再 `UPDATE SET edited_boxes_json = ?`。`raw_boxes_json` 永不修改，保留模型原始快照供追溯 / 恢复。

### 4.6 delete 级联图像

1. 事务内查 `image_path, thumbnail_path` → 记录存在 → DELETE 行；
2. 事务外调用 `ImageAssetStore.deleteImages(originalPath, thumbnailPath)`（幂等：文件缺失不报错）；
3. 图像删除失败不阻塞（留待启动孤儿清理）；
4. 幂等：记录不存在返回 `{deleted:false}`。

### 4.7 listByClass 内存过滤

契约 4.1 "原始或编辑后任一框含该类即匹配"。本阶段不拆 boxes 表（契约 2.2 决策），故读全部行后内存过滤 JSON 列；按 `created_at_ms DESC` + `LIMIT` 截断。后续若引入跨记录类统计（"所有记录中 cup 频次"），拆 `record_boxes` 表并在本方法内 JOIN。

### 4.8 启动孤儿清理

契约 5.3 要求：初始化成功后，把全部 `record_id` 集合交给 `ImageAssetStore.cleanupOrphanRecordImages(context, referencedIds)`。该函数保证：
- 单次上限 200 个文件（`ORPHAN_CLEANUP_MAX_COUNT`）；
- mtime 宽限 10 分钟（`ORPHAN_GRACE_PERIOD_MS`），避免误删正在保存流程、尚未写入 RDB 的新文件；
- 返回删除数量并记录日志；失败不阻塞初始化。

## 5. 事务与 SQL 安全

| 场景 | 策略 |
| --- | --- |
| INSERT / UPDATE / DELETE 写操作 | `RecordDatabase.runInTransaction(store, fn)`：同步 `beginTransaction()` + async fn + `commit()` / 异常 `rollBack()` |
| DDL（建表/索引） | 同 runInTransaction |
| SELECT 查询 | 直接 `store.querySql(sql, bindArgs)`，无事务 |
| 所有 SQL 参数 | 通过 bindArgs 参数化，不拼接用户输入（recordId/路径/类别等） |
| `close()` | dispose 时 await close，异常吞掉并 warn |

## 6. 与其他 Agent 的协调

### Agent 1（ImageAssetStore）

| 点 | 对齐 |
| --- | --- |
| 文件布局 | Agent 1 采用 `filesDir/records/{rec_id}_original.jpg` + `{rec_id}_thumb.jpg`（扁平化，非目录式）；RecordService 的 `extractAssetId` 匹配此前缀 + 后缀；删除/孤儿清理均委托给 `ImageAssetStore.deleteImages` / `cleanupOrphanRecordImages` |
| 相对路径 | RecordService.save 接收任意路径，内部归一化为相对 `filesDir`；Agent 1 也支持"相对或绝对" |
| recordId / assetId 同构 | 两者都用 `rec_{unix_ms}_{hex4}`；RecordService.save 优先复用 Agent 1 生成的 assetId |
| 图像文件回滚 | save 失败时 RecordService 调 `deleteImages`；delete 记录时也是同一调用 |
| 孤儿清理 | RecordService 提供 record_id 集合，ImageAssetStore 判定 + 删除（含宽限），契约 5.3 |
| 错误码映射 | Agent 1 `io-failed→IMAGE_COPY_FAILED`、`encode-failed→THUMBNAIL_FAILED`；RecordService 自身的 DB_INIT_FAILED / DB_WRITE_FAILED / RECORD_NOT_FOUND 不来自 Agent 1 |

### Agent 2（推理）

`DetectionResult.recognizedAtMs` 第二阶段已由 Agent 2 补齐；RecordService.save 额外再补 `createdAtMs = Date.now()`，两者不一致时以保存时刻为准（页面可能在识别完成后延迟保存）。

### Agent 3（页面）

接入指引（契约 4.2 UI 侧示例 + RecordServiceApi 签名）：

```ts
// EntryAbility.onWindowStageCreate：
async initialize() {
  await RecordService.getInstance().initialize(this.context);
  await RecordService.getInstance().dispose();  // onDestroy
}
// 保存按钮：
const assets = await ImageAssetStore.getInstance().persistCapturedImage(ctx, imageSource);
try {
  const recordId = await RecordService.getInstance().save(
    { boxes: result.boxes, modelId: result.modelId, modelSha256: result.modelSha256,
      imageWidth: result.imageWidth, imageHeight: result.imageHeight,
      coldStart: result.timing.coldStart, totalMs: result.timing.totalMs,
      executionMode: result.executionMode },
    result.requestId ? ImageOrigin.CAMERA : ImageOrigin.GALLERY,  // 按 ImageSource.origin
    assets.originalPath, assets.thumbnailPath);
} catch (e) {
  if (e instanceof RecordFailure) { /* 映射 RecordErrorCode */ }
}
```

页面需要自行调用 `persistCapturedImage` 生成文件，之后再调 `save`——RecordService 不做图像编码。

### Agent 0（EntryAbility 入口）

`EntryAbility.ets` 当前仍是最小入口（无 setContext 链路）。Agent 0 在第二阶段任务中需要在 `loadContent` 前插入：

```ts
onWindowStageCreate(windowStage) {
  const ctx = this.context;
  // 顺序：存储初始化 → 推理 setContext → loadContent
  RecordService.getInstance().initialize(ctx);
  RecognitionService.getInstance().setContext(ctx);
  windowStage.loadContent('pages/Index', ...);
}
onDestroy() {
  RecordService.getInstance().dispose();
}
```

该改动属于共享入口，由 Agent 0 统一写入；本报告记录于此供参考。

## 7. 接口兼容性核对

`RecordService` 实现 `RecordServiceApi`（`models/RecordTypes.ets`，Agent 0 冻结）的全部 8 个签名：

| RecordServiceApi 方法 | RecordService 实现 | 差异 |
| --- | --- | --- |
| `initialize()` | `initialize(context?)` | 签名兼容，多接受可选 context（内部用 `getContext()` 兜底） |
| `save(modelResult, source, originalPath, thumbnailPath): Promise<string>` | 同 | — |
| `updateEdited(recordId, editedBoxes): Promise<RecordDetail>` | 同 | — |
| `list(page, pageSize, sourceFilter?): Promise<RecordPage>` | 同 | — |
| `getDetail(recordId): Promise<RecordDetail | null>` | 同 | — |
| `delete(recordId): Promise<{ deleted: boolean }>` | 同 | — |
| `listByClass(classId, limit?): Promise<RecordSummary[]>` | 同 | — |
| `countByTimeRange(fromMs, toMs): Promise<number>` | 同 | — |
| `dispose(): Promise<void>` | 同 | — |

ArkTS 结构类型检查在编译时校验方法签名，构建通过即类型兼容。

## 8. 构建与静态验证

| 目标 | 命令 | 结果 |
| --- | --- | --- |
| 默认 HAP | `./scripts/build-app.sh` | ✅ BUILD SUCCESSFUL（490ms，21 tasks）；storage 两个文件 + 修正后的 ImageAssetStore 零 ArkTS 警告 |

`@kit.ArkData` 导入（`relationalStore`）在本 SDK 版本（DevEco 26.0.0.105 / API 26）编译通过，方法签名按 SDK 声明核对：`getRdbStore(context, config)`、`store.beginTransaction()/commit()/rollBack()`、`store.executeSql(sql, bindArgs)`、`store.querySql(sql, bindArgs)`、`ResultSet.getString/getLong/goToNextRow/close/rowCount`、`store.version` 读写。

## 9. 设备侧需验证项

| 验证项 | 方法 | 阻塞 |
| --- | --- | --- |
| RDB 首次启动：建表 + 索引 + 孤儿清理执行 | 启动应用，看 hilog "RDB opened" + "Orphan cleanup" | 无（模拟器 arm64 可用） |
| 应用重启后数据恢复：save 后 kill 进程再启动 | 用 `RecordService.save` 写入一条后 `aa force-stop`，重启后 `list(1,20)` 确认还在 | 无 |
| 编辑结果保存：updateEdited 修改 edited_boxes_json 后 getDetail 分离 raw/edited | 对比同一 recordId 的 rawBoxes 与 editedBoxes | 无 |
| 时间边界：countByTimeRange(nowMs, nowMs) 闭区间 | 插入时间戳后 count 必须 ≥ 1 | 无 |
| 组合筛选：list(1, 20, ImageOrigin.CAMERA) 仅返回相机 | 先存 camera + gallery 各一条，再查 | 无 |
| 分页稳定性：同毫秒多记录翻页不丢失/重复 | 一次快速保存 3 条同毫秒，list 第 1 页全部在 | 无 |
| DB 失败处理：ensureStoreForSave 初始化失败时回滚图像 | mock 存储层抛错，看 RecordService.deleteImages 被调用（日志） | 需注入测试 |
| save 幂等：同 pathId 连续两次 save 只产生一行 | 日志应打印 "Duplicate save for …, idempotent return" | 无 |
| delete 幂等：删除不存在的 id 返回 {deleted:false} 不抛 | 直接调 `delete('rec_missing')` | 无 |
| listByClass：原始或编辑任一匹配 | 一记录原始含 cup、编辑改为 mug，用 classId=cup 仍能查到 | 无 |

全部可在 arm64 API 24 模拟器（VoiceCalculator_API24, 127.0.0.1:5555）上执行。当前 BLK-8/BLK-9/BLK-4 已解除，第一阶段推理链路可用，设备端可触发真实保存流程。

## 10. 已知限制与后续迭代

| 项 | 说明 | 阶段 |
| --- | --- | --- |
| 单表 JSON 存 boxes | 本阶段不支持跨记录框级查询（"所有记录中 cup 出现频次"）；需跨记录统计时拆 `record_boxes` 表并 bump version | 后续 |
| listByClass 内存过滤 | 随记录规模增长可能变成 O(N) 扫描；1000+ 条数据下建议拆表 | 后续 |
| 图像文件绝对路径也入库 | 与 Agent 1 协调时确认相对路径归一化由 RecordService 内部做；如果 Agent 1 内部改 `originalPath` 为相对，RecordService 仍兼容 | 已兼容 |
| EntryAbility 集成未写入 | 见第 6 节 Agent 0 部分；Agent 0 在 `loadContent` 前串接 RecordService.initialize → RecognitionService.setContext → loadContent | Agent 0 |
| sync_state / upload_attempts / server_revision | phase-1-data-contract 中定义，本阶段不实现；留到后续 RDB v2 迁移 bump user_version 追加列 | 后续 |
| RecordService ohosTest | 本阶段未补 Hypium 覆盖（save 幂等 / list 分页 / hasMore / updateEdited / delete 幂等 / countByTimeRange 边界 / listByClass）；构建通过为静态门禁，设备行为仍需 ohosTest 在 arm64 模拟器 / 真机上跑通。建议 Agent 5（测试负责人）在第二阶段验收前补齐，或 Agent 4 在设备端验证后再补 | Agent 5（建议） / 跟进 |
| BenchmarkRunner.ets / EntryAbility.ets 构建波动 | 非本 Agent 责任文件，并发编辑时有短暂编译失败；构建当前稳定通过 | Agent 0 / Agent 2 |

## 11. 变更清单小结

| 维度 | 状态 |
| --- | --- |
| RDB 打开 + 版本迁移 | ✅ RecordDatabase.open + migrate + runInTransaction |
| 单表 records 建表 + 索引 | ✅ version=1，2 个索引 |
| save 幂等（pathId 优先 + 冲突回退自生成 + 文件回滚） | ✅ SAVE_ID_RETRY=3 |
| updateEdited（仅 edited_boxes_json） | ✅ 事务内先校验存在 |
| list（分页 + hasMore + sourceFilter + 稳定排序） | ✅ LIMIT n+1 判 hasMore |
| getDetail / delete 幂等 / listByClass / countByTimeRange | ✅ |
| 启动孤儿清理（record_id 集合 + 宽限 + 上限） | ✅ 委托 ImageAssetStore |
| 与 Agent 1 图像删除 / 回滚协调 | ✅ 统一 ImageAssetStore.deleteImages |
| 构建 | ✅ 0 error，490 ms |
| 真机 / ohosTest / 端到端 | 待 |

## 12. 第三阶段任务一复审：存储服务确认（2026-10-22）

### 12.1 构建与接口一致性

| 检查项 | 结论 |
| --- | --- |
| `RecordService.ets` + `RecordDatabase.ets` 构建 | ✅ `./scripts/build-app.sh` BUILD SUCCESSFUL（33 tasks），storage 目录 0 error |
| `RecordServiceApi` 实现 | ✅ 8 个方法签名与 `models/RecordTypes.ets` 一致（ArkTS 编译校验结构类型） |
| `docs/phase-2-contract.md` 第 4 节 API | ✅ list/getDetail/delete/listByClass/countByTimeRange/dispose/updateEdited 语义一致 |
| 契约 4.2 的 `save(detectionResult, …)` 示例 | ⚠ 示例按 `DetectionResult` 调用，冻结类型 `RecordSaveInput` 只含存储必需字段；已新增适配函数解决（12.2） |

### 12.2 save 输入结构调整（不改 Agent 0 的 RecordTypes.ets）

新增导出函数（`services/storage/RecordService.ets`）：

```ts
export function toRecordSaveInput(result: DetectionResult): RecordSaveInput
```

页面调用改为：

```ts
const result = await RecognitionService.getInstance().recognize(image, options);
const assets = await ImageAssetStore.getInstance().persistCapturedImage(context, image);
const recordId = await RecordService.getInstance().save(
  toRecordSaveInput(result), source, assets.originalPath, assets.thumbnailPath);
```

映射关系：`boxes`、`modelId`、`modelSha256`、`imageWidth/Height`、`timing.coldStart`、`timing.totalMs`、`executionMode`。`requestId`、`imageId`、阈值、`recognizedAtMs` 属上传阶段字段，本阶段 RDB 不落库。

### 12.3 需要 Agent 0 同步的文档/类型调整（建议）

1. `phase-2-contract.md` 第 4.2 节调用示例改为 `save(toRecordSaveInput(result), …)`，或直接引用 `RecordSaveInput`。
2. 若上传阶段需要 `recognizedAtMs`/`requestId`/`imageId`/阈值，建议 RDB v2 增加列（`recognized_at_ms`、`request_id`、`image_id`、`confidence_threshold`、`iou_threshold`、`max_detections`）并 bump `RECORD_DB_VERSION=2`，同时扩展 `RecordSaveInput`；本次未改冻结类型。
3. `RecordService.save` 的“重复保存”当前依赖 Agent 1 的 `{assetId}_original.jpg` 命名；若 Agent 1 调整命名，需同步 `extractAssetId`。
