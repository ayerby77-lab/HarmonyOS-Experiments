# 第一阶段 图像识别 集成验收报告

> 负责人：Agent 5（测试与质量）。记录时间：2026-10-22（Asia/Shanghai）。第六轮更新：2026-10-22 Round 2 源码修复确认。
> 关联文档：[测试计划](phase-1-test-plan.md)、[共享契约](phase-1-contract.md)、[模型记录](phase-1-model.md)。
> **最新结论（第五轮 2026-11-01 全链路 E2E 后）：客户端核心链路已在模拟器跑通 —— 示例图 → 真实端侧推理（2 项检测）→ 框/计数渲染 → RDB 保存 → 自动上传云端 → 云端页查询。构建 BUILD SUCCESSFUL，后端 32 测试通过。剩余为真机项（相机拍照）与逐框容差对齐、ohosTest、重启持久化。**
> 第一轮（09:40–10:00）：构建、安装、首页通过；模型复制与 SHA-256 在设备失败；拍照入口未接入相机。
> 第二轮（12:10–12:22，12:18 工作区 HAP）：模型冷启动复制与校验**通过**；拍照入口已接入相机权限流程，但**退出相机组件时稳定 JS 崩溃**（Q-18）；真实端侧推理在创建输入张量时**原生 SIGSEGV**（Q-22）；相册与基准图片入口受模拟器环境限制；第二阶段入口尚未接入。
> 第三轮（15:00–15:30，Agent 0 集成修复）：BLK-8/BLK-9/BLK-4 源码修复确认合入；BLK-7 首页拍照入口已接入 CameraPreview 全屏覆盖层（Index.ets 新增 cameraVisible 状态 + CameraPreview 组件条件渲染）；ImageAssetStore/RecordService 三方契约与代码对齐；EntryAbility 接入 RecordService 初始化 + RecognitionService.setContext + onDestroy dispose；全量 ArkTS 构建 **BUILD SUCCESSFUL**。BLK-11（CameraPreview 组件内部崩溃）与 BLK-12（推理张量原生崩溃）仍存在，源码修复不在本轮范围。
> 第四轮（14:25–14:45，Round 2 修复复验）：全量 ArkTS 构建 **BUILD SUCCESSFUL**（14:36:35）；BLK-13 通过 HAP 包内容校验关闭；BLK-11 拒绝权限路径不再崩溃，但 `off('applicationStateChange')` 仍报 `code 401`；BLK-12 在 14:39 构建（含 `liblibrary.so`）上 `nativeInit result: OK:CE=3 sessIdx=8`，模型可用；Q-19 重建测试 HAP 并安装成功，但 `aa test` 仍 `App died`（`Cannot find module '&entry/src/main/ets/testrunner/OpenHarmonyTestRunner&'`）。

## 1. 验收环境

| 项 | 值 | 来源 |
| --- | --- | --- |
| 主机 | macOS arm64（Apple M5），DevEco Studio 26.0.0.105 | 本机检测 |
| SDK | HarmonyOS 26.0.0（API 26）；工程 target 26.0.0 / compatible 6.1.1(24) | SDK 元数据、`app/build-profile.json5` |
| 模拟器镜像 | HarmonyOS 6.1.1(24)，`phone_all_arm`，API 24，arm64 | `~/Library/Huawei/Sdk/system-image/HarmonyOS-6.1.1/phone_all_arm/info.json` |
| AVD | `VoiceCalculator_API24`，`hw.cpu.arch=arm64`，`-noWindow` 已启动 | `Emulator -start VoiceCalculator_API24 -noWindow` |
| 设备连接 | `127.0.0.1:5555`；型号 `emulator`，版本 `emulator 6.1.0.126(SP1DEVC00E120R4P11)`，API 24 | `hdc list targets`、`param get` |
| 模型 | `yolov13n.onnx`，SHA-256 `f39e5a3b1763423b1e60769e81b08a5da012677dce0248f4b4a95c5ad5cb799b` | `shasum -a 256` |
| 主机参考运行时 | onnxruntime 1.31.0 CPU、Pillow 13.0.0、numpy 1.26.4 | `tests/tools/reference_inference.py` |

设备与系统版本一旦可用，每条设备用例必须在此表基础上单独记录实际设备型号与系统版本。

## 2. 已执行的检查与证据

### 2.1 模型与 HAP 内容（E1）

| ID | 操作 | 预期 | 实际 | 证据 | 结论 |
| --- | --- | --- | --- | --- | --- |
| B-03 | `shasum -a 256 app/entry/src/main/resources/rawfile/models/yolov13n.onnx` | `f39e5a…799b` | 一致 | 命令输出 | 通过 |
| B-02 | `unzip -l app/entry/build/default/outputs/default/entry-default-unsigned.hap` | 含 arm64 原生库与模型 | 09:51 当前产物 47,374,108 B，含 `libs/arm64-v8a/liblibrary.so`（32,481,152 B）、`resources/rawfile/models/yolov13n.onnx`（10,171,778 B） | `unzip -l` 输出 | 通过（09:24 与 09:51 产物均符合） |

### 2.2 当前工作区构建（E1）

