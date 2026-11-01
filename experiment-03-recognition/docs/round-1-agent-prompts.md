# 本轮（Round 1）各 Agent 完整 Prompt

> 日期：2026-10-22。本轮范围：第一阶段收尾 + 第二阶段 UI 接入 + 第三阶段启动。
> **验收策略：本轮不要求真机验收，以"构建通过 + 静态检查 + 模拟器运行"为门禁。** 真机项一律标记"待真机补验"，不阻塞本轮。
>
> 以下每个代码块就是该 agent 的完整 prompt，可直接复制使用。

## 公共引导语（每个 agent prompt 前附加）

```text
项目根目录：/Users/avery/Desktop/hongmeng/SmartItemRecognitionAssistant

先阅读项目根目录 AGENTS.md，按其文档地图定位当前任务涉及的代码与文档。
再阅读 docs/round-1-agent-tasks.md 了解本轮整体安排。

本轮公共约束：
1. 所有改动后必须运行 ./scripts/build-app.sh，记录构建结果。
2. 验收证据以"构建日志 + 模拟器截图/hilog"为准，不要求真机。
3. 不私自修改共享类型（models/**）；确需改动时写入交接报告由 Agent 0 协调。
4. 完成后写 docs/phase-2-agent-N-report.md（第二阶段）或更新现有报告。
5. 真机相关验证项标记为"待真机补验"，不阻塞本轮验收。
```

---

## Agent 0 — 架构与集成（先执行）

```text
职责：本轮作为总协调与集成负责人。你独占 docs/phase-2-contract.md、docs/phase-1-review.md、
app/entry/src/main/ets/models/ 共享类型，以及确有必要的入口文件。
本轮获得跨模块修复权限，但修改前先确认相关 agent 已结束编辑。

任务一：同步第二阶段契约与实际实现
依据 docs/phase-2-agent-1-report.md 第 1 节的统一决定，更新 docs/phase-2-contract.md：
- 缩略图最长边改为 480 px（契约 §2.3 仍写 320）
- 文件布局改为扁平 records/{assetId}_original.jpg + {assetId}_thumb.jpg
  （契约仍写 records/img/<imageId>/ 子目录）
- 孤儿清理 API 改为 cleanupOrphanRecordImages(context, referencedIds, gracePeriodMs?, maxCount?)
- 追认 mtime 10 分钟宽限期（ORPHAN_GRACE_PERIOD_MS）
确认 app/entry/src/main/ets/models/RecordTypes.ets 常量与契约一致。

任务二：EntryAbility 初始化链路
修改 app/entry/src/main/ets/entryability/EntryAbility.ets，在 loadContent 前插入：
  RecordService.getInstance().initialize(this.context);
  RecognitionService.getInstance().setContext(this.context);
onDestroy 中调用 RecordService.getInstance().dispose()。
保持现有 maybeRunBenchmark 逻辑不变。

任务三：第一阶段收尾验收
确认以下阻塞项的源码修复已合入：
- BLK-8：ModelLoader.ets 中 getRawFileContent 的 Uint8Array 已复制到新 ArrayBuffer，
  writeSync 使用 {offset, length} 参数
- BLK-9：ModelLoader.ets 中 createMd('SHA256')（无连字符）
- BLK-4：RecognitionService.ets 中 initialize() 在 available=false 时不缓存，允许重试
- BLK-7：Index.ets 已接入 CameraPreview 全屏覆盖层
运行构建，更新 docs/phase-1-review.md 的阻塞项状态（已修复标记为"源码已修复，待模拟器复验"）。
真机相关项（E4、前后相机、方向、性能）全部标记"待真机补验"。

任务四：第三阶段接口契约准备
基于 docs/api-plan.md 制定第三阶段最小接口契约，写入新建 docs/phase-3-contract.md：
- JWT 登录（设备标识+密钥换 token）与刷新
- 模型版本检查与下载
- 记录批量上传（幂等，recordId 去重）
- 云端历史查询（时间范围、类别筛选、分页）
明确客户端 services/network/ 与 services/sync/ 的导出接口边界。

交付物：更新后的 phase-2-contract.md、EntryAbility.ets、phase-1-review.md、新建 phase-3-contract.md。
验收：构建通过；契约与代码常量一致。
```

---

## Agent 1 — 图像采集

