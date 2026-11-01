# Smart Item Recognition Assistant — Agent 工作指南

本文件适用于项目根目录及所有子目录，与上层 AGENTS.md 一起生效。下文路径均相对于本项目根目录。

## 目标与当前状态

开发鸿蒙智能物品识别助手，采用 ArkTS/ArkUI Stage 客户端、onnxruntime-ohos 端侧 YOLOv13 推理与 FastAPI 云端管理。

当前工程已实现第一至第三阶段客户端与服务端代码，并在模拟器（arm64 镜像）跑通全链路：示例图/相册选图 → 端侧 YOLOv13n 推理（真实 RESULT/BOX 输出）→ 框与计数渲染 → RDB 保存 → 自动上传云端 → 云端记录查询。相机拍照与真实性能数据仍待真机验证；ohosTest（Q-19）与逐框容差对齐为待补项。

当前第一阶段范围：拍照/相册选图 → 端侧识别 → 检测框与分类计数 → 单次结果编辑，含 TaskPool 异步执行与耗时对比。RDB、JWT、云端同步和模型更新属于后续阶段；用户明确调整范围时遵循最新任务。

## 开始任务的阅读顺序

1. 阅读本文件与 `README.md`，了解工程入口与运行方式。
2. 阅读 `docs/requirements.md` 中本次任务对应的需求。
3. 第一阶段任务阅读 `docs/phase-1-agent-prompts.md` 中自己的职责和文件边界。
4. 存在 `docs/phase-1-contract.md` 时，先阅读共享接口契约；推理任务同时阅读 `docs/phase-1-model.md`。
5. 按下面地图直接定位相关模块，再用 `rg` 做局部检索。优先复用项目现有实现。

## 文档地图

| 文档 | 内容及使用时机 | 当前状态 |
| --- | --- | --- |
| `AGENTS.md` | 工作规则、代码与文档导航、验证入口 | 已有 |
| `README.md` | 开发环境、启动步骤、构建方式 | 已有 |
| `docs/requirements.md` | 实验功能清单与完成状态 | 已有，业务项待实现 |
| `docs/api-plan.md` | 后续 JWT、模型、记录及统计接口规划 | 已有，业务接口待实现 |
| `docs/phase-1-agent-prompts.md` | Agent 0–5 的职责、执行顺序、人工 review 清单 | 已有 |
| `docs/phase-1-contract.md` | 图像、检测框、结果、耗时、错误及线程传输契约 | 已由 Agent 0 创建 |
| `docs/phase-1-model.md` | 模型来源、许可证、hash、输入输出、类别、ABI 与库兼容性 | 已由 Agent 0 创建 |
| `docs/phase-1-test-plan.md` | 验收矩阵、测试图片与许可、参考结果容差、设备与性能用例 | 已由 Agent 5 创建，随验证更新 |
| `docs/phase-1-agent-N-report.md` | 各 agent 修改文件、接口、验证证据和剩余问题；N 为 0–5 | 0–5 均已创建 |
| `docs/phase-1-review.md` | 集成结果、设备记录、人工验收与已知限制 | 已由 Agent 5 创建；第五轮更新为"核心链路已通过（模拟器），真机与单测项待补" |
| `docs/phase-2-agent-4-report.md` | 第二阶段本地 RDB 存储服务、接口与验证结果 | 已创建（Agent 4） |
| `docs/phase-2-agent-3-report.md` | 第二阶段保存入口、历史列表/详情、路由与模拟器验证 | 已创建（Agent 3） |
| `docs/phase-3-agent-4-report.md` | 第三阶段后端鉴权、记录/模型接口、测试与验收 | 已创建（Agent 4） |
| `docs/phase-3-agent-3-report.md` | 第三阶段云端查询 UI、错误/重试提示、模型更新进度与第二阶段联调核对 | 已创建（Agent 3） |
| `docs/phase-2-contract.md` | 本地记录 RDB schema、原图/缩略图持久化、存储服务 API | 已由 Agent 0 创建（本任务） |

待创建的文档是交付约定。接手任务时先确认文件是否已经生成，并读取最新内容。

## 客户端代码地图

客户端工程根目录为 `app/`。业务 ArkTS 根目录为 `app/entry/src/main/ets/`。