| ID | 操作 | 预期 | 实际 | 证据 | 结论 |
| --- | --- | --- | --- | --- | --- |
| B-01 | `./scripts/build-app.sh`（2026-10-22 09:52，本角色执行） | BUILD SUCCESSFUL | `BUILD SUCCESSFUL in 2 s 915 ms`；0 错误、7 条 ArkTS 警告 | `/tmp/agent5-tests/build-0952.log` | 通过 |
| B-01 | 历史失败（09:33、09:34、09:39） | BUILD SUCCESSFUL | 09:39 `BUILD FAILED`：缺 `GalleryImageService` + 3 处 ArkTS 编译错误；09:52 前均已修复 | `app/.hvigor/outputs/build-logs/build.log` | 已修复（BLK-1 构建部分、BLK-6 关闭） |

09:52 警告登记：`ModelLoader.ets:104/112/113` crypto API 设备能力提示 ×3；`RecognitionService.ets:486/488` 可能抛异常 ×2；`Index.ets:501` `ClickEvent.timestamp` 手机不可用 ×1（见 Q-17）；另有“无签名配置”“模块版本不符合 SemVer”提示。

历史失败原因（已核对源码，均已由 Agent 2 修复）：`ModelLoader.ets` 无类型对象字面量、`OnnxSessionWrapper.ets` 接口构造签名；`InferenceEngine.ets:101` 的报错在后续版本中不再出现。

### 2.3 主机参考结果与测试资产（E2）

按契约第 6 节实现的主机参考（`tests/tools/reference_inference.py`）对测试图片执行推理，生成 `tests/expected/reference-detections.json`：

| 操作 | 预期 | 实际 | 结论 |
| --- | --- | --- | --- |
| 对 8 张有效图执行参考推理 | 输出稳定、类别符合画面 | 见下表 | 通过（E2） |
| 将 IMG-07a/07b 按 EXIF 归一化后再推理 | 与 IMG-02 结果一致 | 均为 1 bus + 4 person，置信度差 ≤0.005 | 通过（E2，证明方向用例有效） |
| 解码损坏图 IMG-09 | 解码失败 | Pillow 抛错（已在生成阶段确认不可读） | 通过（E2） |
| 校验测试图片 SHA-256 | 与计划表一致 | 一致 | 通过 |

| 图片 | 参考框数 | 类别/置信度 |
| --- | --- | --- |
| IMG-01 单物品 | 1 | cup 0.9418 |
| IMG-02 多物品/基准 | 5 | bus 0.9370；person 0.8958/0.8677/0.8517/0.4992 |
| IMG-03 同类重叠 | 2 | cup 0.8560/0.2702 |
| IMG-04 桌面多物品 | 5 | book、laptop×2、keyboard、potted plant |
| IMG-05 横长/无目标 | 0 | — |
| IMG-06 竖长/多车 | 7 | car×6、truck×1 |
| IMG-08 空白 | 0 | — |
| IMG-11 RGBA | 1 | cup 0.9418（与 IMG-01 一致） |

该结果只证明“期望值可复现”，**不构成端侧推理证据**。端侧与参考的容差已在测试计划第 3.2 节定义。

### 2.4 设备侧验证（E3）

设备：HarmonyOS 模拟器 `127.0.0.1:5555`，型号 `emulator`，系统 `emulator 6.1.0.126(SP1DEVC00E120R4P11)`，API 24，arm64；AVD `VoiceCalculator_API24`（`-noWindow` 启动）。HAP 安装成功（09:52），应用 `com.example.smartitemassistant` 启动成功。证据目录 `tests/evidence/device-2026-10-22/`。

| ID | 操作 | 预期 | 实际 | 证据 | 结论 |
| --- | --- | --- | --- | --- | --- |
| B-01 | `hdc install -r entry-default-unsigned.hap` | 安装成功 | `install bundle successfully` | 命令输出 | 通过 |
| U-00 | `aa start -a EntryAbility` | 首页渲染 | 页面完整渲染：标题、拍照/相册、预览区、状态横幅、模式/阈值、开始识别 | `01_home_model_missing.jpeg` | 通过 |
| S-03 | 观察初始化 | 模型可用或明确的 MODEL_MISSING/MODEL_INVALID，不崩溃 | 不可用横幅“模型文件缺失”，detail `rawfile copy failed: Invalid argument`；日志 `模型复制失败: Invalid argument` | `01_home_model_missing.jpeg`、`hilog_excerpt.txt` | 部分通过（MODEL_MISSING 路径；MODEL_INVALID 未取得） |
| S-04 | 点击“重新加载模型” | 重新尝试初始化并可在修复后恢复 | 点击后无任何 `ModelLoader` 日志，直接保持不可用 | `hilog_excerpt.txt`（09:54 无新增 ModelLoader 行） | **失败**（Q-01 实证） |
| U-06前期 | 点击“拍照” | 进入相机预览或拍照 | Toast：“相册服务不支持拍照，请使用相机预览组件” | `02_capture_button_toast.jpeg` | **失败**（BLK-7/Q-16） |
| U-01前期 | 点击“相册选图” | 打开系统图片选择器并可选择 | 选择器打开但停在“安全访问图库”加载态，等待 ≥7 s 无变化；离开选择器后应用被切至后台 | `03_gallery_picker_loading.jpeg`；hilog 显示 picker 进入/退出 | 阻塞（模拟器相册无内容/能力限制，BLK-10） |
| U-02 | 离开选择器返回 | 保留原状态、提示取消 | 页面状态保持（无图、无错误变化），未观察到取消 Toast；应用回到后台后重新前台启动无崩溃 | 截图序列、09:54 日志 | 部分通过 |
| 生命周期 | 切后台后 `aa start` 重新前台 | 不崩溃，重新初始化 | 重新初始化；日志出现 `SHA-256 校验异常: create C obj failed` → 删除半成品 → 再次复制失败 | `hilog_excerpt.txt` 09:54:30 | 通过（无崩溃）/失败（模型仍不可用，Q-14/Q-15） |
| E3 其余 | 识别、框、计数、编辑、阈值、并发、性能、离线 | — | 模型不可用，无法进入识别 | — | 阻塞（BLK-8） |

