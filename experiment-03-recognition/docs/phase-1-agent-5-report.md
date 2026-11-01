# Agent 5 交接报告 — 测试与质量

> 角色：测试与质量负责人。记录时间：2026-10-22（Asia/Shanghai）。
> 关联文档：[测试计划](phase-1-test-plan.md)、[集成验收报告](phase-1-review.md)、[共享契约](phase-1-contract.md)、[模型记录](phase-1-model.md)。
> 结论：**第一阶段验收未通过（阻塞）**。已完成验收矩阵、测试资产、主机参考结果、静态边界审查，并在 HarmonyOS API 24 模拟器上完成构建、安装、首页与错误路径实测；真实推理因模型复制失败未能开始。

## 1. 交付物

| 交付物 | 路径 | 状态 |
| --- | --- | --- |
| 验收计划与矩阵（55 项） | `docs/phase-1-test-plan.md` | 已完成 |
| 集成验收报告 | `docs/phase-1-review.md` | 已完成（随验证结果更新） |
| 本交接报告 | `docs/phase-1-agent-5-report.md` | 已完成 |
| 集成测试资产目录（申请独占） | `tests/` | 已创建 |
| 主机参考推理脚本 | `tests/tools/reference_inference.py` | 可运行 |
| 期望结果基线 | `tests/expected/reference-detections.json` | 已生成 |

`tests/` 目录目前只包含测试资产与参考工具，不含 App 源码，不影响构建。请求 Agent 0 确认该目录归 Agent 5 独占；推理单元测试仍由 Agent 2 维护，本目录不接管其测试代码。

## 2. 测试图片资产

位置 `tests/assets/images/`。全部为合法来源，未修改画面内容（EXIF 与格式转换除外）。

| ID | 文件 | 尺寸 | 用途 | 许可 |
| --- | --- | --- | --- | --- |
| IMG-01 | `01_single_object_cup.jpg` | 1280×853 | 单物品 | Wikimedia Commons，CC0 |
| IMG-02 | `02_multi_object_bus.jpg` | 810×1080 | 多物品/契约基准 | Ultralytics `bus.jpg`，AGPL-3.0（仅测试，不分发） |
| IMG-03 | `03_same_class_overlap_mugs.jpg` | 1920×1277 | 同类重叠 | Wikimedia Commons，CC BY-SA |
| IMG-04 | `04_multi_object_desk.jpg` | 1920×1280 | 桌面多类别 | Wikimedia Commons，CC BY-SA |
| IMG-05 | `05_long_horizontal_street.jpg` | 1920×793 | 横长图/无目标 | Wikimedia Commons，CC BY-SA |
| IMG-06 | `06_long_vertical_cars.jpg` | 1920×4138 | 竖长图/多目标 | Wikimedia Commons，CC BY-SA |
| IMG-07a | `07a_exif_orientation6.jpg` | 存储 1080×810，EXIF=6 | 方向信息 | 由 IMG-02 派生 |
| IMG-07b | `07b_exif_orientation8.jpg` | 存储 1080×810，EXIF=8 | 方向信息 | 由 IMG-02 派生 |
| IMG-08 | `08_blank_gray.jpg` | 1280×960 | 空白图 | 本机生成 |
| IMG-09 | `09_corrupted.jpg` | 截断文件 | 解码失败 | 本机生成 |
| IMG-10 | `10_huge_8000x6000.jpg` | 8000×6000 | 超大图 | 由 IMG-01 放大生成 |
| IMG-11 | `11_rgba_alpha_cup.png` | 1280×853 | RGBA/颜色通道 | 由 IMG-01 派生 |

SHA-256（`shasum -a 256`，2026-10-22）：

