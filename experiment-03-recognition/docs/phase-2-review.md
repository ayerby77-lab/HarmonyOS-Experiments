# 第二阶段 本地记录与图像持久化 验收报告（阶段性）

> 负责人：Agent 5（测试与质量）。记录时间：2026-10-22 12:25（Asia/Shanghai）。
> 关联文档：[第二阶段契约](phase-2-contract.md)、[第一阶段验收报告](phase-1-review.md)、[测试计划](phase-1-test-plan.md)。
> 结论先行：**第二阶段尚不具备端到端验收条件。** 代码已交付且随 12:18 工作区构建通过（E1），但入口未接入、无第二阶段测试，尺寸/方向/重启/失败清理均无设备执行证据。

## 1. 验收环境

| 项 | 值 |
| --- | --- |
| 被测版本 | `entry-default-unsigned.hap`，2026-10-22 12:18，52,565,645 B |
| 设备 | `127.0.0.1:5555`，`emulator 6.1.0.126(SP1DEVC00E120R4P11)`，API 24，arm64 |
| 应用 | `com.example.smartitemassistant` 0.1.0 |
| 证据目录 | `tests/evidence/device-2026-10-22-round2/`（第二阶段无新增执行证据） |

## 2. 已具备条件的验证（E1/E2）

| 项 | 交付/实现 | 证据 | 结论 |
| --- | --- | --- | --- |
| 契约 | `docs/phase-2-contract.md` 已由 Agent 0 创建，定义 RDB schema 与存储 API | 文档 | 通过（静态） |
| 图像持久化 | [ImageAssetStore.ets](file:///Users/avery/Desktop/hongmeng/SmartItemRecognitionAssistant/app/entry/src/main/ets/services/imaging/ImageAssetStore.ets)：`filesDir/records/{assetId}_original.jpg` + `_thumb.jpg`；缩略图最长边 480、JPEG 80，原图 JPEG 90；临时目录写入后原子改名 | 12:18 构建通过；常量位于 `ImageAssetStore.ets:32-48` | 编译通过（E1） |
| 失败清理 | `ORPHAN_GRACE_PERIOD_MS = 10 * 60 * 1000`、`ORPHAN_CLEANUP_MAX_COUNT = 200`；删除仅接受 `records/` 下 `_original.jpg`/`_thumb.jpg`，缺文件不报错 | 同上 | 编译通过（E1），行为未在设备验证 |
| RDB | [RecordDatabase.ets](file:///Users/avery/Desktop/hongmeng/SmartItemRecognitionAssistant/app/entry/src/main/ets/services/storage/RecordDatabase.ets)：`records` 表，`store.version` 迁移，目标版本 1；[RecordService.ets](file:///Users/avery/Desktop/hongmeng/SmartItemRecognitionAssistant/app/entry/src/main/ets/services/storage/RecordService.ets) | 12:18 构建通过 | 编译通过（E1） |
| 共享类型 | `RecordTypes.ets`（12:11）与 `recognizedAtMs` 字段 | Agent 2 报告、构建通过 | 编译通过（E1） |

以上只说明“代码可编译”，**不构成第二阶段功能通过**。

## 3. 未执行项与原因

| 验收项 | 预期 | 当前状态 | 原因 |
| --- | --- | --- | --- |
| 保存识别结果 | 原图 + 缩略图落盘，返回路径 | 待验证 | `ImageAssetStore`/`RecordService` 未被 `Index.ets`/`EntryAbility.ets` 引用（BLK-14） |
| 原图尺寸/方向 | 原始像素尺寸、EXIF 方向归一化后保存 | 待验证 | 无保存入口；相册选择器在本模拟器不可用（BLK-10） |
| 缩略图尺寸 | 最长边 ≤480、等比不放大 | 待验证 | 无保存入口 |
| 重启可读 | 重启后记录/图片仍可读 | 待验证 | 无记录写入路径 |
| 失败清理 | 编码/写入失败无半成品；孤儿文件按 10 分钟宽限清理 | 待验证 | 无保存入口；需注入权限/磁盘错误 |
| RDB CRUD | 插入、查询、删除、计数与契约一致 | 待验证 | 入口未接入，且无第二阶段测试 |
| 记录与图像一致性 | 记录删除同时删除文件，缺文件不崩溃 | 待验证 | 同上 |

## 4. 问题与风险

| ID | 问题 | 负责人 | 影响 |
| --- | --- | --- | --- |
| P2-BLK-1 | 第二阶段服务未接入应用入口（`EntryAbility`/`Index` 无 `RecordService`/`ImageAssetStore` 调用） | Agent 0 | 全部持久化用例阻塞 |
| P2-BLK-2 | `ohosTest` 无第二阶段用例，且模块配置错误导致测试不可执行（同 Q-19） | Agent 2 / Agent 4 | 无自动化证据 |
| P2-BLK-3 | 图像保存依赖应用沙箱可写；主机 shell 无法写入该目录，测试需通过应用内入口执行 | 验收执行人 | 只能通过 UI/测试 HAP 驱动 |
| P2-RISK-1 | 孤儿清理 10 分钟宽限、200 个上限为代码常量，未与契约逐条核对 | Agent 1 / Agent 0 | 可能出现契约偏差 |

## 5. 结论与下一步

- **第二阶段结论：不具备端到端验收条件。** 已确认代码交付与编译通过；未执行任何持久化、重启与清理用例。
- 下一步：
  1. Agent 0 完成 `RecordService.initialize` 与保存入口集成（含失败提示与记录目录初始化）。
  2. Agent 4 提供 RDB CRUD 测试；Agent 1 提供缩略图尺寸/方向/失败清理测试或测试入口。
  3. Q-19 修复、Q-22 修复后，通过“保存识别”或测试 HAP 执行：原图尺寸/方向、480 缩略图、杀进程重启可读、删除记录与文件一致性、失败注入清理。
  4. 每条结果回填本报告，并附日志与截图后才可声明第二阶段通过。

## 6. 第四轮复验更新（2026-10-22 14:30–14:50）

- 入口集成：P2-BLK-1 **已解除**。`EntryAbility.ets` 已调用 `RecordService.initialize()` 与 `RecognitionService.setContext()`；首页新增“历史记录 · 本地保存”入口，`main_pages.json` 已注册 `pages/RecordList`、`pages/RecordDetail`、`pages/CloudRecords`。
- 运行证据：14:42/14:43 冷启动日志 `RecordService init ok=true`、`RecognitionService init available=true`、`NativeBridge nativeInit result: OK:CE=3 sessIdx=8`。
- 端到端：`E2E-01` 因模拟器图库缺失（`10104001`）且推理尚无 `RESULT` 输出而阻塞；`E2E-07` 云端入口降级提示通过。完整链路仍未执行。
- 自动化：`ohosTest` 可构建安装，但 `aa test` 仍 `App died`（Q-19），第二阶段无自动化证据。
- 结论不变：**第二阶段不具备端到端通过条件**。详细证据与操作手册见 [Round 2 验收报告](round-2-acceptance-report.md)。
