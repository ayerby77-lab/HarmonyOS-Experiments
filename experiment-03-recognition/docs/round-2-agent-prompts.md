# Round 2 各 Agent 完整 Prompt（2026-10-22）

> 基于 Round 1 实际交付审查后制定。
> **验收策略：仍不要求真机验收，以"构建通过 + 模拟器运行 + 后端测试"为门禁。**

---

## Round 1 审查结论（必读）

### ✅ Round 1 已完成并验证
| Agent | 交付物 | 验证 |
|---|---|---|
| 0 | EntryAbility 初始化链路、phase-2-contract 同步（480px/扁平布局）、phase-3-contract 新建 | 构建通过 |
| 2 | 推理单元测试 19 例、phase-1-model opset=18 | 测试已编写 |
| 3 | 保存入口、RecordList.ets、RecordDetail.ets、路由注册 | 构建通过 |
| 4 | 后端完整实现（auth/models/records API + core/models/schemas/services） | 24 个 pytest 全部通过 |
| 5 | ImageAssetStore.test.ets | 构建通过 |
| — | 全量构建 | BUILD SUCCESSFUL |

### ⚠️ Round 1 遗留阻塞项（Round 2 必须修复）
| 编号 | 问题 | 影响 | 负责 |
|---|---|---|---|
| **BLK-12** | `OnnxBridge.createOnnxTensor` → `new OnnxTensor(data, shape, 0)` 原生 SIGSEGV（`__stack_chk_fail`），OnnxSessionWrapper 路径推理完全不可用 | 所有识别、性能、编辑用例阻塞 | Agent 2 |
| **BLK-11** | `CameraPreview.aboutToDisappear` 中 `off('applicationStateChange', callback)` 抛参数错误崩溃 | 拍照入口每次退出即崩溃 | Agent 1 |
| **BLK-13** | 12 张 benchmark 图 + bench_01_cup.jpg 位于 `resources/rawfile/`，污染生产 HAP | 生产包含测试资产 | Agent 0 |
| **Q-19** | `ohosTest/module.json5` 配置 `name: entry, type: entry`，测试 HAP 无法执行（`aa test` 报 App died） | 19 例推理测试无执行证据 | Agent 2/5 |

### 关键技术线索
- **BLK-12**：存在两条推理路径——`OnnxBridge`（TS `@ohos/onnxruntime`，崩溃点）和 `NativeInferenceBridge`（C++ NAPI `libonnx_native.so`，EntryAbility smoke test 使用，可能绕过崩溃）。Agent 2 可尝试切换或修复。
- **BLK-11**：HarmonyOS `applicationContext.off(event, callback)` 的 callback 参数匹配可能有问题，可改为 `off(event)` 无参形式或保存注册时的回调引用。
- **Q-19**：ohosTest 模块应为独立测试模块，`name` 通常为 `entry_test` 或保持 `entry` 但 `type` 需正确。参考 ohosTest 标准模板。

---

## 公共引导语（每个 agent prompt 前附加）

```text
项目根目录：/Users/avery/Desktop/hongmeng/SmartItemRecognitionAssistant

先阅读 AGENTS.md，按文档地图定位代码。
再阅读 docs/round-2-agent-prompts.md（本文件）了解本轮任务。
再阅读 docs/phase-1-review.md 了解第一阶段阻塞项详情。

本轮公共约束：
1. 所有改动后必须运行 ./scripts/build-app.sh，记录构建结果。
2. 验收以"构建日志 + 模拟器截图/hilog + 后端测试"为准，不要求真机。
3. 不私自修改共享类型（models/**）；确需改动时写入交接报告由 Agent 0 协调。
4. 完成后更新 docs/phase-1-agent-N-report.md 或 docs/phase-2-agent-N-report.md。
5. 真机相关验证项标记为"待真机补验"。
```

---

## Agent 0 — 架构与集成（先执行）