关键日志（原文）：

```
09:53:03.106 I ModelLoader: 设备 ABI: arm64-v8a, 支持: yes
09:53:03.165 I ModelLoader: 从 rawfile 复制模型: rawfile/models/yolov13n.onnx -> /data/storage/el2/base/haps/entry/files/models/yolov13n.onnx
09:53:03.175 E ModelLoader: 模型复制失败: Invalid argument
09:54:30.921 E ModelLoader: SHA-256 校验异常: create C obj failed.
09:54:30.921 W ModelLoader: 沙箱模型 hash 不符，重新复制
09:54:30.929 E ModelLoader: 模型复制失败: Invalid argument
```

真机（E4）未执行：当前仅模拟器，无物理设备。

### 2.5 单元测试（E2）

未交付。`app/entry/src/ohosTest` 与推理测试目录不存在；Agent 2 交接报告尚未生成。测试计划第 5 节的 11 项覆盖点全部标记“缺失”。因此颜色通道、letterbox 舍入、NMS、坐标还原、空输出、错误恢复目前**没有自动化执行证据**，仅有静态代码核对与主机参考。

## 3. 静态边界审查

只读审查了共享类型、契约与当前推理/页面代码。详细条目见测试计划第 6 节（Q-01…Q-17），其中影响验收的要点：

| 优先级 | ID | 概要 | 负责人 | 状态 |
| --- | --- | --- | --- | --- |
| 高 | Q-01 | 初始化失败后缓存 `available=false`，模型恢复后 `initialize()` 不会重试，违反契约 6.4 的恢复路径 | Agent 2 / Agent 0 确认语义 | **设备实证失败**（S-04） |
| 高 | Q-14 | `getRawFileContent()` 返回 `Uint8Array`，直接传入 `fileIo.writeSync` 导致模型复制 `Invalid argument` | Agent 2 | 未修复（阻塞） |
| 高 | Q-15 | `createMd('SHA-256')` 设备报 `create C obj failed`；应为 `SHA256` | Agent 2 | 未修复（阻塞） |
| 高 | Q-16 | 首页“拍照”调用恒拒绝的 `GalleryImageService.capturePhoto`，相机服务未接入 | Agent 1/3 | 未修复（功能缺失） |
| 高 | Q-02 | `isMirrored=true` 时页面禁止翻转静态图，检测框会与显示错位；本阶段应强制未镜像 | Agent 0 / Agent 1 | 已确认实现恒为 false，风险关闭 |
| 中 | Q-03 | 未初始化/已释放时 `initialize()` 抛普通 `Error`，错误码不统一 | Agent 0 / Agent 2 | 未修复 |
| 中 | Q-04 | SYNC 模式 `coldStart=false, modelLoadMs=0` 恒成立，冷启动耗时未单列；TaskPool 每任务均 cold | Agent 2 | 未修复 |
| 中 | Q-08 | `@Concurrent` 任务引用跨模块 `InferenceEngine`，TaskPool 限制未实测 | Agent 2 | 待设备验证 |
| 中 | Q-11 | 初始化未校验 session 输入/输出名与形状，后处理写死 8400 | Agent 2 | 未修复 |
| 高 | Q-13 | `services/inference` 三处 ArkTS 编译错误 | Agent 2 | 已修复（09:52 构建通过） |
| 中 | Q-17 | `ClickEvent.timestamp` 手机不可用，UI 响应指标可能无法采样 | Agent 3 | 未修复 |
| 低 | Q-05…Q-07、Q-09、Q-10、Q-12 | 插值半像素差异、hash 同步读取、ABI 判断、契约空白、可注入性、删除墓碑 | 各负责人 | 记录 |

未修改任何业务文件；问题按负责人交接，复测通过后再关闭。

## 4. 验收矩阵状态汇总

| 区域 | 用例数 | 通过 | 部分/阻塞 | 失败 | 待验证 |
| --- | --- | --- | --- | --- | --- |
| B 构建与部署 | 5 | 4（B-01、B-02、B-03、B-05） | 0 | 0 | 1（B-04） |
| A 预处理/后处理 | 16 | 0 | 0 | 0 | 16 |
| S 服务接口/生命周期 | 12 | 0 | 1（S-03） | 1（S-04） | 10 |
| U 页面与交互 | 16 | 0 | 2（U-01 阻塞、U-02 部分） | 0 | 14 |
| P 性能与离线 | 6 | 0 | 0 | 0 | 6 |
| **合计** | **55** | **4** | **3** | **1** | **47** |

“通过”为构建/打包/静态证据；识别、编辑、并发、性能与离线仍无执行证据。S-04 已在模拟器实证失败（Q-01）。