```
d32ae1283102eecd1a828156840222a1a0754bcbf5b6f13cf596879800453847  01_single_object_cup.jpg
c02019c4979c191eb739ddd944445ef408dad5679acab6fd520ef9d434bfbc63  02_multi_object_bus.jpg
5dc2a6d2581c4b0ef8052437e07cae21f6326107b55fd60ffc6a5d7e49a42302  03_same_class_overlap_mugs.jpg
7d20ac7822e9241d27bd29791f98377fcc30f0cdd2d613d7f2b03dff2f4cbbfb  04_multi_object_desk.jpg
e3fc7d6605b8cc1cf9ebb8a90f51ded81541b5f576e4be3b6182d5d921eb5bc1  05_long_horizontal_street.jpg
15c52847c4ccde985f362f1fba870414be59a2ab42c8ec950a870e3b01c447db  06_long_vertical_cars.jpg
15fc5f2e80ba53680141b6969846b6a1a7242f8008176a2a651ce3e9b81ef8f8  07a_exif_orientation6.jpg
60f89edddb4f110501adc16a4d79a21f3d1a2ec7870668071fbacc60b1e626de  07b_exif_orientation8.jpg
84059af35c394555a0a73dc84f74c80dc15d10bdeaf8208c737db5481ee8d495  08_blank_gray.jpg
f3ebee381227abc6878a6de75d422e8a372e20708491d31431324a287abbf321  09_corrupted.jpg
5b9fc04185d1703b02832216b62d6ca444a41fd6b316101cbcfcc24a9e2f02d5  10_huge_8000x6000.jpg
6709571f964d7a2f4ae67cebe91f56dd2d5c1c172ade18c9ce9d68b76d9ca8c3  11_rgba_alpha_cup.png
```

## 3. 主机参考结果（E2）

`tests/tools/reference_inference.py` 按契约实现 letterbox（填充 114、半入舍入 `floor(x+0.5)`）、RGB/NCHW 归一化、80 类置信度、逐类 NMS（IoU 0.7）、逆 letterbox 还原与裁剪。运行环境：Python 3.12、onnxruntime 1.31.0 CPU、Pillow 13.0.0、numpy 1.26.4；模型 SHA-256 `f39e5a3b…799b`。

| 图片 | 参考框数 | 结果 |
| --- | --- | --- |
| IMG-01 | 1 | cup 0.9418 |
| IMG-02 | 5 | bus 0.9370；person ×4（0.8958/0.8677/0.8517/0.4992） |
| IMG-03 | 2 | cup 0.8560 / 0.2702 |
| IMG-04 | 5 | book、laptop ×2、keyboard、potted plant |
| IMG-05 | 0 | 无检测 |
| IMG-06 | 7 | car ×6、truck ×1 |
| IMG-08 | 0 | 无检测 |
| IMG-11 | 1 | cup 0.9418（与 IMG-01 完全一致） |

补充验证：IMG-07a/07b 按 EXIF 归一化后与 IMG-02 结果一致（框数、类别相同，置信度差 ≤0.005）；IMG-09 解码失败；IMG-10 可解码但需注意内存峰值。该结果只证明期望值可复现，**不是端侧证据**。

比对容差（详见测试计划 3.2）：框数一致；类别一致；置信度差 ≤0.02；像素坐标边差 ≤4 px（长图按比例放宽至 0.5%）。

## 4. 已执行的验证

| ID | 检查 | 结果 |
| --- | --- | --- |
| B-01 | 2026-10-22 09:52 `./scripts/build-app.sh` | 通过（`BUILD SUCCESSFUL in 2 s 915 ms`，0 错误/7 警告） |
| B-02 | 09:51 HAP 内容 | 通过（47,374,108 B，含 arm64 原生库与 10 MB 模型） |
| B-03 | 模型 SHA-256 | 通过 |
| B-05 | ArkTS 静态检查 | 通过（警告已登记） |
| — | 主机参考推理与 EXIF 归一化 | 通过（E2） |
| — | 模拟器安装与启动 | 通过（127.0.0.1:5555，API 24） |
| — | 首页渲染与错误状态 | 通过（截图 `tests/evidence/device-2026-10-22/01_home_model_missing.jpeg`） |
| S-03 | 模型不可用路径 | 部分通过（MODEL_MISSING 明确、不崩溃） |
| S-04 | 修复模型后重试 | **失败**（点击“重新加载模型”无初始化日志） |
| U-06 前置 | 拍照按钮 | **失败**（Toast：相册服务不支持拍照） |
| U-01 前置 | 相册选择器 | 阻塞（模拟器选择器停在加载态） |