| 路径 | 职责 | 当前状态 |
| --- | --- | --- |
| `app/entry/src/main/ets/entryability/EntryAbility.ets` | 启动窗口并加载 pages/Index | 已实现最小入口 |
| `app/entry/src/main/ets/pages/Index.ets` | 主识别页面与交互入口 | 已由 Agent 3 实现；已接入 CameraPreview 拍照覆盖层与第二阶段“保存识别”“历史记录”入口；第三阶段接入模型更新提示/进度；5th 轮新增“示例图片”入口（rawfile 样例，模拟器可跑通全链路）；保存后经 `SyncManager.onRecordSaved` 触发上传 |
| `app/entry/src/main/ets/pages/RecordList.ets` | 历史记录列表：分页、来源筛选、缩略图与元信息、云端入口 | 已实现（第二阶段 Agent 3）；第三阶段新增“云端记录”入口，模拟器渲染通过 |
| `app/entry/src/main/ets/pages/RecordDetail.ets` | 历史详情：原始/编辑框切换、改类、删除误检、删除记录 | 已实现（第二阶段 Agent 3），模拟器渲染与编辑/删除链路通过 |
| `app/entry/src/main/ets/pages/CloudRecords.ets` | 云端记录查询：时间/类别筛选、分页、统计、错误恢复 | 已实现（第三阶段 Agent 3）；经 `RecordClient` 接入真实后端，模拟器 E2E 显示 `共 4 条记录 · 8 个检测项` |
| `app/entry/src/main/ets/components/` | 可复用界面组件 | `camera/`（Agent 1）；`recognition/`（Agent 3，含 `RecordFormat`/`RecordImage`/`RecordThumb`、`CloudQuery`、`ModelUpdate`/`ModelUpdateBanner`） |
| `app/entry/src/main/ets/models/` | 跨模块共享类型与数据契约 | 已有第一阶段 + 第二阶段契约类型 |
| `app/entry/src/main/ets/services/camera/` | 相机生命周期、拍照、相册选图 | 已实现第一阶段：相册选图、Camera Kit 预览拍照、前后切换、权限、EXIF 归一化（Agent 1） |
| `app/entry/src/main/ets/services/inference/` | 模型加载、预处理、输出解析、NMS、坐标还原 | 已由 Agent 2 实现；第五轮模拟器实测真实推理输出（scissors 0.802 / potted plant 0.339）；laptop/keyboard 中低置信框未检出，逐框容差待对齐 |
| `app/entry/src/main/ets/tasks/` | TaskPool 后台任务与推理调度 | 已由 Agent 2 实现；第五轮模拟器实测 TaskPool worker 执行（`OK:already_init`），单次推理约 30 s |
| `tests/` | Agent 5 集成测试资产：图片、参考推理脚本与期望结果 | 已创建；图片与 `expected/` 可直接复用 |
| `app/entry/src/main/ets/services/imaging/` | 图像资源持久化：沙箱保存、缩略图、记录目录清理 | 已实现第二阶段（ImageAssetStore，Agent 1）；Agent 3 修复重复保存时 `records/` 已存在导致 EEXIST 的问题 |
| `app/entry/src/main/ets/services/storage/` | 本地 RDB 记录管理 | 已实现第二阶段（RecordService，Agent 4）；第五轮模型：保存不再直接入队，由调用方经 `SyncManager.onRecordSaved` 触发上传 |
| `app/entry/src/main/ets/services/network/` | HTTP 封装、JWT 鉴权存储、云端端口实现 | 已实现第三阶段（AuthStore/HttpClient，Agent 4）；Agent 0 补齐 `ModelClient`（ModelUpdatePort）与 `RecordClient`（CloudRecordPort），含二进制下载与 SHA-256 校验，模拟器 E2E 通过 |
| `app/entry/src/main/ets/services/sync/` | 上传队列、串行上传、网络监听调度 | 已实现第三阶段（SyncQueue/UploadService/SyncManager，Agent 4）；第五轮端云联调通过（保存后 33 ms 上传 created），并补延迟重试与失败日志 |
| `app/entry/src/main/resources/rawfile/models/` | YOLOv13 ONNX 模型资源 | 已有 `yolov13n.onnx`（被 `.gitignore` 排除） |
| `app/entry/src/main/resources/rawfile/samples/` | 内置示例图（模拟器/无媒体库环境跑通识别链路） | 已有 `04_multi_object_desk.jpg`，Index“示例图片”入口使用 |
| `app/entry/src/main/resources/base/` | 模块文案、颜色、图片与页面路由资源 | 已有基础资源 |
| `app/entry/src/main/resources/base/profile/main_pages.json` | 页面注册 | 已注册 pages/Index、pages/RecordList、pages/RecordDetail、pages/CloudRecords |
| `app/entry/src/main/module.json5` | Ability、设备类型、权限声明 | 已配置入口、网络与相机权限 |
| `app/AppScope/app.json5` | bundleName、版本、应用图标与名称引用 | 已配置 |
| `app/AppScope/resources/base/` | 应用名称与图标资源 | 已有 |

第一阶段计划新增 `components/camera/` 与 `components/recognition/`，分别由 Agent 1 与 Agent 3 创建。集成测试目录 `tests/` 由 Agent 5 维护；推理单元测试由 Agent 2 维护。