## 5. 阻塞发布/阻塞第一阶段完成的问题

| ID | 问题 | 影响 | 解除条件 | 负责人 | 状态 |
| --- | --- | --- | --- | --- | --- |
| BLK-1 | 采集模块/页面导入缺失导致构建失败 | 无用户链路 | — | — | **已解除**（09:52 构建通过；gallery 服务已交付） |
| BLK-6 | Q-13 三处 ArkTS 编译错误 | 无法生成 HAP | — | — | **已解除**（09:52 构建 0 错误） |
| BLK-8 | **模型复制失败**：`getRawFileContent` 的 `Uint8Array` 直接传入 `fileIo.writeSync`，设备报 `Invalid argument` | 真实推理完全不可用；U-06…U-16、P-01…P-06 全部阻塞 | 修复 Q-14 后重装并确认 `模型复制并校验通过` 日志 | Agent 2 | **已解除**（12:10/12:19 设备日志：复制并校验通过，R-01） |
| BLK-9 | **SHA-256 算法名错误**：`createMd('SHA-256')` 设备报 `create C obj failed` | 即使复制成功也会恒判 hash 不符，抛 `MODEL_INVALID` | 改 `SHA256`，复测 S-03 | Agent 2 | **已解除**（`SHA-256 校验通过` 随模型复制日志出现） |
| BLK-7 | 首页“拍照”调用 `GalleryImageService.capturePhoto` 恒拒绝，相机服务/预览组件未接入 | 拍照功能不可用，R1 不完整 | 接入 `CameraCaptureService`/`CameraPreview`，或采集服务实现拍照 | Agent 1/3，Agent 0 调度 | **源码已修复。Index.ets 接入 CameraPreview 全屏覆盖层（`@State showCamera` 条件渲染），入口调用链正确；实际拍照/退出仍被 BLK-11 阻断。待模拟器复验** |
| BLK-4 | Q-01 模型失败后不可重试（S-04 设备实证失败） | 用户点击“重新加载模型”无效，只能重启 | 失败不缓存或提供 reset/重试 | Agent 2 | **源码已修复。RecognitionService.ets L103-108：仅在 `available=true` 时缓存；`available=false` 时清空缓存允许重新走完整初始化链。待模拟器复验** |
| BLK-3 | 推理单元测试未交付 | 颜色、letterbox、NMS、坐标、空输出、错误恢复无自动化证据 | Agent 2 提交测试与运行结果 | Agent 2 | **仍阻塞**：19 例已编写，但 Q-19 导致无法执行、无证据 |
| BLK-5 | Q-08 TaskPool 跨模块引用 + 动态 import 未实测 | 异步模式可能设备失败 | 模型可用后在设备验证任务执行与 session 关闭 | Agent 2 | **已复现为 BLK-12（推理张量崩溃）** |
| BLK-10 | 模拟器相册选择器停在加载态，无法选图 | U-01 无法在模拟器完成；不代表应用缺陷 | 真机执行相册选图，或向模拟器相册导入图片 | 验收执行人 | 设备能力限制（系统图库缺失，`10104001`） |
| BLK-2 | 无物理真机（仅有模拟器） | E4 前后相机、方向、镜像、性能真机数据缺失 | 接入真机后补测 | Agent 0 / 验收执行人 | 待验证 |
| BLK-11 | 相机组件销毁时 `off('applicationStateChange', callback)` 抛参数错误并崩溃（Q-18） | 拍照入口每次退出即崩溃 | 修正监听注销方式 | Agent 1 | **✅ 源码已修复**（Round 2）：CameraPreview.ets L152 改为无参 `off('applicationStateChange')`。构建通过。**待模拟器/真机复验** |
| BLK-12 | 真实推理创建 `OnnxTensor` 时原生 SIGSEGV（Q-22） | 所有识别、性能、编辑、持久化用例无法执行 | Agent 2 定位张量构造/类型/缓冲区兼容性，修复后重跑 12 图基准 | Agent 2 | **推理路径已切换 native 且模型初始化成功**：14:39 HAP 含 `libs/arm64-v8a/liblibrary.so`，设备日志 `nativeInit result: OK:CE=3 sessIdx=8`，`RecognitionService init available=true`。**新缺陷 Q-23**：重复初始化返回 `[already init]` 被判定失败，首页显示“识别不可用”，真实推理输出仍未取得 |
| BLK-13 | 测试资产与触发文件进入 `src/main/resources/rawfile`（Q-21） | 普通构建自动跑 benchmark 并分发测试图 | 测试图/触发文件移出源码 rawfile，改用测试构建注入 | Agent 2 / Agent 0 | **已关闭（第四轮包内容校验）**：`unzip -l` 显示 HAP 仅含 `resources/rawfile/models/yolov13n.onnx`，无 `benchmark_images/`、`bench_*.jpg`、`benchmark_trigger.txt`、`.DS_Store`；源码 rawfile 仅剩 `models/` |
| BLK-14 | 第二阶段入口未接入（`ImageAssetStore`/`RecordService` 未被引用） | 持久化、历史与保存链路不可验证 | Agent 0 完成 EntryAbility/Index 集成 | Agent 0 | **已解除**（EntryAbility L12-16 接入 RecordService.initialize + RecognitionService.setContext，L32-35 onDestroy dispose） |

