# 本轮 Agent 任务分配（2026-10-22）

> 本轮范围：第一阶段收尾 + 第二阶段 UI 接入 + 第三阶段启动。
> **验收策略调整：本轮及后续轮次暂不要求真机验收，以"构建通过 + 静态检查 + 模拟器运行"为门禁。** 真机数据留作交付前补验。
>
> 执行顺序：Agent 0 先完成契约同步与入口初始化 → Agent 1/2/3 并行（第二阶段 UI 与第一阶段复验）→ Agent 4 第三阶段后端 → Agent 5 测试与验收 → Agent 0 最终集成。

## 公共约束

1. 所有改动后必须运行 `./scripts/build-app.sh`，记录构建结果（成功/失败/警告）。
2. 验收证据以"构建日志 + 模拟器截图/hilog"为准，不要求真机。
3. 不私自修改共享类型（`models/**`）；确需改动时写入交接报告由 Agent 0 协调。
4. 每个 agent 完成后写 `docs/phase-2-agent-N-report.md`（第二阶段）或更新现有报告。
5. 真机相关验证项一律标记为"待真机补验"，不阻塞本轮验收。

---

## Agent 0 — 架构与集成（先执行）

**本轮任务：**

1. **同步第二阶段契约与实际实现**
   - 依据 [phase-2-agent-1-report.md](phase-2-agent-1-report.md) 第 1 节的统一决定，更新 [phase-2-contract.md](phase-2-contract.md)：
     - 缩略图最长边改为 480 px（契约 §2.3 仍写 320）
     - 文件布局改为扁平 `records/{assetId}_original.jpg`（契约仍写 `records/img/<imageId>/` 子目录）
     - 孤儿清理 API 改为 `cleanupOrphanRecordImages(context, referencedIds, gracePeriodMs?, maxCount?)`
     - 追认 mtime 10 分钟宽限期（`ORPHAN_GRACE_PERIOD_MS`）
   - 确认 [RecordTypes.ets](../app/entry/src/main/ets/models/RecordTypes.ets) 常量与契约一致。

2. **EntryAbility 初始化链路**
   - 修改 [EntryAbility.ets](../app/entry/src/main/ets/entryability/EntryAbility.ets)，在 `loadContent` 前插入：
     ```ts
     RecordService.getInstance().initialize(this.context);
     RecognitionService.getInstance().setContext(this.context);
     ```
   - `onDestroy` 中调用 `RecordService.getInstance().dispose()`。
   - 保持现有 `maybeRunBenchmark` 逻辑不变。

3. **第一阶段收尾验收**
   - 确认 BLK-8（模型复制）、BLK-9（SHA-256 算法名）、BLK-4（初始化重试）、BLK-7（拍照入口）的源码修复已合入。
   - 运行构建，更新 [phase-1-review.md](phase-1-review.md) 的阻塞项状态（已修复的标记为"源码已修复，待模拟器复验"）。
   - 协调真机相关项（E4、前后相机、方向、性能）全部标记"待真机补验"。

4. **第三阶段接口契约准备**
   - 基于 [api-plan.md](api-plan.md) 制定第三阶段最小接口契约（JWT 登录/刷新、模型版本检查、记录上传幂等、云端查询分页），写入 `docs/phase-3-contract.md`（新建）。
   - 明确客户端 `services/network/` 与 `services/sync/` 的导出接口边界。

**交付物：** 更新后的 phase-2-contract.md、EntryAbility.ets、phase-1-review.md、新建 phase-3-contract.md。
**验收：** 构建通过；契约与代码常量一致。

---

## Agent 1 — 图像采集

**本轮任务：**

1. **ImageAssetStore 复验**
   - 确认 [ImageAssetStore.ets](../app/entry/src/main/ets/services/imaging/ImageAssetStore.ets) 与第二阶段契约对齐（480 缩略图、扁平布局、mtime 宽限）。
   - 运行构建，确认无新增编译错误。

2. **相机组件接入确认**
   - 确认 [CameraPreview.ets](../app/entry/src/main/ets/components/camera/CameraPreview.ets) 已被 [Index.ets](../app/entry/src/main/ets/pages/Index.ets) 正确引用（BLK-7 修复）。
   - 若 Agent 3 在历史页面中需要图片解码显示（缩略图/原图），提供 `PixelMap` 解码辅助方法或确认现有 `PreviewPixelMap.ets` 可复用。