## 5. 静态边界审查（Q 系列）

未修改任何业务文件，全部以问题单形式交接。完整描述见测试计划第 6 节。

| ID | 问题 | 严重度 | 负责人 |
| --- | --- | --- | --- |
| Q-01 | `initialize()` 失败后设置 `initialized=true` 并缓存不可用；模型恢复后无法重试，与契约 6.4 的恢复路径冲突 | 高 | Agent 2 |
| Q-02 | `isMirrored=true` 时页面不翻转静态图，框与图像错位；第一阶段应强制未镜像 | 高 | Agent 0/1 |
| Q-03 | 未 `setContext`/已释放时 `initialize()` 抛普通 `Error`，错误码不统一 | 中 | Agent 2 |
| Q-04 | SYNC 恒为 `coldStart=false, modelLoadMs=0`；TaskPool 每任务均冷启动 | 中 | Agent 2 |
| Q-05 | 双线性采样无半像素中心偏移，端侧与参考存在 ≤1 px 差异 | 低 | Agent 2 |
| Q-06 | SHA-256 同步整文件读入内存（10 MB），存在 UI 卡顿风险 | 低 | Agent 2 |
| Q-07 | ABI 判断依赖 `deviceInfo.abi.includes('arm64')`，未覆盖 arm64 变体命名 | 低 | Agent 2 |
| Q-08 | `@Concurrent` 任务跨模块引用 `InferenceEngine` 且动态 import，TaskPool 约束未实测 | 中 | Agent 2 |
| Q-09 | 契约未覆盖 `ImageSource` 生命周期与缓冲区所有权细节 | 低 | Agent 0 |
| Q-10 | 推理服务不可注入，单测需真实模型/设备 | 低 | Agent 0/2 |
| Q-11 | 初始化未校验 session 输入/输出名与形状，后处理写死 `[1,84,8400]` | 中 | Agent 2 |
| Q-12 | 删除误检项为物理删除，无墓碑，后续 RDB 统计不可追溯 | 低 | Agent 3/4 |
| Q-13 | 09:50 前推理实现存在 ArkTS 编译错误（已修复，09:52 构建 0 错误） | 高 | Agent 2（已关闭） |
| Q-14 | `getRawFileContent()` 返回 `Uint8Array`，直接传入 `fileIo.writeSync`，设备报 `模型复制失败: Invalid argument`（`ModelLoader.ets` 第 62–65 行） | 高 | Agent 2 |
| Q-15 | `cryptoFramework.createMd('SHA-256')` 设备报 `SHA-256 校验异常: create C obj failed.`；OpenHarmony 算法名应为 `SHA256`（`ModelLoader.ets` 第 104 行） | 高 | Agent 2 |
| Q-16 | 首页“拍照”调用 `GalleryImageService.capturePhoto()`，该实现恒拒绝（“相册服务不支持拍照，请使用相机预览组件”），`CameraCaptureService` 未接入 | 高 | Agent 1/3 |
| Q-17 | `Index.ets:501` 使用 `ClickEvent.timestamp`，构建警告“手机不可用”，UI 响应指标可能无法采样 | 中 | Agent 3 |

Q-01 已在模拟器实证：09:54:30 点击“重新加载模型”，hilog 无任何 `ModelLoader` 行，失败状态被缓存且不重试。

## 6. 构建与设备实测证据

### 6.1 构建（B-01，已通过）

