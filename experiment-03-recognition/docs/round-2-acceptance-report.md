# Round 2 验收报告（2026-10-22）

> 负责人：Agent 5（测试与质量）。记录时间：2026-10-22 14:30–14:50（Asia/Shanghai）。
> 依据：[Round 2 各 Agent Prompt](round-2-agent-prompts.md)、[第一阶段评审](phase-1-review.md)、[第二阶段评审](phase-2-review.md)、[第三阶段契约](phase-3-contract.md)。
> 验收门禁：构建通过 + 模拟器运行 + 后端测试；不要求真机。
> 结论：**构建与后端通过；第一阶段阻塞项部分关闭（BLK-13 关闭，BLK-11 残留注销失败，BLK-12 仅到模型初始化且被 Q-23 阻断）；第二阶段端到端与第三阶段端云联调未通过（环境/依赖受限）。**

## 1. 环境与版本

| 项 | 值 |
| --- | --- |
| 主机 | macOS arm64（Apple M5），DevEco Studio 26.0.0.105 |
| SDK | HarmonyOS 26.0.0（API 26）；工程 target 26.0.0 / compatible 6.1.1(24) |
| 设备 | 模拟器 `127.0.0.1:5555`，`emulator 6.1.0.126(SP1DEVC00E120R4P11)`，API 24，arm64，AVD `VoiceCalculator_API24` |
| 应用 HAP（14:36） | `entry-default-unsigned.hap`，12,361,604 B；无 `liblibrary.so` |
| 应用 HAP（14:39，Agent 2 重建） | 47,944,919 B；含 `libs/arm64-v8a/liblibrary.so`（32,481,152 B） |
| 应用 HAP（14:46，含 network/sync） | 构建 **BUILD SUCCESSFUL**（3 s 51 ms）；源码新增 `AuthStore`/`HttpClient`/`SyncQueue`/`UploadService`/`SyncManager` |
| 测试 HAP | `outputs/ohosTest/entry-ohosTest-unsigned.hap`，14:40 构建并安装 |
| 后端 | `backend/.venv`，pytest `24 passed` |
| 证据目录 | `tests/evidence/device-2026-10-22-round3/` |

> 说明：本轮多个 Agent 并行修改源码、构建并操作同一台模拟器；部分 UI 操作被其他 Agent 的导航打断。下表只记录可复现的证据，被打断的步骤标记“环境受限/并发冲突”。

## 2. 任务一：第一阶段阻塞修复验证

| ID | 阻塞 | 操作 | 实际 | 结论 |
| --- | --- | --- | --- | --- |
| V-01 | BLK-13 | 检查源码 rawfile 与 HAP 包内容 | 源码 `rawfile/` 仅 `models/`；`unzip -l` 仅有 `resources/rawfile/models/yolov13n.onnx`，无测试图、trigger、`.DS_Store` | **通过，关闭** |
| V-02 | BLK-11 | 首页“拍照”→ 权限弹窗 → “不允许” | 返回首页，进程存活，无 JS 崩溃；日志 `CameraPreview: off applicationStateChange failed: {"code":401}` | **部分通过**：崩溃消除；监听未注销 |
| V-03 | BLK-12 | 14:36 HAP 冷启动 | `ModelLoader: 模型已在沙箱且校验通过` → `NativeBridge.nativeInit 异常: dlopen liblibrary.so` → `available=false`，UI“识别不可用：模型无效” | **失败（该包）**：ORT 运行库未打包 |
| V-04 | BLK-12 | 14:39 HAP 冷启动（含 `liblibrary.so`） | `nativeInit result: OK:CE=3 sessIdx=8`；`RecognitionService init available=true`；`RecordService init ok=true` | **通过（模型初始化）**；无 `RESULT`/`BOX` 输出证据 |
| V-10 | BLK-12 后续 | 冷启动后进入首页，观察第二次初始化 | EntryAbility 首次 `available=true`；首页再次初始化命中 `[already init]`，`RecognitionService` 仅接受 `startsWith('OK')`，判定失败并显示“识别不可用：模型无效”（detail `[already init]`） | **失败（Q-23 新增）**：模型已就绪但 UI 不可用 |
| V-11 | 基准入口 | `touch /data/local/tmp/benchmark_trigger.txt` 后冷启动 | 无 `BenchmarkRunner` 日志；沙箱 `fileIo.access` 不可达；rawfile trigger 已清理 | **失败（Q-24 新增）**：生产包无可用基准入口 |
| V-05 | Q-19 | 重建并安装 ohosTest HAP；`aa test -b com.example.smartitemassistant -m ohosTest -s unittest OpenHarmonyTestRunner -w 60`；再试 `-m entry` | 两次均 `TestFinished-ResultCode: -1` / `TestFinished-ResultMsg: App died`；日志 `srcPath: entry/ets/testrunner/OpenHarmonyTestRunner.abc` → `Cannot find module '&entry/src/main/ets/testrunner/OpenHarmonyTestRunner&'` | **失败**：19 例推理单测仍无执行证据 |