3. **模拟器图像持久化验证（可选，如模拟器可用）**
   - 在模拟器上验证 `persistCapturedImage` 能写出原图 + 缩略图，缩略图最长边 ≤ 480。
   - 验证 `deleteImages` 幂等、`resolveAbsolutePath` 重启后可解析。
   - 若模拟器不可用，记录"待模拟器/真机补验"。

**交付物：** 更新 phase-2-agent-1-report.md 的验证状态。
**验收：** 构建通过；ImageAssetStore API 与契约一致。

---

## Agent 2 — 端侧推理

**本轮任务：**

1. **阻塞项修复确认**
   - 确认 [ModelLoader.ets](../app/entry/src/main/ets/services/inference/ModelLoader.ets) 中：
     - BLK-8：`getRawFileContent` 返回的 `Uint8Array` 已复制到新 `ArrayBuffer`，`writeSync` 使用 `{offset, length}` 参数。
     - BLK-9：`createMd('SHA256')`（无连字符）。
   - 确认 [RecognitionService.ets](../app/entry/src/main/ets/services/inference/RecognitionService.ets) 中：
     - BLK-4：`initialize()` 在 `available=false` 时不缓存，允许重试。

2. **推理单元测试（BLK-3）**
   - 在 `app/entry/src/ohosTest/` 或同级测试目录下创建推理算法单元测试，覆盖：
     - letterbox 缩放与 padding 记录（横图、竖图、方图）
     - NCHW 转换正确性
     - NMS 同类抑制、异类保留
     - 坐标还原到原图像素空间
     - 空输出、错误形状处理
     - 阈值边界
   - 测试应可在不加载真实 ONNX session 的情况下运行（纯算法测试），用构造的假输出张量验证后处理逻辑。

3. **模型文档修正**
   - 更新 [phase-1-model.md](phase-1-model.md)：将 opset 从 12 修正为 18（已由 `onnx.load()` 验证）。
   - 确认输入 `images [1,3,640,640]`、输出 `output0 [1,84,8400]`、80 类无 objectness。

4. **模拟器推理复验（如模拟器可用）**
   - 重装 HAP，确认 hilog 出现 `模型复制并校验通过`。
   - 跑通一次相册选图 → 识别流程，确认检测框输出。
   - 若模拟器相册为空（BLK-10），用 `hdc file send` 推送测试图到模拟器或记录限制。

**交付物：** 推理单元测试代码、更新后的 phase-1-model.md、phase-1-agent-2-report.md。
**验收：** 构建通过；单元测试编译通过；模型文档与实际元数据一致。

---

## Agent 3 — 页面与交互

**本轮任务（重点）：**

1. **保存识别入口**
   - 在 [Index.ets](../app/entry/src/main/ets/pages/Index.ets) 识别成功后增加"保存识别"按钮。
   - 保存流程（参照 [phase-2-contract.md](phase-2-contract.md) §4.3）：
     ```ts
     const assets = await ImageAssetStore.getInstance().persistCapturedImage(context, currentImage);
     try {
       const recordId = await RecordService.getInstance().save(
         { boxes: result.boxes, modelId: result.modelId, modelSha256: result.modelSha256,
           imageWidth: result.imageWidth, imageHeight: result.imageHeight,
           coldStart: result.timing.coldStart, totalMs: result.timing.totalMs,
           executionMode: result.executionMode },
         currentImage.origin,
         assets.original.relativePath, assets.thumbnail.relativePath);
       // 提示保存成功
     } catch (e) {
       // 映射 RecordErrorCode 提示
       await ImageAssetStore.getInstance().deleteImages(context, assets.originalPath, assets.thumbnailPath);
     }
     ```
   - 保存成功后显示 Toast"已保存到历史记录"。

2. **历史列表页**
   - 新建 `components/recognition/RecordList.ets`（或 `pages/RecordList.ets`），实现：
     - 调用 `RecordService.getInstance().list(page, pageSize, sourceFilter?)` 分页加载
     - 展示缩略图、时间、来源、物品数量、执行模式、耗时
     - 支持按来源（相机/相册）筛选
     - 点击进入详情页
   - 在首页增加"历史记录"入口按钮。

3. **历史详情页**
   - 新建 `components/recognition/RecordDetail.ets`，实现：
     - 调用 `getDetail(recordId)` 获取原始框与编辑后框
     - 绘制检测框（优先显示编辑后框，可切换查看原始框）
     - 支持编辑（改类别、删除误检项）→ 调用 `updateEdited(recordId, editedBoxes)`
     - 支持删除记录 → 调用 `delete(recordId)`，删除后返回列表