2026-10-22 09:52 本角色执行 `./scripts/build-app.sh`：`BUILD SUCCESSFUL in 2 s 915 ms`，0 错误、7 条 ArkTS 警告（crypto `createMd/update/digest` 设备能力 ×3、`RecognitionService` 可能抛异常 ×2、`Index` 点击时间戳 API 手机不可用 ×1、ArkTS FAQ ×1）。产物 47,374,108 B，含 `libs/arm64-v8a/liblibrary.so`（32,481,152 B）与 `resources/rawfile/models/yolov13n.onnx`（10,171,778 B）。日志 `/tmp/agent5-tests/build-0952.log`。

历史失败（09:39:23 `BUILD FAILED`：缺 `GalleryImageService` + 3 处 ArkTS 错误）已由 Agent 1/2 交付与修复，09:52 复测通过，故未再向模块负责人提出编译类问题。

### 6.2 模拟器实测（E3）

设备：`127.0.0.1:5555`，型号 `emulator`，版本 `emulator 6.1.0.126(SP1DEVC00E120R4P11)`，API 24，arm64；AVD `VoiceCalculator_API24`（`-noWindow`）。HAP 安装成功、`aa start -a EntryAbility -b com.example.smartitemassistant` 启动成功。证据目录 `tests/evidence/device-2026-10-22/`。

| 项 | 观察 | 证据 |
| --- | --- | --- |
| 首页渲染 | 标题、拍照/相册、预览区、状态横幅、模式/阈值、开始识别均渲染 | `01_home_model_missing.jpeg` |
| 模型初始化 | 横幅“识别不可用：模型文件缺失”，detail `rawfile copy failed: Invalid argument` | 同上、`hilog_excerpt.txt` |
| 重新加载模型 | 点击后无 `ModelLoader` 日志，失败状态被缓存（Q-01） | `hilog_excerpt.txt` 09:54 |
| 拍照 | Toast“相册服务不支持拍照，请使用相机预览组件”（Q-16/BLK-7） | `02_capture_button_toast.jpeg` |
| 相册选图 | 选择器停在“安全访问图库”加载态 ≥7 s，无法选图；退出后应用被切后台 | `03_gallery_picker_loading.jpeg` |
| 前后台 | 重新前台启动无崩溃，重新初始化 | `hilog_excerpt.txt` 09:54:30 |

关键日志（原文）：

```
09:53:03.106 I ModelLoader: 设备 ABI: arm64-v8a, 支持: yes
09:53:03.165 I ModelLoader: 从 rawfile 复制模型: rawfile/models/yolov13n.onnx -> /data/storage/el2/base/haps/entry/files/models/yolov13n.onnx
09:53:03.175 E ModelLoader: 模型复制失败: Invalid argument
09:54:30.921 E ModelLoader: SHA-256 校验异常: create C obj failed.
09:54:30.921 W ModelLoader: 沙箱模型 hash 不符，重新复制
09:54:30.929 E ModelLoader: 模型复制失败: Invalid argument
```

根因（静态核对 SDK d.ts 后确认）：

1. `resourceManager.getRawFileContent()` 返回 `Uint8Array`；`fileIo.writeSync(fd, buffer)` 只接受 `ArrayBuffer|string` → `Invalid argument`（Q-14）。
2. `cryptoFramework.createMd('SHA-256')` 算法名不合法，运行时报 `create C obj failed`，应使用 `SHA256`（Q-15）。

建议修复（交 Agent 2，经 Agent 0 调度）：

1. `ModelLoader.ets`：复制改为 `fileIo.writeSync(file.fd, buffer.buffer)`（或 `buffer.buffer.slice(buffer.byteOffset, buffer.byteOffset + buffer.byteLength)`），并核对写入字节数。
2. `ModelLoader.ets`：`createMd('SHA256')`。
3. 修复后重装并确认日志出现 `模型复制并校验通过`，再通知本角色复验 S-03/S-04 与 U-06…U-16。

## 7. 未执行项与原因