阻塞状态已回填 [phase-1-review.md](phase-1-review.md) 第 5 节与新增第 10 节。

## 3. 任务二：第二阶段端到端验收（模拟器）

### 3.1 执行结果

| ID | 流程 | 实际 | 结论 |
| --- | --- | --- | --- |
| E2E-01 | 拍照/选图 → 识别 → 保存 | 相册选择器在模拟器不可用（系统图库缺失，`aa start com.huawei.hmos.photos` 报 `10104001`）；相机权限路径可用但模拟器无真实被摄物；推理无 `RESULT`/`BOX` 输出 | **阻塞**（BLK-10 环境受限 + 推理输出待验证） |
| E2E-02 | 历史列表 → 缩略图与统计 | `pages/RecordList` 已注册并可从首页“历史记录 · 本地保存”进入；因无成功保存的记录，仅能验证空态 | **部分验证**（路由与空态） |
| E2E-03 | 详情 → 检测框 → 改类别 → 删除 | `pages/RecordDetail` 已注册；无可打开的记录，编辑/删除链路未执行 | **阻塞**（依赖 E2E-01） |
| E2E-04 | 重启应用 → 历史仍在 | 未写入记录，重启后无数据可校验 | **未执行** |
| E2E-05 | 云端记录入口 | 首页可进入 `pages/CloudRecords`，页面显示“云端服务尚未配置，当前仅支持本地历史记录” | **通过（降级提示）** |

### 3.2 操作手册（待推理输出可用后执行）

> 适用：模拟器或真机；每条用例记录到 `tests/evidence/device-YYYY-MM-DD-roundN/`，命名 `E2E-xx_描述_时间.png`，日志用 `hdc shell "hilog -x | grep -E 'RecognitionService|RecordService|ImageAssetStore|SyncManager'"`。

| 步骤 | 操作 | 预期 | 实际记录位 |
| --- | --- | --- | --- |
| 1 | 冷启动应用，等待状态徽标变为“识别可用” | `RecognitionService init available=true` | `hilog` + 首页截图 |
| 2 | 点击“相册选图”（真机）或“拍照” | 返回图片，预览区显示原图 | 截图 |
| 3 | 点击“开始识别”，分别用“同步/TaskPool” | 出现检测框、分类计数、分阶段耗时 | 截图 + `RESULT|...` 日志 |
| 4 | 点击“保存识别” | Toast 保存成功；`RecordService` 写入 RDB；`files/records/{assetId}_original.jpg` 与 `_thumb.jpg` 存在 | `hdc shell "ls -la /data/storage/el2/base/haps/entry/files/records"` |
| 5 | 点击“历史记录 · 本地保存” | 列表显示缩略图、时间、来源、物品数、模式、耗时 | 截图 |
| 6 | 点击任一记录进入详情 | 显示原图与检测框（编辑后优先） | 截图 |
| 7 | 修改一个框的类别 → 保存 | 详情刷新，计数同步变化 | 截图 + `hilog` |
| 8 | 删除一个误检框 / 删除整条记录 | 框消失 / 返回列表且记录消失 | 截图 |
| 9 | `aa force-stop` 后重启应用 → 历史记录 | 记录与图片仍可读，缩略图正常 | 截图 |

失败判定：出现崩溃、记录丢失、缩略图缺失、重启后图片不可读，任一项即失败并附崩溃日志。

## 4. 任务三：第三阶段后端与同步测试

### 4.1 后端 pytest

命令：`cd backend && source .venv/bin/activate && python -m pytest -q`

结果：`24 passed, 1 warning in 0.45s`。

| 覆盖点 | 用例数 | 文件 | 结论 |
| --- | --- | --- | --- |
| 登录 / 刷新 / 鉴权失败 | 10 | `backend/tests/test_auth.py` | 通过 |
| 模型版本 / 下载 | 3 | `backend/tests/test_models.py` | 通过 |
| 记录幂等上传 / 筛选 / 分页 / 冲突 | 11 | `backend/tests/test_records.py` | 通过 |

### 4.2 客户端 sync 层

交付状态：Agent 0/4 于 14:37–14:46 交付 `services/network/`（`HttpClient.ets`、`AuthStore.ets`）与 `services/sync/`（`SyncQueue.ets`、`UploadService.ets`、`SyncManager.ets`）；`RecordService.save()` 已调用 `enqueueForSync(recordId)`。包含这些模块的构建于 14:46:30 **BUILD SUCCESSFUL**。