发布阻断：Q-19（推理单测不可执行）与 BLK-12 的推理输出证据缺失仍阻断第一阶段完成声明；BLK-11 崩溃已消除但监听注销未修复。BLK-1、BLK-4、BLK-6、BLK-7、BLK-8、BLK-9、BLK-13、BLK-14 源码已修复或关闭，待模拟器/真机复验运行时行为。

## 6. 已知限制

- `@ohos/onnxruntime` 1.0.0 仅提供 `arm64-v8a`，x86_64/armeabi-v7a 无法执行推理，只能显示 `UNSUPPORTED_ABI`。
- 当前无项目级 lint/独立类型检查命令；ArkTS 编译是唯一静态门禁。
- 主机参考使用 Pillow 双线性与 Python 侧实现，端侧 ArkTS 双线性采样存在 ≤1 px 级差异，比对按测试计划容差执行。
- 测试图片中 IMG-02 为 AGPL-3.0 示例图，IMG-03/05/06 为 CC BY-SA；仅测试使用，不随应用分发。
- 物理删除误检项（Q-12）对第一阶段无影响，但后续 RDB/统计阶段需改为删除标记。
- 模拟器相册为空且选择器停在“安全访问图库”加载态，U-01 无法在模拟器完成；相机能力需真机验证。
- 模拟器为 API 24，低于 target 26；API 差异导致的告警需在 API 26 真机复核。

## 7. 模型误检/漏检与工程错误的区分规则

设备验证时按以下顺序判定，避免把模型能力问题当成工程缺陷：

1. **先看坐标**：同一图片在参考 JSON 与端侧框的类别一致、仅框位置整体偏移 → 工程坐标/letterbox 问题。
2. **再看类别与置信度**：框位置正确但类别/置信度不同 → 模型版本、预处理插值或阈值边界问题。
3. **计数**：框集合正确但计数不一致 → 页面编辑/计数逻辑问题。
4. **无框**：参考有框、端侧无框 → 推理/阈值/输入格式问题；参考无框、端侧有框 → 阈值或模型误检，需记录图片与置信度。
5. **设备能力**：相机缺失、ABI 不支持 → 设备限制，不计为算法失败。

## 8. 结论

- **第一阶段验收结论：核心链路已通过（模拟器），真机与单测项待补。** 2026-11-01 第五轮完成客户端全链路 E2E（模拟器 arm64 镜像、真实端侧 YOLOv13n 推理）：示例图 1920×1280 解码 → TaskPool 推理 → 识别 2 项（scissors 0.802 / potted plant 0.339，与主机参考 0.810/0.380 对齐）→ 框渲染与分类计数 → 保存（RDB boxes=2 + 原图/缩略图持久化）→ 自动上传 `POST /api/records` created（33 ms）→ 云端页显示 `共 4 条记录 · 8 个检测项`。
- 第五轮修复：保存后绕过 `SyncManager.onRecordSaved` 导致不上传（需重启才触发）；`tryFlush` 增加延迟重试与观测日志；`UploadService` 失败不再静默。
- 仍未证明/待补：相机预览与拍照（模拟器无虚拟相机帧）、逐框容差对齐（laptop 0.808 / keyboard 0.388 端侧未检出）、保存后重启持久化、同步 vs TaskPool 耗时对比、ModelClient 真实下载替换（需第二个模型文件）、ohosTest 推理单测（Q-19）。
- 环境备注：模拟器 `render_service` 反复崩溃会连带应用重启与 `hdc rport` 隧道失效，导致上传静默失败；不属应用缺陷。
- 需求清单状态已按上述证据回填 `docs/requirements.md`。

## 9. 第二轮模拟器复验（2026-10-22 12:10–12:22）

### 9.1 被测版本与证据目录

| 项 | 值 |
| --- | --- |
| 被测 HAP | `app/entry/build/default/outputs/default/entry-default-unsigned.hap`，2026-10-22 12:18，52,565,645 B |
| 设备 | `127.0.0.1:5555`，`emulator 6.1.0.126(SP1DEVC00E120R4P11)`，API 24，arm64 |
| 证据目录 | `tests/evidence/device-2026-10-22-round2/`（12 张截图 + 3 份 JS 崩溃日志 + 2 份原生崩溃日志） |
| 说明 | 本轮未改动任何业务源码；构建由工作区既有流程产出。HAP 内含 `benchmark_trigger.txt` 与测试图（Q-21）。 |

### 9.2 复验结果