### 构建与依赖定位

| 路径 | 用途 |
| --- | --- |
| `app/build-profile.json5` | SDK 版本、产品与模块配置 |
| `app/entry/build-profile.json5` | entry 模块构建目标 |
| `app/oh-package.json5` | 工程级依赖 |
| `app/entry/oh-package.json5` | entry 模块依赖，ONNX 接入时重点检查 |
| `app/hvigor/hvigor-config.json5` | Hvigor 模型版本及配置 |
| `app/hvigorfile.ts`、`app/entry/hvigorfile.ts` | appTasks / hapTasks 构建入口 |
| `scripts/build-app.sh` | 使用 DevEco 内置 Java、Node 与 SDK 进行命令行构建 |
| `.gitignore` | 排除缓存、虚拟环境、构建产物、密钥及 ONNX 大文件 |

当前 modelVersion/targetSdkVersion 为 26.0.0，compatibleSdkVersion 为 6.1.1(24)。修改前检查本机工具链、目标设备和实际 API 兼容性。

### ABI / SDK 兼容性决策（Agent 0 · 2026-10-22 裁定）

**目标设备与最低要求**：**arm64-v8a 真机 + HarmonyOS SDK 26.0.0**。`compatibleSdkVersion 6.1.1(24)` 仅保证 ArkTS 基础语法与系统 API 可用，不保证 Native 推理与新版 UI API。

| ABI | 状态 | 说明 |
| --- | --- | --- |
| arm64-v8a | **完整支持** | HAP 包含 `libs/arm64-v8a/liblibrary.so`（ONNX Runtime OHOS，32 MB）+ `libonnx_native.so`（NAPI 桥），可端侧推理 |
| armeabi-v7a | **不支持推理** | HAP 仅含系统库，无 ONNX Runtime native libs。安装后 NativeBridge.initNative() 返回 `available=false`，UI 降级"识别不可用" |
| x86_64（模拟器） | **不支持推理** | 同上，ONNX Runtime OHOS npm 包未提供 x86_64 native libs。仅可用于 ArkUI 渲染、路由、RDB 等非 Native 功能验证 |

**已知 SDK 警告（构建不阻塞）**：

| 位置 | 警告 | 影响 | 处理 |
| --- | --- | --- | --- |
| `Index.ets:687` | `This API is unavailable to phone`（`systemDateTime.getUptime`） | 仅影响 UI 响应时间采样指标，phone 上跳过不记录 | 运行时降级，不阻塞主流程 |
| `CameraPreview.ets:374` | `fill API 需 SDK 26，compatible 24`（`Circle.fill()`） | SDK 24 模拟器上拍照按钮圆形填充色可能不生效；SDK 26 真机正常 | 真机目标无影响；低版本模拟器视觉降级 |
| `SyncManager.ets:111/129` | `需 ohos.permission.GET_NETWORK_INFO` | module.json5 未声明该权限 | 需后续补充声明（当前网络监听失败静默跳过） |

ONNX Runtime OHOS 包（`@ohos/onnxruntime_ohos`）当前版本仅提供 arm64-v8a 原生库；其他 ABI 需等官方补齐或自行交叉编译。如后续需支持更多 ABI，可在 CMakeLists.txt 加 `if(OHOS_ARCH STREQUAL "arm64-v8a")` 条件编译。

## 后端代码地图

| 路径 | 职责 | 当前状态 |
| --- | --- | --- |
| `backend/app/main.py` | FastAPI 实例、GET /health | 已实现 |
| `backend/app/api/` | 业务路由：auth 登录/刷新、models 版本/下载、records 批量上传/查询 | 已实现（Agent 4，第三阶段） |
| `backend/app/core/` | 配置、SQLAlchemy 会话、JWT 鉴权依赖、统一错误码 | 已实现（Agent 4，第三阶段） |
| `backend/app/models/` | Device / Record / RecordDetection / ModelVersion | 已实现（Agent 4，第三阶段） |
| `backend/app/schemas/` | Pydantic 请求与响应结构 | 已实现（Agent 4，第三阶段） |
| `backend/app/services/` | 鉴权、记录幂等写入与筛选分页、模型版本 | 已实现（Agent 4，第三阶段） |
| `backend/tests/` | pytest + TestClient 接口测试（24 个用例） | 已实现（Agent 4，第三阶段） |
| `backend/data/` | SQLite 开发库 `app.db`，首次启动自动创建 | 开发使用 |
| `backend/requirements.txt` | 基础依赖范围 | 已有 |
| `backend/requirements.lock.txt` | 已验证环境的精确依赖版本 | 已有 |
| `backend/.env.example` | 未来环境配置模板 | 已有，入口尚未加载 |

## 第一阶段模块协作

