# 第一阶段 图像识别 测试计划与验收矩阵

> 负责人：Agent 5（测试与质量）。版本：v1（2026-10-22，Asia/Shanghai）。
> 依据：`docs/requirements.md`、`docs/phase-1-contract.md`、`docs/phase-1-model.md`、`docs/phase-1-agent-prompts.md`。
> 配套资产：`tests/assets/images/`、`tests/expected/reference-detections.json`、`tests/tools/reference_inference.py`。
> 结论状态定义：**通过**＝有可复核证据；**失败**＝有证据表明不符合预期；**待验证**＝尚未执行或缺少设备；**阻塞**＝使验收无法继续。

## 1. 范围与证据分级

第一阶段范围：相册选图/拍照 → 真实 YOLOv13n 端侧推理 → 检测框、类别、置信度与分类计数 → 单次结果编辑 → 同步/TaskPool 耗时对比。RDB、JWT、云端同步、模型热更新不在本计划内。

证据分级（报告中必须标注）：

| 级别 | 含义 | 可接受证据 |
| --- | --- | --- |
| E1 编译 | Hvigor 构建通过 | 构建日志、HAP 清单 |
| E2 算法/主机 | 主机参考运行时或纯函数测试 | 测试输出、参考 JSON、对照脚本 |
| E3 模拟器 | API 24 arm64 模拟器实际运行 | 截图、hilog、hdc 命令记录 |
| E4 真机 | HarmonyOS 真机实际运行 | 截图、hilog、设备/系统版本 |

**第一阶段完成声明至少需要 E3 的真实端侧推理证据；仅有 E1/E2 不得声明通过。**

## 2. 目录与所有权

| 目录 | 所有者 | 内容 |
| --- | --- | --- |
| `tests/`（本计划新增） | Agent 5 | 测试图片、期望值、主机参考工具、集成检查记录。**待 Agent 0 在集成报告中确认独占。** |
| `app/entry/src/ohosTest/**`、推理单元测试 | Agent 2 | 推理纯函数与运行时单元测试；Agent 5 只审查覆盖、提交补充建议，不直接改其文件。 |
| `app/entry/src/main/ets/**` | Agent 1/2/3 | 业务实现；Agent 5 只读审查，不直接修改。 |

设备侧集成用例若需 ArkTS 测试工程，应先由 Agent 2 确定 Hypium 结构；Agent 5 在 `tests/` 记录用例和证据，避免与其测试目录冲突。

## 3. 测试资产

### 3.1 图片清单与许可

所有图片仅用于测试，不随 HAP 分发。文件 SHA-256 用于确认测试输入未被替换。