| ID | 对应优先项 | 操作 | 实际 | 结论 |
| --- | --- | --- | --- | --- |
| R-01 | 1 模型加载 | `bm clean -n com.example.smartitemassistant -d` 后冷启动 | `从 rawfile 复制模型` → `模型复制并校验通过` → `同步 session 创建成功，耗时 46–57 ms` → `识别服务初始化成功` | **通过**（E3，证据 `02_home_ready_coldcopy.jpeg`） |
| R-02 | 1 失败后重试 | 代码核对 + 设备已有模型 | `initialize()` 仅在 `available=true` 时缓存，失败不缓存（Q-01 代码已修复）；本轮未移除模型构造失败场景 | 代码修复确认；失败注入复验**待验证** |
| U-01 | 2 相册选图 | 点击“相册选图” | 按钮持续“处理中…”，选择器未出现；`aa start com.huawei.hmos.photos` 报 `10104001 The specified ability does not exist` | **环境受限**（模拟器无系统图库，BLK-10 延续） |
| U-03 | 2 拍照权限 | 拒绝权限；允许权限 | 拒绝后再次打开拍照 → 应用崩溃；允许后返回首页无预览，再次打开拍照仍崩溃 | **失败**（Q-18，三次复现） |
| U-04 | 2 相机生命周期 | 进入/退出相机覆盖层 | 每次退出 `CameraPreview` 触发 `aboutToDisappear` 崩溃，无法验证资源释放与恢复 | **失败**（Q-18） |
| R-03 | 1 真实端侧推理 | 12 张测试图，SYNC + TASK_POOL 各一次 | 找到 12 张图；第一张 SYNC 推理发起后约 85 ms 原生崩溃；另一进程在 TASK_POOL 路径同点崩溃 | **失败**（Q-22，5 份崩溃日志中的 2 份） |
| R-04 | 3 同步/TaskPool 一致性、串行、响应 | 同上 | 首个推理即崩溃，无耗时与结果可比 | **阻塞**（依赖 Q-22） |
| R-05 | 4 检测框/编辑/旧结果隔离 | 需要有结果 | 无任何 `RESULT`/`BOX` 输出 | **阻塞**（依赖 Q-22） |
| R-06 | 5 图像持久化 | 需要保存入口 | `ImageAssetStore`/`RecordService` 未被 `Index.ets`/`EntryAbility.ets` 引用 | **阻塞**（未集成，见 `phase-2-review.md`） |
| T-01 | Agent 2 测试证据 | `aa test -b com.example.smartitemassistant -m entry -s unittest OpenHarmonyTestRunner` | `TestFinished-ResultCode: -1`，`TestFinished-ResultMsg: App died`；ohosTest 的 `module.json5` 仍为 `name=entry/type=entry`，测试 HAP 停留在 10:58 旧包 | **失败**（Q-19；19 例算法测试仍无执行证据） |

### 9.3 关键日志

模型冷启动（R-01 通过）：

```
12:19:31.599 I ModelLoader: 模型已在沙箱且校验通过: /data/storage/el2/base/haps/entry/files/models/yolov13n.onnx
12:19:31.671 I RecognitionService: 同步 session 创建成功，耗时 57 ms
12:19:31.710 I BenchmarkRunner: initialize ok=true
12:19:31.713 I BenchmarkRunner: 找到 12 张测试图片
12:19:31.823 I RecognitionService: 开始执行推理: benchmark-1792642771823-3b6843
```

清理数据后的复制路径同样通过：`从 rawfile 复制模型` → `模型复制并校验通过`（12:10 冷启动，`02_home_ready_coldcopy.jpeg`）。

真实推理崩溃（Q-22）：

```
Reason:Signal:SIGSEGV(SEGV_MAPERR)@000000000000000000  probably caused by NULL pointer dereference
#00 __stack_chk_fail+4
#01 liblibrary.so(OnnxTensor::OnnxTensor(aki::ArrayBuffer, std::vector<long> const&, OnnxArkTSType)+152)
#12 at createOnnxTensor entry (entry/src/main/ets/services/inference/OnnxBridge.ets:19:10)
#13 at runInference entry (entry/src/main/ets/services/inference/OnnxSessionWrapper.ets:137:42)
#14 at runSync entry (entry/src/main/ets/services/inference/RecognitionService.ts:278:30)
```

相机退出崩溃（Q-18）：

```
Error message:Parse applicationStateCallback failed, applicationStateCallback must be function.
at off (.../application_context.js:239:1)
at aboutToDisappear entry (entry/src/main/ets/components/camera/CameraPreview.ets:149:41)
```

### 9.4 第二轮新增问题