| 项目 | 原因 |
| --- | --- |
| 真实端侧推理、检测框、计数、编辑、阈值 | 模型复制失败（BLK-8/Q-14），推理无法初始化 |
| 相册选图全链路 | 模拟器选择器停在“安全访问图库”加载态，无法选图（BLK-10，设备限制） |
| 拍照与相机预览/切换 | 首页拍照入口未接入相机服务（BLK-7/Q-16）；无相机预览组件 |
| 权限拒绝、取消选图、快速连点、切图、前后台 | 前台切换已做（不崩溃）；其余依赖可用的选图与模型 |
| 同步/异步各 ≥10 次耗时、冷启动、UI 响应 | 同第一行，且 Q-04/Q-17 未修复 |
| 离线识别 | 同第一行 |
| 真机前后相机、方向、镜像、性能 | 无物理设备（BLK-2），仅 API 24 模拟器 |
| 推理单元测试覆盖检查 | `app/entry/src/ohosTest` 不存在，Agent 2 未交付测试 |

修复模型复制（Q-14）与 hash 算法名（Q-15）后，按测试计划第 7 节顺序复跑，并把每条操作步骤、预期、实际、设备与系统版本、模型 hash、截图或日志回填 `docs/phase-1-review.md`。

## 8. 阻塞项

| ID | 问题 | 解除条件 | 状态 |
| --- | --- | --- | --- |
| BLK-1 | 采集模块未交付导致构建失败 | 已由 Agent 1 交付，09:52 构建通过 | **已解除** |
| BLK-6 | Q-13 三处 ArkTS 编译错误 | 已修复，09:52 构建 0 错误 | **已解除** |
| BLK-8 | Q-14 模型复制 `Invalid argument` | 修复后重装，日志出现 `模型复制并校验通过` | **阻塞发布** |
| BLK-9 | Q-15 `createMd('SHA-256')` 报 `create C obj failed` | 改为 `SHA256` 后复测 S-03 | **阻塞发布** |
| BLK-7 | Q-16 拍照入口恒拒绝，相机服务未接入 | 接入 `CameraCaptureService`/预览组件 | **阻塞发布**（R1 不完整） |
| BLK-4 | Q-01 失败状态缓存且不可重试（S-04 实证失败） | 失败不缓存或提供 reset；复测 S-04 | **阻塞第一阶段完成** |
| BLK-3 | 推理单元测试未交付 | Agent 2 提交测试与运行输出 | 阻塞完成声明 |
| BLK-5 | Q-08 TaskPool 跨模块引用未实测 | 模型可用后设备验证异步任务与 session 关闭 | 待验证 |
| BLK-10 | 模拟器相册选择器停在加载态 | 换真机或向模拟器相册导入图片 | 设备能力限制 |
| BLK-2 | 无物理真机 | 接入真机后补 E4 | 待验证 |

发布阻断：BLK-7、BLK-8、BLK-9；完成声明阻断：BLK-4、BLK-3。

## 9. 交接请求

1. **Agent 2（最高优先）**：按 6.2 节修复 Q-14（`Uint8Array` → `ArrayBuffer` 写入）与 Q-15（`SHA256`）；修复 Q-01 失败缓存；交付推理单元测试（覆盖测试计划第 5 节 11 项）；回复 Q-03/Q-04/Q-08/Q-11。修复后构建并在模拟器重装，确认日志 `模型复制并校验通过`，通知本角色复验。
2. **Agent 1/3**：接入拍照入口（Q-16/BLK-7）：页面调用 `CameraCaptureService` 或提供 `CameraPreview`，并明确 `isMirrored` 第一阶段恒为 `false`（Q-02）。
3. **Agent 0**：确认 `tests/` 为 Agent 5 独占目录；协调 Q-14/Q-15/Q-16 的修复顺序；修复完成后通知本角色串行执行构建与设备复验。
4. **Agent 3**：确认 Q-17（`ClickEvent.timestamp`）改用 `systemDateTime` 采样，或接受 UI 响应指标缺失并登记；确认 Q-12 墓碑留待 RDB 阶段。
5. **Agent 0/验收执行人**：提供真机或可导入图片的模拟器相册，以解除 BLK-10 与 BLK-2。

## 10. 结论