4. **页面路由**
   - 更新 `main_pages.json` 注册新页面（如用 `pages/RecordList.ets` 和 `pages/RecordDetail.ets`）。
   - 或使用 `Navigation`/`NavPathStack` 在 Index 内导航，避免多页面。

**交付物：** 保存入口、RecordList、RecordDetail、路由配置、phase-1-agent-3-report.md / phase-2-agent-3-report.md。
**验收：** 构建通过；保存流程代码逻辑正确；列表/详情页 UI 可渲染（模拟器验证如可用）。

---

## Agent 4 — 数据与端云协同

**本轮任务：**

1. **存储服务确认**
   - 确认 [RecordService.ets](../app/entry/src/main/ets/services/storage/RecordService.ets) 与 [RecordDatabase.ets](../app/entry/src/main/ets/services/storage/RecordDatabase.ets) 构建通过、API 与 [phase-2-contract.md](phase-2-contract.md) 一致。
   - 如有必要，配合 Agent 3 调整 `save` 输入结构（当前 `RecordSaveInput` 与 `DetectionResult` 字段需对齐）。

2. **第三阶段后端实现**（新建）
   - 在 `backend/app/` 下实现以下模块：
     - `core/config.py`：配置加载（JWT secret、模型版本、数据库路径）
     - `core/auth.py`：JWT 签发/验证/刷新，设备标识 + 密钥换取 token，401 处理
     - `models/`：SQLAlchemy 模型（Device、Record、ModelVersion）
     - `schemas/`：Pydantic 请求/响应结构
     - `api/auth.py`：`POST /api/auth/login`、`POST /api/auth/refresh`
     - `api/models.py`：`GET /api/models/version`、`GET /api/models/download`
     - `api/records.py`：`POST /api/records`（批量、幂等）、`GET /api/records`（时间/类别筛选、分页）
     - `services/`：业务逻辑
   - 使用 SQLite 作为开发数据库（`backend/data/app.db`）。
   - 统一错误码规范（与客户端 `RecognitionErrorCode`/`RecordErrorCode` 对应）。

3. **后端测试**
   - 用 FastAPI TestClient 编写核心接口测试：登录、刷新、幂等上传、筛选分页。
   - 启动后端，验证 `/health` 与 `/docs` 可用。

**交付物：** 后端业务代码、测试、更新 phase-2-agent-4-report.md / 新建 phase-3-agent-4-report.md。
**验收：** 后端启动成功；核心接口测试通过；`/docs` 可交互。

---

## Agent 5 — 测试与质量

**本轮任务：**

1. **第一阶段复验矩阵更新**
   - 更新 [phase-1-test-plan.md](phase-1-test-plan.md)：将真机项标记为"待真机补验"，模拟器项保留。
   - 配合 Agent 2 确认推理单元测试覆盖度。

2. **第二阶段存储测试**
   - 若 Agent 4 尚未编写 RDB 测试，补充存储层测试（save 幂等、list 分页、hasMore、updateEdited、delete 幂等、countByTimeRange 边界、listByClass）。
   - 测试可在模拟器或纯单元层面执行。

3. **模拟器端到端验收**
   - 如模拟器可用，执行完整流程：拍照/选图 → 识别 → 保存 → 历史列表 → 详情 → 编辑 → 删除。
   - 记录截图与 hilog，更新验收报告。
   - 如模拟器不可用，编写详细的人工验收操作手册（步骤、预期、实际记录位）。

4. **静态检查清单**
   - 确认全量构建 0 错误。
   - 检查无遗留的 `console.log`/TODO/FIXME 阻塞项。
   - 检查错误码映射一致性（采集→推理→存储→页面）。

**交付物：** 更新测试计划、存储测试、验收报告（模拟器证据或操作手册）。
**验收：** 构建通过；测试用例编译通过；验收文档完整。

---

## 本轮完成定义（DoD）

| 阶段 | 完成标准 |
| --- | --- |
| 第一阶段 | 构建通过；BLK-8/9/4/7 源码修复确认；推理单元测试交付；phase-1-review.md 更新阻塞项为"待模拟器/真机复验" |
| 第二阶段 | EntryAbility 初始化链路接入；保存入口可用；历史列表+详情页实现；构建通过 |
| 第三阶段 | 后端核心接口（auth/model/records）实现并可启动；phase-3-contract.md 落地 |
| 验收 | 模拟器端到端流程跑通（如可用）；测试文档完整 |

**下一轮预告：** 第三阶段客户端鉴权与同步（network/sync）、端云联调、第四阶段整体验收。