```text
职责：总协调与集成。独占共享契约、入口文件、构建配置。

任务一：修复 BLK-13（测试资产移出 rawfile）
将以下测试资产从 app/entry/src/main/resources/rawfile/ 移出：
- benchmark_images/ 目录（12 张图）
- bench_01_cup.jpg
方案：移到 tests/assets/images/（已有目录）或新建 tests/benchmark_assets/。
更新 BenchmarkRunner.ets 中读取路径，改为从应用沙箱或测试注入路径读取，
确保普通构建不包含这些文件。
更新 .gitignore 确认不跟踪大文件。

任务二：修复 Q-19（ohosTest 模块配置）
检查 app/entry/src/ohosTest/module.json5：
当前 "name": "entry", "type": "entry" 导致测试 HAP 与 entry HAP 冲突。
参考 HarmonyOS ohosTest 标准模板修正：
- name 保持 "entry" 或改为测试模块名
- type 应为正确的测试类型
- 确认 build-profile.json5 中 ohosTest 模块配置正确
目标：aa test 能正常启动测试模块并执行 19 例推理测试。

任务三：第三阶段客户端网络层契约落地
依据 docs/phase-3-contract.md，在 app/entry/src/main/ets/services/network/ 下创建：
- HttpClient.ets：封装 @ohos.net.http 请求，统一超时/错误码
- AuthService.ets：JWT 登录（设备标识+密钥）、token 存储、自动刷新、401 处理
- ModelClient.ets：模型版本检查、下载、替换本地模型
明确导出接口，供 services/sync/ 和页面调用。
不实现同步逻辑（留给 Agent 4），只实现网络与鉴权。

任务四：集成协调
- 确认 Agent 1 修复 BLK-11 后 CameraPreview 生命周期正常
- 确认 Agent 2 修复 BLK-12 后推理可运行
- 构建通过后更新 docs/phase-1-review.md 阻塞项状态

交付物：rawfile 清理、ohosTest 配置修复、services/network/ 三个模块。
验收：构建通过；rawfile 不含测试图；ohosTest 可执行（如模拟器可用）；network 模块编译通过。
```

---

## Agent 1 — 图像采集

```text
职责：相机采集与图像持久化。独占 services/camera/、components/camera/、services/imaging/。

任务一：修复 BLK-11（相机组件退出崩溃）
定位 app/entry/src/main/ets/components/camera/CameraPreview.ets 第 149 行：
  application.getApplicationContext().off('applicationStateChange', this.appStateCallback);
崩溃原因：off 带 callback 参数时 HarmonyOS 可能无法匹配回调引用。
修复方案（任选其一，验证后采用）：
1. 改为无参注销：application.getApplicationContext().off('applicationStateChange');
2. 或在 on 注册时保存回调的包装引用，off 时传同一引用
3. 或使用 ApplicationStateChangeCallback 的正确注销 API
修复后验证：进入相机覆盖层 → 退出 → 不崩溃；重复 3 次稳定。
同时确认相机会话（camera session）在 aboutToDisappear 中正确释放。

任务二：ImageAssetStore 与契约最终对齐
确认 app/entry/src/main/ets/services/imaging/ImageAssetStore.ets：
- 缩略图最长边 480 px
- 扁平布局 records/{assetId}_original.jpg + {assetId}_thumb.jpg
- 孤儿清理 mtime 10 分钟宽限
与 docs/phase-2-contract.md 完全一致。

任务三：相机权限与前后置切换复验（如模拟器可用）
- 拒绝权限后再次进入拍照不应崩溃
- 允许权限后预览正常
- 前后置切换正常

交付物：修复后的 CameraPreview.ets、更新 phase-2-agent-1-report.md。
验收：构建通过；aboutToDisappear 不崩溃（模拟器验证或代码审查）。
```

---

## Agent 2 — 端侧推理（最高优先级）

