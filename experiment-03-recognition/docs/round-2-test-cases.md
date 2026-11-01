# Round 2 测试用例（2026-10-22）

> 维护：Agent 5。状态取值：通过 / 失败 / 待验证 / 环境受限 / 阻塞。
> 证据目录：`tests/evidence/device-2026-10-22-round3/`；详细结论见 [Round 2 验收报告](round-2-acceptance-report.md)。

## 1. 构建与打包

| ID | 前置 | 步骤 | 预期 | 实际 | 状态 |
| --- | --- | --- | --- | --- | --- |
| B-01 | 干净工作区 | `./scripts/build-app.sh` | BUILD SUCCESSFUL，0 错误 | 14:36:35 成功，45 警告 | 通过 |
| B-02 | B-01 | `unzip -l entry-default-unsigned.hap` | 含 arm64 原生库与模型，无测试资产 | 含 `libonnx_native.so`、`libc++_shared.so`、模型；14:39 包另含 `liblibrary.so` | 通过 |
| B-03 | B-01 | 计算模型 SHA-256 | `f39e5a…799b` | 一致 | 通过 |
| B-04 | 工作区 | `-p module=entry@ohosTest assembleHap` | BUILD SUCCESSFUL | 14:40 成功，34 tasks | 通过 |
| B-05 | B-04 | `hdc install -r entry-ohosTest-unsigned.hap` | 安装成功 | `install bundle successfully`；`bm dump` 含 `moduleName: ohosTest` | 通过 |

## 2. 第一阶段阻塞修复

| ID | 前置 | 步骤 | 预期 | 实际 | 状态 |
| --- | --- | --- | --- | --- | --- |
| F-01 | 安装应用 HAP | 冷启动 | 模型校验通过并可用 | 14:42/14:43 日志 `available=true`、`OK:CE=3` | 通过 |
| F-02 | 相机权限未授予 | 点击“拍照”→ 拒绝 | 不崩溃，可再次进入 | 进程存活，无 jscrash | 通过 |
| F-03 | 相机覆盖层已打开 | 退出相机覆盖层 | 监听注销成功、session 释放 | `off applicationStateChange failed: {"code":401}` | 失败（监听未注销） |
| F-04 | 安装含 `liblibrary.so` 的包 | 冷启动并触发一次基准 | 输出 `RESULT|...boxes=` | 未取得推理输出日志 | 待验证 |
| F-06 | 模型可用 | 冷启动后进入首页 | 状态徽标“识别可用” | 二次初始化返回 `[already init]` → 显示“识别不可用：模型无效” | 失败（Q-23） |
| F-07 | 测试图已在 `/data/local/tmp` | 创建 trigger 后冷启动 | BenchmarkRunner 执行并输出结果 | 无 BenchmarkRunner 日志（沙箱不可达） | 失败（Q-24） |
| F-05 | 测试 HAP 已安装 | `aa test -m ohosTest`（再试 `-m entry`） | 19 例推理测试执行并输出统计 | `App died`；testrunner 路径 `entry/src/main/ets/testrunner` 不存在 | 失败（Q-19） |

## 3. 第二阶段端到端

| ID | 前置 | 步骤 | 预期 | 状态 |
| --- | --- | --- | --- | --- |
| E2E-01 | 模型可用、已有图片 | 选图/拍照 → 识别 | 检测框与计数出现 | 阻塞（模拟器无图库且无推理输出） |
| E2E-02 | E2E-01 成功 | 点击“保存识别” | Toast 成功；RDB 与 `files/records/*_original.jpg`/`*_thumb.jpg` 生成 | 阻塞 |
| E2E-03 | 已保存记录 | “历史记录 · 本地保存” | 缩略图、时间、来源、物品数、模式、耗时 | 阻塞（仅验证路由与空态） |
| E2E-04 | 有记录 | 进入详情 | 检测框叠加，编辑后可切换原始/编辑 | 阻塞 |
| E2E-05 | 详情页 | 改类别 / 删除误检 / 删除记录 | 计数同步、记录与文件删除一致 | 阻塞 |
| E2E-06 | E2E-02 成功 | `aa force-stop` 后重启 → 历史 | 记录与缩略图仍可读 | 阻塞 |
| E2E-07 | 无网络配置 | 打开“云端记录” | 显示“云端服务尚未配置”，可返回本地历史 | 通过 |
| E2E-08 | 已有记录 | 并发快速切换两张图 | 旧结果不覆盖新图 | 待验证 |

## 4. 第三阶段后端

| ID | 步骤 | 预期 | 状态 |
| --- | --- | --- | --- |
| BE-01 | `POST /api/auth/login` 正确凭据 | 200 + token pair | 通过（`test_auth.py`） |
| BE-02 | `POST /api/auth/refresh` 有效/无效 refresh | 新 token / 401 | 通过 |
| BE-03 | 重复 `POST /api/records/batch` 同 `recordId` 同载荷 | `duplicate`，不重复写入 | 通过（`test_records.py`） |
| BE-04 | 同 `recordId` 不同载荷 | `conflict` | 通过 |
| BE-05 | 时间范围 / 类别筛选 / 分页 | 返回符合 `RecordPage` | 通过 |
| BE-06 | `GET /api/models/version` / download | 版本信息与文件流 | 通过（`test_models.py`） |

## 5. 客户端同步层

> 代码状态：`services/network/`（HttpClient、AuthStore）与 `services/sync/`（SyncQueue、UploadService、SyncManager）已于 14:37–14:46 交付，14:46:30 构建通过；以下用例尚无执行证据。

| ID | 步骤 | 预期 | 状态 |
| --- | --- | --- | --- |
| SY-01 | 保存记录后重启应用 | 队列持久化，未上传记录仍在 | 未执行（缺单测） |
| SY-02 | 断网后 `flush()`，恢复网络再 `flush()` | 失败保留队列，恢复后成功上传 | 未执行（缺网络注入） |
| SY-03 | 同一 `recordId` 重复入队 | 仅入队一次，上传一次 | 未执行 |
| SY-04 | 连续上传 60 条 | 按 50 条/批拆分 | 未执行 |
| SY-05 | 上传返回 401 | 自动 refresh 后重试一次，仍失败清 token | 未执行 |
| SY-06 | 上传返回 conflict/invalid | RDB 状态标记 CONFLICT/FAILED | 未执行 |

## 6. 静态检查

| ID | 检查 | 预期 | 实际 | 状态 |
| --- | --- | --- | --- | --- |
| ST-01 | 全量构建 | 0 错误 | 0 错误 / 45 警告 | 通过 |
| ST-02 | `console.log`/`TODO`/`FIXME` | 0 阻塞项 | 0 命中 | 通过 |
| ST-03 | 错误码映射 | 采集、推理、存储、网络、页面各层有明确错误码且语义正确 | 推理/存储/云端存在；native 初始化失败误映射 `MODEL_INVALID`；网络/同步未实现 | 部分通过 |
| ST-04 | `@Concurrent` 模块约束 | 并发任务仅引用 import/局部变量 | 14:33–14:35 因命名空间 `NativeBridge` 失败，14:36 已修复 | 通过（以最新构建为准） |