| 用例 | 结果 |
| --- | --- |
| 队列持久化 | **未执行**：代码已交付，无对应 ohosTest 用例；Q-19 未修复 |
| 断网重传 | **未执行**：需设备网络注入与 `SyncManager` 触发入口 |
| 幂等上传 | **未执行**：仅后端用例覆盖；客户端无单测 |

### 4.3 端云联调

- `pages/CloudRecords` 与 `pages/RecordList` 已引用 network 层；但后端地址/密钥未配置，页面显示“云端服务尚未配置，当前仅支持本地历史记录”。
- “保存 → 自动上传 → 云端查询”**未执行**：缺后端可达地址与成功识别记录，属环境与前置依赖限制，非已证缺陷。

## 5. 任务四：静态检查

| 检查 | 命令/范围 | 结果 | 结论 |
| --- | --- | --- | --- |
| 全量构建 | `hvigorw --mode module -p product=default -p module=entry@default assembleHap` | 14:36:35 **BUILD SUCCESSFUL**；含 sync/network 版本 14:46:30 **BUILD SUCCESSFUL**；14:33–14:35 曾因 `Concurrent function should only use import variable or local variable, 'NativeBridge'` 失败 | **通过**（以 14:46 为准） |
| 测试 HAP 构建 | `-p module=entry@ohosTest assembleHap` | **BUILD SUCCESSFUL**（34 tasks） | 通过 |
| 遗留标记 | `console.log` / `TODO` / `FIXME` 扫描 `app/entry/src` | 0 命中 | 通过 |
| 错误码映射 | 采集→推理→存储→网络→页面 | 推理 `RecognitionErrorCode`、存储 `RecordErrorCode`、云端 `CLOUD_UNAVAILABLE_MESSAGE` 均存在；**native 初始化失败被映射为 `MODEL_INVALID`**（实为运行库缺失/加载失败），语义不符；network/sync 已交付，其错误码与页面提示映射尚未逐条核对 | **部分通过**，需修正推理错误码语义 |

### 5.1 构建警告归类（45 条）

- `Function may throw exceptions`（RecordService/ImageAssetStore/CameraPreview 等）：需在设备路径复核，不阻塞。
- `deprecated getContext` / `abilityDelegatorRegistry`：技术债，不阻塞。
- `CameraPreview.ets:374 fill API 需 SDK 26`（compatible 24）：需 `apiAvailable` 兜底，潜在低版本兼容风险。
- `Index.ets:606 API unavailable to phone`：UI 响应采样指标在手机不可用（Q-17 延续）。

## 6. 问题与负责人

| ID | 问题 | 负责人 | 优先级 |
| --- | --- | --- | --- |
| Q-19 | ohosTest testrunner 路径解析到 `entry/src/main/ets/testrunner`，`aa test` App died | Agent 0 | 高（阻塞单测证据） |
| Q-23 | `initNative` 已初始化返回 `[already init]`，`RecognitionService` 仅接受 `OK` 前缀，二次初始化判定失败 | Agent 2 | 高（阻塞识别入口） |
| Q-24 | BLK-13 清理后基准触发入口失效（`/data/local/tmp` 沙箱不可达） | Agent 2 | 中（阻塞基准执行） |
| BLK-11 残留 | `off('applicationStateChange')` 报 code 401，监听未注销 | Agent 1 | 中 |
| BLK-12 证据 | 模型初始化通过，缺 `RESULT|...boxes=` 输出 | Agent 2 | 高 |
| 错误码语义 | native 初始化失败 → `MODEL_INVALID` | Agent 2 | 中 |
| 第三阶段依赖 | `services/network`、`services/sync` 已交付并编译通过，但无客户端单测/联调证据 | Agent 4 | 高（阻塞联调验证） |
| 模拟器图库 | 相册选择器不可用（10104001） | 验收执行人 / 真机补验 | 环境限制 |

## 7. 验收结论

| 门禁 | 结果 |
| --- | --- |
| 构建通过 | **通过**（应用 HAP + 测试 HAP） |
| 第一阶段阻塞项状态更新 | **已完成**（BLK-13 关闭；BLK-11/12 降级；Q-19 未解除） |
| 第二阶段端到端 | **未通过**（环境受限 + 推理输出缺失） |
| 第三阶段后端测试 | **通过**（24 例） |
| 第三阶段 sync/端云 | **未验证**（代码已交付、构建通过；无单测与联调环境） |
| 测试文档完整 | **通过**（本报告 + [测试用例](round-2-test-cases.md)） |