```text
职责：实现拍照与相册选图，并向其他模块提供契约规定的图像来源。
你独占：app/entry/src/main/ets/services/camera/、app/entry/src/main/ets/components/camera/、
app/entry/src/main/ets/services/imaging/ImageAssetStore.ets，以及 module.json5 中相机权限。
首页由 Agent 3 维护。

任务一：ImageAssetStore 复验
确认 app/entry/src/main/ets/services/imaging/ImageAssetStore.ets 与第二阶段契约对齐：
- 缩略图最长边 480 px
- 文件布局扁平 records/{assetId}_original.jpg
- 孤儿清理 mtime 10 分钟宽限
运行构建，确认无新增编译错误。

任务二：相机组件接入确认
确认 app/entry/src/main/ets/components/camera/CameraPreview.ets 已被
app/entry/src/main/ets/pages/Index.ets 正确引用（BLK-7 修复）。
若 Agent 3 在历史页面中需要图片解码显示（缩略图/原图），提供 PixelMap 解码辅助方法
或确认现有 components/recognition/PreviewPixelMap.ets 可复用。

任务三：模拟器图像持久化验证（如模拟器可用）
在模拟器上验证 persistCapturedImage 能写出原图 + 缩略图，缩略图最长边 ≤ 480。
验证 deleteImages 幂等、resolveAbsolutePath 重启后可解析。
若模拟器不可用，记录"待模拟器/真机补验"。

交付物：更新 docs/phase-2-agent-1-report.md 的验证状态。
验收：构建通过；ImageAssetStore API 与契约一致。
```

---

## Agent 2 — 端侧推理

```text
职责：实现真实 YOLOv13 端侧识别和异步执行。
你独占：app/entry/src/main/ets/services/inference/、app/entry/src/main/ets/tasks/、
app/entry/src/main/resources/rawfile/models/，以及推理相关测试目录。

任务一：阻塞项修复确认
确认 app/entry/src/main/ets/services/inference/ModelLoader.ets 中：
- BLK-8：getRawFileContent 返回的 Uint8Array 已复制到新 ArrayBuffer，
  writeSync(file.fd, copy.buffer, {offset, length})
- BLK-9：createMd('SHA256')（无连字符）
确认 app/entry/src/main/ets/services/inference/RecognitionService.ets 中：
- BLK-4：initialize() 在 available=false 时不缓存 available，允许重试

任务二：推理单元测试（BLK-3）
在 app/entry/src/ohosTest/ 或同级测试目录下创建推理算法单元测试，覆盖：
- letterbox 缩放与 padding 记录（横图、竖图、方图）
- NCHW 转换正确性
- NMS 同类抑制、异类保留
- 坐标还原到原图像素空间
- 空输出、错误形状处理
- 阈值边界
测试应可在不加载真实 ONNX session 的情况下运行（纯算法测试），
用构造的假输出张量验证后处理逻辑。

任务三：模型文档修正
更新 docs/phase-1-model.md：将 opset 从 12 修正为 18（已由 onnx.load() 验证）。
确认输入 images [1,3,640,640]、输出 output0 [1,84,8400]、80 类无 objectness。

任务四：模拟器推理复验（如模拟器可用）
重装 HAP，确认 hilog 出现"模型复制并校验通过"。
跑通一次相册选图 → 识别流程，确认检测框输出。
若模拟器相册为空（BLK-10），用 hdc file send 推送测试图或记录限制。

交付物：推理单元测试代码、更新后的 phase-1-model.md、phase-1-agent-2-report.md。
验收：构建通过；单元测试编译通过；模型文档与实际元数据一致。
```

---

## Agent 3 — 页面与交互（本轮重点）

```text
职责：完成第一阶段用户界面，并接入第二阶段保存与历史功能。
你独占：app/entry/src/main/ets/pages/Index.ets、app/entry/src/main/ets/components/recognition/。
保持公共类型由 Agent 0 管理、采集组件由 Agent 1 管理、存储服务由 Agent 4 管理。

任务一：保存识别入口
在 app/entry/src/main/ets/pages/Index.ets 识别成功后增加"保存识别"按钮。
保存流程（参照 docs/phase-2-contract.md §4.3）：
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
保存成功后显示 Toast"已保存到历史记录"。

任务二：历史列表页
新建 components/recognition/RecordList.ets（或 pages/RecordList.ets），实现：
- 调用 RecordService.getInstance().list(page, pageSize, sourceFilter?) 分页加载
- 展示缩略图、时间、来源、物品数量、执行模式、耗时
- 支持按来源（相机/相册）筛选
- 点击进入详情页
在首页增加"历史记录"入口按钮。

任务三：历史详情页
新建 components/recognition/RecordDetail.ets，实现：
- 调用 getDetail(recordId) 获取原始框与编辑后框
- 绘制检测框（优先显示编辑后框，可切换查看原始框）
- 支持编辑（改类别、删除误检项）→ 调用 updateEdited(recordId, editedBoxes)
- 支持删除记录 → 调用 delete(recordId)，删除后返回列表

任务四：页面路由
更新 app/entry/src/main/resources/base/profile/main_pages.json 注册新页面
（如用 pages/RecordList.ets 和 pages/RecordDetail.ets），
或使用 Navigation/NavPathStack 在 Index 内导航。

交付物：保存入口、RecordList、RecordDetail、路由配置、
docs/phase-1-agent-3-report.md / docs/phase-2-agent-3-report.md。
验收：构建通过；保存流程代码逻辑正确；列表/详情页 UI 可渲染。
```