| ID | 文件 | 尺寸 | 场景 | 来源/许可 | SHA-256 |
| --- | --- | --- | --- | --- | --- |
| IMG-01 | `01_single_object_cup.jpg` | 1280×853 | 单物品（咖啡杯） | Wikimedia [Cup of coffee with beans](https://commons.wikimedia.org/wiki/File:Cup_of_coffee_with_beans.jpg)，Petr Kratochvil，CC0 | `d32ae1283102eecd1a828156840222a1a0754bcbf5b6f13cf596879800453847` |
| IMG-02 | `02_multi_object_bus.jpg` | 810×1080 | 多物品（公交车+多人，契约基准图） | Ultralytics `assets/bus.jpg`，AGPL-3.0，仅测试 | `c02019c4979c191eb739ddd944445ef408dad5679acab6fd520ef9d434bfbc63` |
| IMG-03 | `03_same_class_overlap_mugs.jpg` | 1920×1277 | 同类重叠（多个杯子前后遮挡） | Wikimedia [Mugs!](https://commons.wikimedia.org/wiki/File:Mugs!.jpg)，Sage Ross，CC BY-SA 2.0 | `5dc2a6d2581c4b0ef8052437e07cae21f6326107b55fd60ffc6a5d7e49a42302` |
| IMG-04 | `04_multi_object_desk.jpg` | 1920×1280 | 多物品（手机/书/笔电/绿植） | Wikimedia [White work table](https://commons.wikimedia.org/wiki/File:White_work_table_with_notes,_smartphone_and_laptop_(Unsplash).jpg)，JESHOOTS.COM，CC0 | `7d20ac7822e9241d27bd29791f98377fcc30f0cdd2d613d7f2b03dff2f4cbbfb` |
| IMG-05 | `05_long_horizontal_street.jpg` | 1920×793 | 横长图、无目标（空结果） | Wikimedia [Regent Street](https://commons.wikimedia.org/wiki/File:Panorama_of_the_Quadrant_on_Regent_Street.jpg)，Benh LIEU SONG，CC BY-SA 4.0 | `e3fc7d6605b8cc1cf9ebb8a90f51ded81541b5f576e4be3b6182d5d921eb5bc1` |
| IMG-06 | `06_long_vertical_cars.jpg` | 1920×4138 | 竖长图、多车 | Wikimedia [Panorama vertical 2](https://commons.wikimedia.org/wiki/File:Panorama_vertical_2_-_panoramio.jpg)，Ugo Cuesta，CC BY-SA 3.0 | `15c52847c4ccde985f362f1fba870414be59a2ab42c8ec950a870e3b01c447db` |
| IMG-07a | `07a_exif_orientation6.jpg` | 1080×810 存储，EXIF=6 | 方向信息（顺时针 90° 观看） | 由 IMG-02 派生 | `15fc5f2e80ba53680141b6969846b6a1a7242f8008176a2a651ce3e9b81ef8f8` |
| IMG-07b | `07b_exif_orientation8.jpg` | 1080×810 存储，EXIF=8 | 方向信息（逆时针 90° 观看） | 由 IMG-02 派生 | `60f89edddb4f110501adc16a4d79a21f3d1a2ec7870668071fbacc60b1e626de` |
| IMG-08 | `08_blank_gray.jpg` | 1280×960 | 空白图 | 生成（纯灰 128,128,128） | `84059af35c394555a0a73dc84f74c80dc15d10bdeaf8208c737db5481ee8d495` |
| IMG-09 | `09_corrupted.jpg` | — | 损坏文件（JPEG 头+随机字节） | 生成 | `f3ebee381227abc6878a6de75d422e8a372e20708491d31431324a287abbf321` |
| IMG-10 | `10_huge_8000x6000.jpg` | 8000×6000 | 超大图（RGBA 解码约 192 MB） | 生成 | `5b9fc04185d1703b02832216b62d6ca444a41fd6b316101cbcfcc24a9e2f02d5` |
| IMG-11 | `11_rgba_alpha_cup.png` | 1280×853 | RGBA 像素格式 | 由 IMG-01 派生（alpha=255） | `6709571f964d7a2f4ae67cebe91f56dd2d5c1c172ade18c9ce9d68b76d9ca8c3` |

派生图片沿用源许可；分发或对外展示时需保留上表署名与许可。IMG-02 为 AGPL-3.0 示例图，仅本地测试使用。

### 3.2 主机参考结果

`tests/tools/reference_inference.py` 按契约第 6 节实现：RGB、letterbox(114)、`round` 使用 JS 半入语义、`[1,84,8400]`、无 objectness、class-wise NMS IoU 0.7、逆变换与裁剪。结果写入 `tests/expected/reference-detections.json`。

运行环境：Python 3.12、onnxruntime 1.31.0（CPU）、Pillow 13.0.0、numpy 1.26.4；模型即 `rawfile/models/yolov13n.onnx`（SHA-256 `f39e5a…799b`）。**这是主机参考，不是端侧证据。**

| 图片 | 参考框数 | 类别（classId）与置信度 | 用途 |
| --- | --- | --- | --- |
| IMG-01 | 1 | cup(41) 0.9418 | 单物品、可信度 |
| IMG-02 | 5 | bus(5) 0.9370；person(0) 0.8958/0.8677/0.8517/0.4992 | 契约基准、多物品 |
| IMG-03 | 2 | cup(41) 0.8560/0.2702 | 同类 NMS 与计数 |
| IMG-04 | 5 | book(76) 0.8101；laptop(63) 0.8079；keyboard(66) 0.3884；potted plant(58) 0.3804；laptop(63) 0.2857 | 异类保留 |
| IMG-05 | 0 | — | 空结果（非空白但无 COCO 目标） |
| IMG-06 | 7 | car(2)×6（0.6847/0.6825/0.6228/0.6128/0.5384/0.4113）；truck(7) 0.4603 | 竖长图、过检抑制 |
| IMG-07a/07b | 5（方向归一化后） | 与 IMG-02 同类别；置信度差异 ≤ 0.02 | EXIF 方向归一化 |
| IMG-08 | 0 | — | 空白图 |
| IMG-11 | 1 | cup(41) 0.9418 | RGBA/Alpha 处理 |

端侧比对容差（插值实现不同）：框数允许 ±1；同类别置信度允许 ±0.05；框坐标允许 `max(8 px, 2% 图像边长)`。IMG-05/08 必须为 0 框，不应出现低置信度误检；若端侧出现，先按阈值边界与预处理差异登记，再判定。

## 4. 验收矩阵

状态列在每次执行后更新；证据写入 `docs/phase-1-review.md` 对应记录。

### 4.1 构建与部署

| ID | 需求 | 输入/前提 | 操作 | 预期 | 证据 | 状态 |
| --- | --- | --- | --- | --- | --- | --- |
| B-01 | R2 | 干净工程、模型存在 | `./scripts/build-app.sh` | BUILD SUCCESSFUL；HAP 生成 | 构建日志 | 通过（09:52 本角色执行 `BUILD SUCCESSFUL in 2 s 915 ms`；12:04:21 最新工作区构建 `BUILD SUCCESSFUL in 2 s 526 ms`，HAP 47,493,576 B；ohosTest HAP 已生成） |
| B-02 | R2 | HAP | `unzip -l` 检查 | 含 `libs/arm64-v8a/liblibrary.so` 与 `resources/rawfile/models/yolov13n.onnx` | HAP 清单 | 通过（09:51 产物 47,374,108 B，含 32,481,152 B 原生库与 10,171,778 B 模型）；此前 09:24 快照同样通过 |
| B-03 | R2 | 模型文件 | `shasum -a 256` | 等于 `f39e5a…799b` | 命令输出 | 通过（`f39e5a3b1763423b1e60769e81b08a5da012677dce0248f4b4a95c5ad5cb799b`） |
| B-04 | 契约 6.4 | 临时移除 rawfile 模型 | 构建并安装 | 构建/安装成功，首页可进入，识别显示不可用 | 日志/截图 | 待验证 |
| B-05 | 质量 | 全工程 | 静态检查（当前无项目级 lint；使用构建 ArkTS 检查） | 无新增错误；警告逐条登记 | 构建日志 | 通过（0 错误、7 条 ArkTS 警告：crypto `createMd/update/digest` 设备能力 ×3、`RecognitionService` 可能抛异常 ×2、`Index` 点击时间戳 API 手机不可用 ×1、ArkTS FAQ ×1；另有无签名与 SemVer 提示） |

### 4.2 预处理与后处理（算法边界）

优先由 Agent 2 单元测试覆盖；Agent 5 用主机参考结果交叉核对。仅当无法做成纯函数测试时才升级到设备。

| ID | 需求 | 输入 | 预期 | 状态 |
| --- | --- | --- | --- | --- |
| A-01 | R3 | RGB 像素已知图案（红/绿/蓝块） | NCHW 三个平面通道顺序为 R/G/B，值 = byte/255 | 待验证 |
| A-02 | R3 | RGBA（IMG-11） | 忽略 Alpha，结果与 RGB 源一致；不把 A 当 B | 待验证 |
| A-03 | R3 | `rowStride = width*3 + 4` 的填充行 | 仅读取每行前 `width*3` 字节，不串行 | 待验证 |
| A-04 | R3 | 图像 1280×853 | scale=0.5、newW=640、newH=**427**、padTop=**106**（JS `Math.round` 半入，不是 426/107） | 待验证 |
| A-05 | R3 | 853×1280、1001×999 等半像素尺寸 | 舍入与 padding 之和恰好 640；左右/上下分别只差 ≤1 | 待验证 |
| A-06 | R3 | IMG-06 竖长图 | scale=0.154664、newW=297、padLeft=171、padTop=0 | 待验证 |
| A-07 | R4 | 已知 1 个候选（conf 0.9, 1 类） | 还原坐标 = 原图像素；与参考偏差在容差内 | 待验证 |
| A-08 | R4 | 两个同类框 IoU>0.7、两个异类框 IoU>0.7 | 同类保留高置信度 1 个；异类都保留 | 待验证 |
| A-09 | R4 | 框超出图像边界 | 裁剪到 `[0,w]×[0,h]`；退化框丢弃 | 待验证 |
| A-10 | R4 | conf 阈值 0.25/0.5/0.9；`iouThreshold` 0.3/0.7 | 过滤在 NMS 前；结果与展示阈值一致 | 待验证 |
| A-11 | R4 | 阈值 0 或 1.01；maxDetections 0/301 | `INFERENCE_FAILED`，不启动任务，不崩溃 | 待验证 |
| A-12 | R4 | 300+ 个高分候选 | 全局最多 300，置信度降序 | 待验证 |
| A-13 | R4 | 模型输出全低分 | `boxes=[]`，状态 EMPTY，不是 ERROR | 待验证 |
| A-14 | R4 | 输出形状非 `[1,84,8400]` | 明确错误，不越界读，可重试 | 待验证 |
| A-15 | R6 | 任一成功结果 | `totalMs ≥ preprocessMs+inferenceMs+postprocessMs`；三阶段非负 | 待验证 |
| A-16 | R6 | 冷启动 | 冷启动耗时单独可查；`coldStart/modelLoadMs` 语义与实际一致 | 待验证 |

### 4.3 服务接口、状态与资源边界

| ID | 需求 | 操作 | 预期 | 状态 |
| --- | --- | --- | --- | --- |
| S-01 | 契约 4.2 | `initialize()` 连续调用 2 次 | 返回相同可用性；不重复创建 session、不泄漏 | 待验证 |
| S-02 | 契约 4.2 | 两个 `initialize()` 并发调用 | 只创建一次 session；两个 Promise 都完成 | 待验证 |
| S-03 | 契约 6.4 | 模型缺失 / hash 错误 | `available=false`，code=MODEL_MISSING / MODEL_INVALID，不抛异常 | 部分通过（2026-10-22 模拟器：模型复制失败→`MODEL_MISSING`、页面显示不可用、不崩溃；`MODEL_INVALID` 未取得证据） |
| S-04 | 契约 6.4 | 模型修复后再次 `initialize()` | 恢复可识别（**当前单例缓存失败状态，需实现确认**） | **失败**（09:54 模拟器点击“重新加载模型”无任何 ModelLoader 日志，直接返回缓存不可用；Q-01/BLK-4 实证） |
| S-05 | 契约 4.2 | 非 arm64 设备/ABI | `UNSUPPORTED_ABI`，识别禁用，不崩溃 | 待验证 |
| S-06 | 契约 4.2 | 运行中快速发起 10 次识别 | 任一时刻最多 1 个推理；排队请求 latest-wins；被替换者 `CANCELLED` | 待验证 |
| S-07 | 契约 4.2 | `cancel(未开始 requestId)` / 未知 id / 已完成 id | 未开始→CANCELLED；未知/已完成→无副作用、不抛 | 待验证 |
| S-08 | 契约 5.3 | `dispose()` 后再 `recognize/initialize` | 明确拒绝，不崩溃、不使用已关闭 session | 待验证 |
| S-09 | 契约 2.1 | 传入 data 长度不符 / rowStride 过小 / 0 尺寸 | `IMAGE_INVALID`，不启动推理 | 待验证 |
| S-10 | 契约 5.3 | 识别失败后再次识别 | 服务仍可用，可重试成功 | 待验证 |
| S-11 | 契约 5.3 | dispose 后检查 session/tensor | 全部 Close；无原生资源泄漏（日志/内存观察） | 待验证 |
| S-12 | 契约 4.2 | TaskPool 传参与返回 | 仅传可序列化数据；无 `10200006`；UI 像素缓冲仍有效 | 待验证 |

### 4.4 页面与交互（模拟器优先）

2026-10-22 第一轮模拟器实测：首页可启动并渲染；模型初始化因复制失败而不可用；首页“拍照”提示“相册服务不支持拍照”。第二轮（当前）代码已修复模型复制、SHA-256 算法名与初始化重试，拍照入口改接 `CameraPreview`，本表状态待第二轮设备复验后更新；回归用例见第 8 节。

| ID | 需求 | 操作 | 预期 | 状态 |
| --- | --- | --- | --- | --- |
| U-01 | R1 | 点击相册，选 IMG-01 | 图片显示正确、方向正确，可开始识别 | 阻塞（2026-10-22 模拟器：相册选择器停在“安全访问图库”加载态，无法选图；且模型不可用，见 BLK-8/BLK-10） |
| U-02 | R1 | 进入相册后取消 | 提示或静默返回；已有图片/结果不被破坏 | 部分通过（离开选择器后页面无图片状态保持、未崩溃；未观察到取消提示，且应用被切至后台） |
| U-03 | R1 | 拒绝相机权限，再次授权 | 首次提示明确；授权后相机可用 | 待验证 |
| U-04 | R1 | 进入/退出相机预览 ≥3 次，切后台再回 | 无崩溃；资源释放；恢复后可拍照 | 待验证 |
| U-05 | R1 | 切换前后摄像头（若设备暴露） | 预览/拍照正确；仅一个摄像头时合理禁用 | 待验证 |
| U-06 | R7 | IMG-02/03/04 识别 | 框贴合、类别/置信度显示；同类计数=保留框数 | 待验证 |
| U-07 | R7 | 横图/竖图/方图（IMG-05/06/01） | contain 留白正确；框无系统偏移；长图不拉伸 | 待验证 |
| U-08 | R7 | IMG-07a / 07b | 显示方向正确；无重复旋转；框对齐 | 待验证 |
| U-09 | R8 | 修改一项类别 | 框标签/列表/计数同步；原始结果仍可追溯 | 待验证 |
| U-10 | R8 | 删除一项误检 | 框/列表/计数同步；不出现负数或残留 | 待验证 |
| U-11 | R4 | 调整阈值 0.25→0.5→0.9 | 重新识别；展示的阈值与结果一致；不用旧结果本地过滤 | 待验证 |
| U-12 | R4/R7 | IMG-08 空白图；IMG-05 无目标 | EMPTY 状态明确，可继续选图 | 待验证 |
| U-13 | 错误 | 损坏模型/损坏图片（IMG-09/10） | 明确错误提示；可换图；不崩溃 | 待验证 |
| U-14 | 并发 | 连点识别 10 次后立即切换图片 | 至多 1 个推理；旧 requestId/imageId 结果不覆盖新图 | 待验证 |
| U-15 | 生命周期 | 识别中切后台/离开页面再返回 | 不崩溃；旧结果按 requestId 丢弃 | 待验证 |
| U-16 | R6 | 识别中操作交互探针 | TASK_POOL 模式可响应；SYNC 模式阻塞可观察 | 待验证 |

### 4.5 性能与离线

| ID | 需求 | 操作 | 预期 | 状态 |
| --- | --- | --- | --- | --- |
| P-01 | R6 | 同一模型、IMG-02，预热后 SYNC 连续 ≥10 次 | 记录每次三阶段/总耗时，报告中位数与环境 | 待验证 |
| P-02 | R6 | 同一模型、IMG-02，预热后 TASK_POOL 连续 ≥10 次 | 同上；记录 session 创建耗时 | 待验证 |
| P-03 | R6 | 冷启动首次识别（两种模式分别） | 单独列出 modelLoadMs 与总耗时，不混入热启动 | 待验证 |
| P-04 | R6 | 同步/异步各 10 次交互探针 | 独立 UI 响应指标；不以推理总耗时冒充 UI 响应 | 待验证 |
| P-05 | R5 | 10 次快速点击并查看 hilog | 日志证明最多一个推理在运行 | 待验证 |
| P-06 | 契约 6.4 | 模型随包部署后关闭网络 | 选图→识别→编辑全流程可用 | 待验证 |

## 5. Agent 2 单元测试覆盖审查

Agent 2 已交付 `app/entry/src/ohosTest/ets/test/InferenceEngine.test.ets`（19 例）与 Hypium 运行器，两个构建目标通过。截至本轮**执行证据仍为空**：Agent 2 报告自述“需在 arm64 真机或模拟器运行 `aa test`”，尚未提供运行输出。逐点核对如下：

| 覆盖点 | 最低断言 | 交付状态 |
| --- | --- | --- |
| 颜色通道 | RGB 已知图案 → 三平面值正确；RGBA 不被当作 RGB | 部分：RGB 纯色 NCHW 有断言；RGBA/Alpha 未覆盖 |
| letterbox 舍入 | 1280×853 → newH=427、padTop=106；半像素/奇数尺寸组合 | 部分：3 例覆盖宽/长/方图，未覆盖 1280×853 的具体舍入值 |
| letterbox 逆变换 | 已知候选 → 原图坐标；横/竖/方图 | 覆盖（4 例，含 padding 与裁剪） |
| rowStride 填充 | 带行尾填充的输入结果与紧凑输入一致 | 缺失 |
| NMS | 同类 IoU 0.7 边界（=0.7 保留、>0.7 抑制）；异类不抑制 | 覆盖 6 例（含阈值、边界、空输入、截断）；IoU 恰好 0.7 的边界待确认 |
| 阈值边界 | conf = 阈值时保留；阈值 0/1.01 拒绝；iou 边界 | 部分：conf 等于阈值有断言；0/1.01 参数校验属服务层，未覆盖 |
| 空输出 | 全低分 → 空数组；不抛异常 | 覆盖（全零输出） |
| 错误恢复 | 损坏输出形状/长度 → 明确错误；下一次调用成功 | 缺失 |
| 坐标裁剪 | 越界框裁剪、退化框丢弃 | 覆盖（2 例） |
| maxDetections | >300 候选取前 300，降序 | 覆盖（截断断言） |
| 耗时 | 三段非负且 total ≥ 三段和 | 缺失（仅有设备侧 benchmark 计划） |

补充建议（已提交 Agent 2，不直接修改其测试）：补 RGBA、rowStride、损坏输出与耗时不变式；将用例分组标注“纯函数（主机可跑）”与“设备运行”，并附 `aa test` 实际输出；TaskPool 与真实 session 用例单独标记，避免主机 CI 误判。

## 6. 已发现的边界问题（交给模块负责人）

仅记录，不在本计划中修改业务代码。

| ID | 位置 | 问题 | 影响 | 建议负责人/处理 |
| --- | --- | --- | --- | --- |
| Q-01 | `RecognitionService.initialize()` | 第一轮：初始化失败后 `initialized=true` 并缓存 `available=false`，再次调用直接返回缓存。**10:52 版本已改为：上次不可用时重新尝试**（`initialize()` 第 103 行仅缓存 available=true） | 契约 6.4 恢复路径；S-04 | Agent 2：已修复，待设备复验 S-04 |
| Q-02 | 契约 2.1/2.3、`isMirrored` | 若 Agent 1 产出 `isMirrored=true`，契约禁止页面翻转静态图，检测框与显示像素将错位 | 镜像照片框偏移 | Agent 0：本阶段强制静态图不镜像（`isMirrored=false`）或补充显示转换规则 |
| Q-03 | 契约 4.2 / `dispose()` | `recognize`/`initialize` 在未初始化、已释放时的错误码未统一（当前 initialize 抛普通 Error） | 页面错误处理与测试断言不稳定 | Agent 0/2：统一为 `RecognitionFailure` 并写清 code |
| Q-04 | `InferenceTiming` | SYNC 模式 `coldStart=false, modelLoadMs=0` 恒成立；初始化建 session 的耗时未进入任何结果；TaskPool 每个任务均 `coldStart=true` | “冷启动单独统计”口径不清晰 | Agent 2：日志/结果中单列 initialize 耗时并说明 TaskPool 口径 |
| Q-05 | `InferenceEngine.preprocess` | 双线性采样使用 `srcX = x/scale`（未做半像素中心偏移），与 OpenCV/PIL 结果存在系统性 ≤1 px 差异 | 与参考结果比对需容差；不是坐标空间错误 | Agent 2：在报告中说明；测试按容差判定 |
| Q-06 | `ModelLoader.verifySha256` | 一次性同步读取 10 MB 并计算 hash，在 UI 线程初始化时可能造成卡顿；未分块 | 首屏初始化响应 | Agent 2：设备上测 initialize 耗时；必要时异步/分块 |
| Q-07 | `ModelLoader.isAbiSupported` | 以 `abi.includes('arm64')` 判断；`deviceInfo.abi` 在部分 API 上可能为空/弃用 | 误报 UNSUPPORTED_ABI | Agent 2：设备日志核对；补充 fallback |
| Q-08 | `InferenceTask` | `@Concurrent` 函数引用 `InferenceEngine`/`ModelConstants` 导入；TaskPool 对跨模块引用的限制需实测 | 任务创建/执行可能抛序列化或模块错误 | Agent 2：设备实测；必要时内联纯函数或改 ThreadWorker |
| Q-09 | `InferenceOptions` | 契约 4.2 未明确 `iouThreshold` 非法时的行为（实现已校验），`cancel` 未知 id 语义未写明 | 测试预期不一致 | Agent 0：补契约一句 |
| Q-10 | 测试可注入性 | 服务没有注入 ABI/模型路径/时间源的测试入口；UNSUPPORTED_ABI、MODEL_INVALID 难以在 arm64 模拟器复现 | 部分错误路径只能靠移除模型或改构建 | Agent 2/0：提供测试构造方式或明确“仅设备手测” |
| Q-11 | `initialize()` / `postprocess` | 初始化只做 hash 校验，未核对 session 的实际输入/输出名与形状；后处理将 `8400` 写死 | 模型被替换但 hash 常量同步更新错误时，可能读越界或产生无意义框 | Agent 2：创建 session 后用 `GetInputNames/GetOutputNames` 校验名称与输出维度 |
| Q-12 | 页面编辑模型 | 删除为物理移除，未保留删除墓碑；第一阶段原始 `DetectionResult` 仍完整，故不影响本阶段验收，但影响后续保存/统计 | 后续 RDB 阶段无法重建误检删除记录 | Agent 3/4/0：后续阶段改为删除标记，本阶段记录为已知限制 |
| Q-13 | `services/inference/*` 编译 | 09:39:23 构建显示三处 ArkTS 错误：`InferenceEngine.ets:101` 解构声明、`ModelLoader.ets:106` 无类型对象字面量、`OnnxSessionWrapper.ets:25` 接口构造签名 | 当前工作区无法构建，所有 E3/E4 阻塞 | Agent 2：已修复；09:52 构建通过，关闭 |
| Q-14 | `ModelLoader.ensureModelInSandbox` | 第一轮：`getRawFileContent()` 返回 `Uint8Array` 直接传入 `fileIo.writeSync`，设备报 `Invalid argument`。**10:50 版本已改为复制独立 `ArrayBuffer` 并带 offset/length 写入** | 真机/模拟器识别全部不可用 | Agent 2：已修复，待设备复验 S-03 |
| Q-15 | `ModelLoader.verifySha256` | 第一轮：`createMd('SHA-256')` 在设备报 `create C obj failed`。**10:50 版本已改为 `createMd('SHA256')`** | hash 校验恒失败 | Agent 2：已修复，待设备复验 S-03 |
| Q-16 | 首页“拍照”入口 | 第一轮：页面调用恒拒绝的 `GalleryImageService.capturePhoto()`。**11:33 版本 `onCapturePhoto()` 改为打开 `CameraPreview` 覆盖层** | 拍照功能不可用 | Agent 1/3：已接入，待模拟器/真机验证 U-03/U-04 |
| Q-17 | `Index.recordTapProbe` | 编译警告 `ClickEvent.timestamp` 在手机上不可用；Agent 3 称已校验有限值后使用，不可用时跳过点击样本，定时器指标仍有效 | P-04 点击样本可能缺失 | Agent 3：设备实测确认是否有样本；必要时换时间源 |

## 7. 执行顺序与记录要求

1. 各模块交付后，由 Agent 0 串行调度构建（B-01），避免与其他 agent 同时写构建缓存。
2. 先跑 Agent 2 单元测试（E2），再跑模拟器用例（E3），最后真机（E4）。
3. 每条用例在 `docs/phase-1-review.md` 记录：操作步骤、预期、实际、设备与系统版本、模型 SHA-256、截图/日志路径、结论。
4. 模型误检/漏检、工程坐标错误、计数错误、设备能力限制分别登记，不互相掩盖。
5. 修复后重跑受影响用例；只有复测通过才关闭问题。

## 8. 第二轮回归用例（2026-10-22，待 Agent 0 稳定版本）

前提：12:04 构建产物（`BUILD SUCCESSFUL`，HAP 47,493,576 B）已包含 Q-01/Q-14/Q-15/Q-16 修复与 `BenchmarkRunner`；稳定版本以 Agent 0 通知为准。设备仍为 `VoiceCalculator_API24`（arm64，API 24）。证据统一写入 `tests/evidence/device-2026-10-22-round2/`。

| ID | 优先级 | 关联 | 操作 | 预期 | 判定证据 |
| --- | --- | --- | --- | --- | --- |
| R-01 | 1 | S-03、Q-14 | 冷启动安装后直接进入首页 | 日志出现 `设备 ABI: arm64-v8a, 支持: yes` → `模型复制并校验通过`；横幅不再显示模型缺失 | hilog + 截图 |
| R-02 | 1 | S-04、Q-01 | 模型不可用时点击“重新加载模型” | 每次点击都重新执行 ModelLoader（日志新增复制/校验行），不是返回缓存 | hilog 时间序列 |
| R-03 | 1 | U-06、P-01/P-02 | 使用 `/data/local/tmp/test_images/` 触发 `BenchmarkRunner`，跑 IMG-01/02/03/04/05/06/08/11 | `RESULT|` 行显示真实模型 hash；框数与参考 JSON 在容差内；IMG-05/08 为 0 框 | hilog `RESULT|`/`BOX|` |
| R-04 | 2 | U-03、Q-16 | 点击“拍照” | 打开 `CameraPreview` 覆盖层；模拟器无相机时显示相机失败面板并可返回，不崩溃 | 截图 + hilog |
| R-05 | 2 | U-01 | 点击“相册选图”，从模拟器图库选择 IMG-01 | 图片显示、方向正确；可进入识别 | 截图 |
| R-06 | 2 | U-02 | 相册内取消返回 | 保留原状态，无崩溃，无旧结果串入 | 截图 + hilog |
| R-07 | 3 | S-06、P-05 | benchmark 连续执行 SYNC 与 TASK_POOL 各 ≥10 次 | 任一时刻最多 1 个推理（日志无并行 RESULT 交错）；两种模式结果类别/框数一致 | hilog 时序 |
| R-08 | 3 | P-01/P-02 | 同一图片热身后各 10 次 | 记录每次 pre/infer/post/total；TASK_POOL 的 `cold/loadMs` 与 SYNC 分别标注 | `RESULT|` 行汇总 |
| R-09 | 3 | P-03 | 冷启动首次识别 | `coldStart=1` 与 `modelLoadMs` 单列，不与热启动混合 | 首条 `RESULT|` |
| R-10 | 3 | U-16、P-04 | TASK_POOL 运行中点击“响应探针”/切换模式 | UI 不卡死；探针样本增量；SYNC 运行中点击可观察阻塞 | 截图 + 探针数值 |
| R-11 | 4 | U-06/U-09 | IMG-02 成功后修改一项类别 | 框标签、清单、分类计数同步；原始值保留 | 截图 |
| R-12 | 4 | U-10 | 删除一项误检 | 框/清单/计数同步；显示“删除 1”；可恢复 | 截图 |
| R-13 | 4 | U-11 | 阈值 0.25→0.5→0.9 | 释放滑块后按新阈值重跑；不本地过滤旧结果；运行中排队 | 截图 + 日志 |
| R-14 | 4 | U-14 | 连续点击识别 10 次后立即切换新图 | 旧 requestId/imageId 结果不覆盖新图；最多 1 个运行 | 日志 + 截图 |
| R-15 | 4 | U-15 | 识别中切后台再回前台 | 不崩溃；旧结果被丢弃；可重新识别 | 日志 |
| R-16 | 5 | 第二阶段 §4 | 通过 benchmark 结果触发一次保存（若页面保存入口已接入） | `filesDir/records/{rec}_original.jpg` 与 `_thumb.jpg` 存在；缩略图最长边 ≤480、比例一致、方向正确 | `hdc shell ls -l` + 图片回读 |
| R-17 | 5 | 第二阶段 §5.3 | 清除应用数据后重启，检查孤儿清理 | 无 RDB 引用的 `records/` 文件被清理；10 分钟内新文件不被误删 | hilog + 文件列表 |
| R-18 | 5 | 第二阶段 §4.1 | 保存后 `aa force-stop` 再启动，查询记录 | 记录仍可读，图像绝对路径可重建 | 页面/日志 |
| R-19 | 5 | 第二阶段 §5.2 | 模拟图像编码失败或 DB 写失败 | 不留半成品文件；失败可重试 | 日志（若无法注入则标“环境受限”） |
| R-20 | 3 | 离线 | 关闭模拟器网络后重复 R-03 | 识别不受影响（模型与推理均在本地） | 日志/截图 |

环境受限项：R-04 相机预览在模拟器可能无摄像头；R-16/R-18/R-19 依赖页面保存入口与失败注入能力，若未接入则仅记录服务层静态证据并转 `phase-2-review.md` 待验证。

### 8.1 第二轮执行结果（2026-10-22 12:10–12:22，12:18 HAP）

| ID | 结果 | 说明 |
| --- | --- | --- |
| R-01 | **通过** | 冷启动 `从 rawfile 复制模型` → `模型复制并校验通过`；热启动 `模型已在沙箱且校验通过`；session 46–57 ms |
| R-02 | 待验证 | Q-01 代码已改为仅成功缓存；本轮未构造模型失败场景 |
| R-03 | **失败** | 找到 12 张图，首张 SYNC 推理 85 ms 后原生 `SIGSEGV`（`OnnxTensor` 构造），无 `RESULT|` 输出 |
| R-04 | **失败** | 相机覆盖层可打开并弹权限框；拒绝或允许后退出组件均崩溃（`CameraPreview.ets:149`） |
| R-05 | **环境受限** | 模拟器无系统图库，`aa start` 报 `10104001`，选择器停在“处理中…” |
| R-06 | 部分通过（第一轮） | 离开选择器后页面状态保持、未崩溃；本轮未重复 |
| R-07–R-15 | **阻塞** | 首个推理即崩溃，无结果/耗时/编辑/并发证据 |
| R-16–R-19 | **阻塞** | 第二阶段入口未接入（`phase-2-review.md`） |
| R-20 | 待验证 | 依赖 R-03 |

证据：`tests/evidence/device-2026-10-22-round2/`（截图 12 张、JS 崩溃 3 份、原生崩溃 2 份）。详细日志与阻塞项见 `docs/phase-1-review.md` 第 9 节。