执行顺序：Agent 0 完成接口和兼容性准备 → Agent 1、2、3 并行 → Agent 4 数据与端云协同、Agent 5 测试与质量 → Agent 0 最终集成验收。具体提示词和文件所有权见 `docs/phase-1-agent-prompts.md`。

- Agent 0：架构与集成；共享类型（第一/第二阶段）、接口契约、模型与运行库兼容性、存储 schema、必要构建配置，以及各模块交付后的最终集成。
- Agent 1：图像采集、相机组件、相机权限及权限文案；扩展：原图 + 缩略图生成（`filesDir/records/`）。
- Agent 2：真实端侧推理、TaskPool、模型资源及推理测试。
- Agent 3：主页面、结果组件、编辑、阈值和响应指标展示；扩展：历史列表/详情页与"保存识别"入口。
- Agent 4：数据与端云协同；当前阶段：RDB 存储服务（`services/storage/`），后续：JWT、云端同步与模型更新规划。
- Agent 5：测试与质量（测试框架、用例、静态检查与验收证据整理）。

计划数据流：采集模块 → 契约规定的图像输入 → 推理调度 → 预处理/模型/NMS → 原图坐标检测结果 → 页面映射与编辑。共享契约应定义方向、镜像、坐标空间、资源所有权与线程传输规则。

## 公共执行规则

- 直接完成已授权任务与必要验证。遇到可恢复阻塞时尝试替代方案；关键歧义、破坏性操作或缺少授权时及时说明。
- 按分配范围修改代码。多人共享工程时保留其他人的改动；共享接口调整由负责人协调。
- 复用已有模式并保持小范围改动。onnxruntime-ohos 为需求指定依赖；其他新依赖按用户授权范围处理。
- 使用官方文档和维护方资料核实 API、模型与依赖版本。模型记录来源、许可证和 hash；输出解析依据实际模型元信息。
- 识别使用真实端侧模型。测试替身仅用于明确标记的测试环境，默认业务入口连接真实服务。
- 模型缺失、ABI 不兼容、权限不足和设备能力不足应提供明确错误与复现步骤。
- 推理任务串行执行，UI 使用请求标识避免旧结果覆盖新图片。遵守 ONNX session 的线程约束，确认 TaskPool 参数的传输能力。
- 分别记录预处理、推理、后处理、总耗时和 UI 响应指标；冷启动单独统计。
- 原始模型结果、用户编辑结果和分类计数保持可追溯关系。
- 完整 Hvigor 构建由负责人串行调度，避免多个 agent 同时写入构建缓存。
- 保持密钥在环境配置中。模型下载来源与校验方式写入文档，结合 `.gitignore` 管理大文件。

## 验证与运行入口

在项目根目录构建客户端：

```sh
./scripts/build-app.sh
```

脚本默认使用 `/Applications/DevEco-Studio.app/Contents`，可通过 `DEVECO_ROOT` 覆盖。未签名产物为 `app/entry/build/default/outputs/default/entry-default-unsigned.hap`；真机安装前配置签名。

启动后端（工作目录为 `backend/`）：

```sh
source .venv/bin/activate
python -m pip install -r requirements.lock.txt
python -m uvicorn app.main:app --reload --host 127.0.0.1 --port 8000
```

首次环境创建见 README。健康检查路径 `/health`，交互接口文档路径 `/docs`。第一阶段客户端离线识别可独立于后端开发。

每次变更运行相关构建、测试与适用静态检查，并阅读输出。当前尚无项目级 lint 或独立类型检查命令；ArkTS 编译是唯一静态门禁。主机参考推理（Agent 5 维护，需 onnxruntime/Pillow/numpy）：

```sh
python tests/tools/reference_inference.py \
  app/entry/src/main/resources/rawfile/models/yolov13n.onnx \
  tests/assets/images/*.jpg tests/assets/images/*.png \
  > tests/expected/reference-detections.json
```

人工检查场景见 `docs/phase-1-agent-prompts.md` 末尾表格。

完成报告区分：编译通过、算法测试通过、模拟器运行通过、真机运行通过。记录实际 SDK/设备/模型版本，未执行的验证标记待验证。第一阶段完成声明需要真实端侧推理证据。

## 交接与地图维护

- 第一阶段 agent 交接报告使用 `docs/phase-1-agent-N-report.md`，包含修改文件、导出接口、验证命令与结果、尚待验证项。
- 增加或移动模块、入口、文档或测试命令时同步更新本地图；实现预留模块后更新其状态。
- 需求清单仅勾选已有验证证据的项目。接口改变时同步更新契约与调用方。
- `build/`、`.hvigor/`、`oh_modules/`、`.venv/`、`__pycache__/` 属于产物或环境目录；常规代码检索聚焦上述源代码路径。