---

## Agent 4 — 数据与端云协同

```text
职责：第二阶段 RDB 存储服务 + 第三阶段后端业务接口。
你独占：app/entry/src/main/ets/services/storage/、backend/app/ 下的业务模块。
不修改 models/RecordTypes.ets（Agent 0），但可在交接报告中提出调整需求。

任务一：存储服务确认
确认 app/entry/src/main/ets/services/storage/RecordService.ets 与 RecordDatabase.ets
构建通过、API 与 docs/phase-2-contract.md 一致。
如有必要，配合 Agent 3 调整 save 输入结构
（当前 RecordSaveInput 与 DetectionResult 字段需对齐）。

任务二：第三阶段后端实现（新建）
在 backend/app/ 下实现以下模块：
- core/config.py：配置加载（JWT secret、模型版本、数据库路径）
- core/auth.py：JWT 签发/验证/刷新，设备标识+密钥换取 token，401 处理
- models/：SQLAlchemy 模型（Device、Record、ModelVersion）
- schemas/：Pydantic 请求/响应结构
- api/auth.py：POST /api/auth/login、POST /api/auth/refresh
- api/models.py：GET /api/models/version、GET /api/models/download
- api/records.py：POST /api/records（批量、幂等）、GET /api/records（时间/类别筛选、分页）
- services/：业务逻辑
使用 SQLite 作为开发数据库（backend/data/app.db）。
统一错误码规范（与客户端 RecognitionErrorCode/RecordErrorCode 对应）。

任务三：后端测试
用 FastAPI TestClient 编写核心接口测试：登录、刷新、幂等上传、筛选分页。
启动后端，验证 /health 与 /docs 可用。

交付物：后端业务代码、测试、更新 phase-2-agent-4-report.md / 新建 phase-3-agent-4-report.md。
验收：后端启动成功；核心接口测试通过；/docs 可交互。
```

---

## Agent 5 — 测试与质量

```text
职责：测试框架、用例、静态检查与验收证据整理。
你维护：docs/phase-1-test-plan.md、docs/phase-1-review.md 的验收部分、测试目录。
不修改业务代码，发现缺陷写入报告并通知对应负责人。

任务一：第一阶段复验矩阵更新
更新 docs/phase-1-test-plan.md：将真机项标记为"待真机补验"，模拟器项保留。
配合 Agent 2 确认推理单元测试覆盖度。

任务二：第二阶段存储测试
若 Agent 4 尚未编写 RDB 测试，补充存储层测试：
- save 幂等（同 pathId 重复提交只产生一行）
- list 分页与 hasMore
- updateEdited 只改 edited_boxes_json
- delete 幂等（不存在返回 deleted=false）
- countByTimeRange 边界（闭区间）
- listByClass（原始或编辑任一匹配）
测试可在模拟器或纯单元层面执行。

任务三：模拟器端到端验收
如模拟器可用，执行完整流程：拍照/选图 → 识别 → 保存 → 历史列表 → 详情 → 编辑 → 删除。
记录截图与 hilog，更新验收报告。
如模拟器不可用，编写详细的人工验收操作手册（步骤、预期、实际记录位）。

任务四：静态检查清单
- 确认全量构建 0 错误
- 检查无遗留的 console.log/TODO/FIXME 阻塞项
- 检查错误码映射一致性（采集→推理→存储→页面）

交付物：更新测试计划、存储测试、验收报告（模拟器证据或操作手册）。
验收：构建通过；测试用例编译通过；验收文档完整。
```

---

## 执行顺序与依赖

```
Agent 0（契约同步 + EntryAbility + phase-3-contract）
    │
    ├── Agent 1（ImageAssetStore 复验 + 相机接入确认）
    ├── Agent 2（推理阻塞项确认 + 单元测试 + 模型文档）
    └── Agent 3（保存入口 + 历史列表/详情页）  ← 依赖 Agent 0 的 EntryAbility
           │
           └── Agent 4（存储确认 + 后端实现）
                  │
                  └── Agent 5（测试 + 验收）
                         │
                         └── Agent 0（最终集成验收）
```

## 本轮完成定义（DoD）

| 阶段 | 完成标准 |
| --- | --- |
| 第一阶段 | 构建通过；BLK-8/9/4/7 源码修复确认；推理单元测试交付；phase-1-review.md 更新 |
| 第二阶段 | EntryAbility 初始化链路接入；保存入口可用；历史列表+详情页实现；构建通过 |
| 第三阶段 | 后端核心接口（auth/model/records）实现并可启动；phase-3-contract.md 落地 |
| 验收 | 模拟器端到端流程跑通（如可用）；测试文档完整 |