- 已有证据（E1/E2/E3 部分）：模型 SHA-256、HAP 冻结内容、12 张测试图资产、8 张图主机参考结果、09:52 构建通过、模拟器安装与启动、首页渲染、错误状态不可用横幅、拍照入口失败、相册选择器设备限制、前后台无崩溃。
- 设备根因已定位：Q-14（模型复制失败）与 Q-15（hash 算法名）使真实端侧推理完全无法开始；Q-01 使“重新加载模型”无效。
- 缺失证据：真实端侧推理、检测框、计数、编辑、阈值、并发串行、性能、离线、真机相机。
- 第一阶段验收：**未通过（阻塞）**。不得声明第一阶段完成，直到 BLK-8、BLK-9、BLK-7 解除并取得 E3 真实推理证据，且 BLK-4、BLK-3 关闭。

## 11. 第二轮复验交接（2026-10-22 12:25）

本轮被测版本为工作区 12:18 HAP（52,565,645 B），设备仍为 API 24 模拟器；未改动业务源码。证据目录 `tests/evidence/device-2026-10-22-round2/`。

### 11.1 结果变化

| 项 | 第一轮 | 第二轮 |
| --- | --- | --- |
| 模型复制 + SHA-256 | 失败（Q-14/Q-15） | **通过**（冷启动 `模型复制并校验通过`，热启动 `模型已在沙箱且校验通过`） |
| 失败后重试 | S-04 失败 | 代码已修复（仅成功缓存），失败注入**待复验** |
| 拍照入口 | 未接入（Q-16） | 已接入 `CameraPreview`，权限流程可弹出，但退出组件时**崩溃（Q-18）** |
| 真实推理 | 无法开始 | 可发起，但创建 `OnnxTensor` 时**原生 SIGSEGV（Q-22）** |
| 测试执行 | 测试不存在 | 19 例已编写，`aa test` 仍 `App died`（Q-19，ohosTest 配置错误） |
| 相册选图 | 加载态 | 系统图库不存在，`10104001`（环境受限） |
| 图像持久化 | 未交付 | 代码已交付并编译通过，入口未接入（P2-BLK-1） |

### 11.2 新缺陷与交接

1. **Agent 2（最高优先）**：修复 Q-22 —— `OnnxInstance`/`OnnxTensor` 构造在 `OnnxBridge.ets:19` 触发 `SIGSEGV`（`__stack_chk_fail`，`OnnxTensor::OnnxTensor+152`），SYNC 与 TASK_POOL 均在首张图失败。请核对 `Float32Array.buffer` 生命周期、shape/类型参数与库 ABI；修复后重跑 12 图基准（SYNC + TASK_POOL），输出 `RESULT|`/`BOX|`。
2. **Agent 2**：修复 Q-19 —— `app/entry/src/ohosTest/module.json5` 应为 `name=entry_test`、`type=feature`，重编 ohosTest HAP 并执行 `aa test`，提交 19 例通过/失败明细。
3. **Agent 1 / Agent 0**：修复 Q-18 —— `CameraPreview.ets:149` 的 `applicationContext.off('applicationStateChange', this.appStateCallback)` 抛 `Parse applicationStateCallback failed`；改为与注册匹配的注销方式，复验拒绝权限、允许权限、无摄像头三条路径。
4. **Agent 2 / Agent 0**：处理 Q-21 —— `src/main/resources/rawfile/` 中的 `benchmark_trigger.txt`、`bench_01_cup.jpg`、`benchmark_images/` 必须移出普通构建，改用测试构建注入；否则每次启动自动跑 benchmark 且测试图随 HAP 分发。
5. **Agent 0**：完成第二阶段入口集成；当前 `ImageAssetStore`/`RecordService` 无调用方，`docs/phase-2-review.md` 已记录阶段性结论。

### 11.3 结论

真实推理与相机入口仍为阻塞；模型加载链路已可复现通过。第一阶段仍为**未通过（阻塞）**。Q-22 修复并取得 E3 推理证据前，检测框、编辑、阈值、一致性、性能与持久化无法进入验收。