```text
职责：推理引擎与异步执行。独占 services/inference/、tasks/、模型资源。

任务一：修复 BLK-12（推理张量原生崩溃）— 最高优先级
当前 OnnxSessionWrapper.ets 调用 OnnxBridge.createOnnxTensor(data, shape, 0)
→ new OnnxTensor(data, shape, type) 时原生 SIGSEGV（__stack_chk_fail）。

排查与修复步骤：
1. 确认崩溃点：OnnxSessionWrapper.runInference 中 createOnnxTensor 调用
2. 检查 freshBuffer 构造：
   const totalFloats = inputShape.reduce((a,d) => a*d, 1);
   const freshBuffer = new ArrayBuffer(totalFloats * 4);
   确认 buffer 大小与 shape 匹配（[1,3,640,640] → 4915200 bytes）
3. 尝试方案 A（优先）：切换到 NativeInferenceBridge 路径
   - NativeInferenceBridge 使用 C++ NAPI (libonnx_native.so)，绕过 TS OnnxTensor 构造
   - 修改 RecognitionService 和 InferenceTask，将 OnnxSessionWrapper 替换为 NativeInferenceBridge
   - 注意：NativeInferenceBridge.runNative 需要 outputSizeBytes 参数
     （output0 [1,84,8400] float32 → 84*8400*4 = 282240 bytes）
4. 尝试方案 B（备选）：修复 OnnxBridge 张量创建
   - 尝试直接传 Float32Array.buffer 而非复制
   - 尝试 OnnxTensor 其他构造函数签名
   - 检查 @ohos/onnxruntime 的 OnnxTensor 构造文档
5. 修复后在模拟器验证：模型加载 → 推理 → 输出检测框

任务二：修复 Q-19 配合（ohosTest 可执行后）
确认推理单元测试（InferenceEngine.test.ets 19 例）能在 ohosTest 中执行。
配合 Agent 0 修正 ohosTest 配置后，运行测试并记录结果。

任务三：模型文档与代码一致性
确认 phase-1-model.md 中 opset=18、输入 [1,3,640,640]、输出 [1,84,8400]。
确认 RecognitionService 中输出解析逻辑与实际输出格式一致。

交付物：修复后的推理路径、测试执行结果、更新 phase-1-agent-2-report.md。
验收：构建通过；模拟器推理输出检测框（如可用）；测试可执行。
```

---

## Agent 3 — 页面与交互

```text
职责：用户界面。独占 pages/Index.ets、components/recognition/、pages/RecordList.ets、pages/RecordDetail.ets。

任务一：第二阶段 UI 联调确认
确认 Index.ets 保存流程与 RecordService API 对齐：
- 保存按钮在识别成功后出现
- 保存成功 Toast 提示
- 保存失败回滚图片
- "历史记录"按钮跳转 pages/RecordList
确认 RecordList.ets：
- 调用 RecordService.list(page, pageSize, sourceFilter?) 分页
- 展示缩略图、时间、来源、物品数、执行模式、耗时
- 来源筛选（相机/相册）
- 点击进入 RecordDetail
确认 RecordDetail.ets：
- getDetail(recordId) 获取原始框与编辑后框
- 绘制检测框（编辑后优先，可切换原始）
- 编辑（改类/删框）→ updateEdited
- 删除 → delete(recordId)

任务二：第三阶段云端查询 UI（依赖 Agent 0 network 层）
在 RecordList 或新建页面中增加云端记录查询入口：
- 调用 ModelClient/RecordClient 查询云端历史
- 支持时间范围、类别筛选、分页
- 展示云端统计（各类别数量）
UI 仅调用 Agent 0 提供的 network 接口，不直接处理 HTTP。

任务三：错误提示与用户体验
- 网络不可用时提示"网络异常，记录将在恢复后自动上传"
- 鉴权失败时引导重新登录
- 模型更新时显示下载进度

交付物：确认第二阶段 UI 完整、第三阶段云端查询 UI、更新报告。
验收：构建通过；UI 流程代码逻辑正确。
```

---

## Agent 4 — 数据与端云协同