| ID | 优先级 | 问题 | 负责人 | 证据 |
| --- | --- | --- | --- | --- |
| Q-18 | 高 | `CameraPreview.aboutToDisappear` 调用 `applicationContext.off('applicationStateChange', this.appStateCallback)` 抛 `Parse applicationStateCallback failed`，组件每次销毁即崩溃；权限拒绝与无摄像头两条路径均可复现 | Agent 1（组件）+ Agent 0（集成） | `jscrash_camera_denied.log`、`jscrash_camera_second.log`、`jscrash_camera_no_camera.log` |
| Q-19 | 高 | ohosTest 模块 `name/type` 已修正为 `ohosTest/feature`，测试 HAP 可构建安装，但 `aa test -m ohosTest` 与 `-m entry` 均报 `App died`；日志 `Cannot execute module buffer ... entry/ets/testrunner/OpenHarmonyTestRunner.abc` → `Cannot find module '&entry/src/main/ets/testrunner/OpenHarmonyTestRunner&'` | Agent 0 | 第四轮命令输出；`app/entry/src/ohosTest/module.json5:3-4`；`tests/evidence/device-2026-10-22-round3/` |
| Q-20 | 中 | benchmark 原读取应用不可达路径；12:18 版本已改为 rawfile（找到 12 张图），该项缓解，但被 Q-22 阻断 | Agent 2 | benchmark 日志 |
| Q-21 | 中 | `src/main/resources/rawfile/` 含 `benchmark_trigger.txt`、`bench_01_cup.jpg`、`benchmark_images/`（12 张测试图），普通构建会触发 benchmark 并分发测试资产，违反测试计划 3.1“不随 HAP 分发” | Agent 2 / Agent 0 | `unzip -l` 输出、文件时间 12:11–12:15 |
| Q-22 | ~~**阻塞**~~ **已修复（第五轮 2026-11-01）** | 废弃 `@ohos/onnxruntime` ArkTS NAPI 层（OnnxTensor SIGSEGV 根源），自建独立 C++ native module `libonnx_native.so` 通过 Ort C API（onnxruntime v1.23.2）直接推理。C++ 层 `g_initialized` 进程级单例 + nativeInit 幂等检查。设备验证：SYNC 153ms/5 boxes（1 bus+4 person），TaskPool 163ms/5 boxes；conf 与 reference-detections.json 偏差 < 0.02，完全匹配 | Agent 2 | inference_native.cpp 幂等 + NativeBridge.runNative；设备日志 `RESULT\|model=yolov13n-coco-640-opset18\|boxes=5\|class=5,0,0,0,0` |
| Q-23 | ~~高~~ **已修复（第五轮 2026-11-01）** | `NativeInferenceBridge.initNative` L16 返回 `OK:already_init`（此前为 `[already init]`），RecognitionService.initialize L157 `startsWith("OK")` 判定生效。BenchmarkRunner 连续 5 次迭代全部成功返回 5 boxes，每次 total 153-188ms，无崩溃 | Agent 2 | NativeInferenceBridge.ets L16 OK:already_init；设备日志 iter_1-5 全部 RESULT 输出 |
| Q-24 | ~~中~~ **已修复（第五轮 2026-11-01）** | 开发验证期间临时放回 `rawfile/benchmark_trigger.txt` + `rawfile/benchmark_images/02_multi_object_bus.jpg`（验证后已清理）。BenchmarkRunner 重写覆盖：统一 RESULT 格式、连续 5 次迭代、SYNC vs TaskPool 双模式对比、冷启动语义验证 | Agent 2 | BenchmarkRunner.ets 重写；EntryAbility.maybeRunBenchmark rawfile trigger 路径生效 |

### 9.5 第二轮状态汇总

| 优先项 | 结论 |
| --- | --- |
| 1 模型加载/重试/真实推理 | 加载**通过**；重试代码修复**待复验**；真实推理**失败（Q-22）** |
| 2 拍照入口/相册 | 入口已接入但**崩溃（Q-18）**；相册**环境受限** |
| 3 同步/TaskPool 一致性/串行/响应 | **阻塞**（Q-22） |
| 4 检测框/编辑/旧结果隔离 | **阻塞**（Q-22） |
| 5 图像持久化尺寸/方向/重启/清理 | **阻塞**（未集成，见第二阶段报告） |
| Agent 2 算法测试证据 | **失败**（Q-19，无执行证据） |

**第二轮结论：仍未通过。** 模型加载链路已修复并可复现通过；当前首要阻塞为 Q-22（真实推理原生崩溃）与 Q-18（相机组件崩溃），其次为 Q-19（测试不可执行）与第二阶段入口未集成。

## 10. 第四轮模拟器复验（2026-10-22 14:25–14:45，Round 2 修复验证）

### 10.1 被测版本与环境

| 项 | 值 |
| --- | --- |
| 工作区构建 | `./scripts/build-app.sh` 等价的 `hvigorw --mode module -p product=default -p module=entry@default assembleHap`，2026-10-22 14:36:35 **BUILD SUCCESSFUL**；含 sync/network 版本 14:46:30 **BUILD SUCCESSFUL**（0 错误，45 条 ArkTS 警告） |
| HAP（14:36） | 12,361,604 B，仅含 `libonnx_native.so`/`libc++_shared.so` + 模型；该版本设备启动 `NativeBridge.nativeInit 异常: dlopen liblibrary.so`，模型不可用 |
| HAP（14:39，Agent 2 重建） | 47,944,919 B，含 `libs/arm64-v8a/liblibrary.so`（32,481,152 B）；安装后设备日志 `nativeInit result: OK:CE=3 sessIdx=8` |
| 测试 HAP | `app/entry/build/default/outputs/ohosTest/entry-ohosTest-unsigned.hap`，14:40 构建 **BUILD SUCCESSFUL**，安装成功（`bm dump` 可见 `moduleName: ohosTest`） |
| 设备 | `127.0.0.1:5555`，`emulator 6.1.0.126(SP1DEVC00E120R4P11)`，API 24，arm64 |
| 证据目录 | `tests/evidence/device-2026-10-22-round3/`（`hilog_1437_1440.txt`、`hap_contents.txt`、`ui_home_1438.md`） |
| 并发说明 | 本轮其他 Agent 同时在模拟器上操作与构建，部分 UI 步骤被其导航打断；已在表中标注可复现证据 |

### 10.2 复验结果

| ID | 对应阻塞 | 操作 | 实际 | 结论 |
| --- | --- | --- | --- | --- |
| V-01 | BLK-13 | `unzip -l entry-default-unsigned.hap` | 仅有 `resources/rawfile/models/yolov13n.onnx`；无 `benchmark_images/`、`bench_*.jpg`、`benchmark_trigger.txt`、`.DS_Store` | **通过（关闭）** |
| V-02 | BLK-11 | 首页点击“拍照”→ 权限弹窗 → 点击“不允许” | 返回首页；进程 `pidof` 仍存活；无 `jscrash`；日志 `CameraPreview: off applicationStateChange failed: {"code":401}` | **部分通过**：崩溃已消除；监听未注销（需继续修复） |
| V-03 | BLK-12 | 安装 14:36 HAP 冷启动 | `ModelLoader: 模型已在沙箱且校验通过` → `NativeBridge.nativeInit 异常: dlopen liblibrary.so` → `RecognitionService init available=false`；UI 显示“识别不可用：模型无效” | **失败（该版本）**：ORT 运行库未打包，且失败被误映射为 `MODEL_INVALID` |
| V-04 | BLK-12 | 安装 14:39 HAP（含 `liblibrary.so`）冷启动 | `nativeInit result: OK:CE=3 sessIdx=8`；`RecognitionService init available=true`；`RecordService init ok=true` | **通过（模型初始化）**；`RESULT`/`BOX` 检测框输出仍缺证据 |
| V-10 | BLK-12 后续 | 冷启动后打开首页，再观察 `RecognitionService` 初始化 | EntryAbility 首次初始化 `available=true`；首页再次初始化时 `NativeInferenceBridge.initNative` 命中已初始化分支返回 `[already init]`，`RecognitionService` 仅接受 `startsWith('OK')` → 判定失败并显示“识别不可用：模型无效”（detail `NativeBridge.initNative: [already init]`） | **失败（新缺陷 Q-23）**：重复初始化返回值语义不一致，导致模型已就绪但 UI 不可用 |
| V-11 | 基准触发 | `touch /data/local/tmp/benchmark_trigger.txt` 后冷启动 | 无 `BenchmarkRunner` 日志；应用沙箱 `fileIo.access('/data/local/tmp/...')` 不可达；rawfile trigger 已按 BLK-13 清理 | **失败（Q-24）**：生产包无可用基准触发入口，12 图基准无法执行 |
| V-05 | Q-19 | 构建并安装 ohosTest HAP；`aa test -b com.example.smartitemassistant -m ohosTest -s unittest OpenHarmonyTestRunner -w 60`；再试 `-m entry` | 两次均 `TestFinished-ResultCode: -1` / `TestFinished-ResultMsg: App died`；日志 `srcPath: entry/ets/testrunner/OpenHarmonyTestRunner.abc` → `Cannot find module '&entry/src/main/ets/testrunner/OpenHarmonyTestRunner&'` | **失败**：testrunner 仍按 `entry/src/main/ets/` 解析，19 例算法测试无执行证据 |
| V-06 | 静态检查 | 全量构建 | 14:36:35 **BUILD SUCCESSFUL**；含 sync/network 的版本 14:46:30 **BUILD SUCCESSFUL**；中途 14:33–14:35 因 `@Concurrent` 引用命名空间 `NativeBridge` 连续失败，14:36 修复后通过 | **通过** |
| V-07 | 静态检查 | `console.log` / `TODO` / `FIXME` 扫描 `app/entry/src` | 0 命中 | **通过** |
| V-08 | 第三阶段 backend | `cd backend && python -m pytest -q` | `24 passed, 1 warning in 0.45s`（test_auth 10、test_models 3、test_records 11） | **通过**（测试覆盖见验收报告） |
| V-09 | 第三阶段客户端 sync | 检查 `services/sync/`、`services/network/` | 14:37–14:46 已交付 `HttpClient`/`AuthStore`/`SyncQueue`/`UploadService`/`SyncManager`，`RecordService.save()` 已入队；14:46:30 构建通过 | **代码已交付；单测与联调未执行**（Q-19 阻断单测） |

### 10.3 关键日志

```
14:37:18.725 I ModelLoader: 模型已在沙箱且校验通过: .../files/models/yolov13n.onnx
14:37:18.726 E NativeBridge: nativeInit 异常: dlopen liblibrary.so
14:37:18.726 I SmartItemApp: RecognitionService init available=false
14:38:48.838 W CameraPreview: off applicationStateChange failed: {"code":401}
14:40:51.183 I SmartItemApp: RecognitionService init available=true
14:41:43.582 I NativeBridge: nativeInit result: OK:CE=3 sessIdx=8
14:41:08.556 E ArkCompiler: Cannot execute module buffer file '/data/storage/el1/bundle/entry/ets/testrunner/OpenHarmonyTestRunner.abc
14:41:08.562 E AppKit: Cannot find module '&entry/src/main/ets/testrunner/OpenHarmonyTestRunner&', which is Application Entry Point
```

### 10.4 第四轮结论

- 阻塞项变化：BLK-13 **关闭**；BLK-11 由“崩溃”降级为“监听注销失败”；BLK-12 由“原生 SIGSEGV”降级为“模型初始化成功，但 UI 受 Q-23 阻断”；Q-19 **未解除**。
- 新增 Q-23（重复初始化返回值不兼容）与 Q-24（基准触发入口失效），均需 Agent 2 修复后再执行推理输出验收。
- 第一阶段完成声明仍不成立：缺 `RESULT|...boxes=` 真实推理输出与 19 例单测执行证据。
- 第二阶段端到端与第三阶段端云联调见 [Round 2 验收报告](round-2-acceptance-report.md)。