```text
职责：存储服务 + 后端 + 客户端同步。独占 services/storage/、backend/app/、services/sync/。

任务一：后端确认与测试
确认 backend 已实现的接口与 docs/phase-3-contract.md 一致：
- POST /api/auth/login（设备标识+密钥 → JWT）
- POST /api/auth/refresh
- GET /api/models/version
- GET /api/models/download
- POST /api/records（批量、幂等 recordId）
- GET /api/records（时间/类别筛选、分页）
运行 pytest 确认 24 个测试通过。
如有不一致，修正后端或契约（需通知 Agent 0）。

任务二：客户端同步层实现
在 app/entry/src/main/ets/services/sync/ 下创建：
- SyncQueue.ets：本地待传记录队列，持久化到 RDB 或偏好存储
- UploadService.ets：
  - 遍历待传队列，调用 network 层上传
  - 幂等：每条记录带 recordId，后端去重
  - 断网重传：上传失败保留队列，网络恢复后自动重试
  - 并发控制：串行上传，避免并发
- SyncManager.ets：统一调度，监听网络状态变化
依赖 Agent 0 的 services/network/ 层（HttpClient、AuthService）。

任务三：记录同步触发
在 RecordService.save 成功后，将 recordId 加入 SyncQueue 待传队列。
或在 RecordService 中提供 markForSync 方法，由页面保存后调用。

交付物：services/sync/ 三个模块、后端测试确认、更新报告。
验收：构建通过；sync 模块编译通过；后端测试通过。
```

---

## Agent 5 — 测试与质量

```text
职责：测试、验收、质量。维护测试计划与验收报告。

任务一：第一阶段阻塞修复验证
- 配合 Agent 2 验证 BLK-12 修复后推理可运行
- 配合 Agent 1 验证 BLK-11 修复后相机退出不崩溃
- 配合 Agent 0 验证 BLK-13 清理后 rawfile 无测试资产
- 配合 Agent 0/2 验证 Q-19 修复后 ohosTest 可执行
更新 docs/phase-1-review.md 阻塞项状态。

任务二：第二阶段端到端验收（模拟器）
执行完整流程并记录证据：
1. 拍照/选图 → 识别 → 保存
2. 历史列表 → 查看缩略图与统计
3. 详情页 → 查看检测框 → 编辑类别 → 删除
4. 重启应用 → 历史记录仍在
如模拟器不可用，编写详细操作手册（步骤、预期、实际记录位）。

任务三：第三阶段后端与同步测试
- 后端 pytest 已通过，确认覆盖登录、刷新、幂等上传、筛选分页
- 客户端 sync 层单元测试：队列持久化、断网重传、幂等
- 端云联调测试（如模拟器可用）：保存 → 自动上传 → 云端查询

任务四：静态检查
- 全量构建 0 错误
- 无遗留 console.log/TODO 阻塞项
- 错误码映射一致（采集→推理→存储→网络→页面）

交付物：更新 phase-1-review.md、验收报告、测试用例。
验收：构建通过；测试文档完整；阻塞项状态更新。
```

---

## 执行顺序

```
Agent 0（BLK-13 清理 + Q-19 配置 + network 层）
    │
    ├── Agent 1（BLK-11 相机修复）
    ├── Agent 2（BLK-12 推理修复 — 最高优先级）
    └── Agent 4（后端确认 + sync 层）  ← 依赖 Agent 0 network 层
           │
           └── Agent 3（UI 联调 + 云端查询 UI）  ← 依赖 Agent 0 network
                  │
                  └── Agent 5（验收 + 测试）
                         │
                         └── Agent 0（最终集成）
```

## Round 2 完成定义（DoD）

| 阶段 | 完成标准 |
| --- | --- |
| 第一阶段 | BLK-11/12/13 修复；Q-19 修复；推理可运行；构建通过 |
| 第二阶段 | 保存→列表→详情→编辑→删除全链路；重启恢复；构建通过 |
| 第三阶段 | 后端接口可用；客户端 network+sync 实现；端云联调（如可用） |
| 验收 | 模拟器端到端跑通（如可用）；测试文档完整；阻塞项清零 |
