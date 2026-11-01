# 项目开发清单

依据《实验三 智能物品识别助手 APP》整理。勾选标记区分**后端 pytest 验证**和**客户端真机验证**；模拟器渲染/代码骨架完成标记 `(骨架)`。

## 客户端（arkTS/ArkUI · 鸿蒙）

| # | 功能 | 状态 | 证据 |
| --- | --- | --- | --- |
| C1 | 相机拍照、实时预览、前后摄像头切换、相册选图 | (部分) | 相册选图与内置示例图入口已可用（模拟器 E2E：rawfile 样例 1920×1280 解码 → 识别）；相机预览/拍照代码完成，模拟器无虚拟相机帧，待真机（BLK-10 媒体库注入受限） |
| C2 | onnxruntime-ohos 集成及 yolov13n.onnx 加载 | (已通过·模拟器) | nativeInit `OK:CE=3 sessIdx=8`；真实推理输出已产出：识别完成 2 项（scissors 0.802 / potted plant 0.339），RESULT/BOX 链路打通（2026-11-01 全链路 E2E） |
| C3 | letterbox、归一化、NCHW 转换及比例/padding 记录 | (部分) | letterbox/NCHW 代码在端侧生效，输出与主机参考基本对齐（scissors 0.802 vs 0.810、potted plant 0.339 vs 0.380）；参考中的 laptop 0.808 / keyboard 0.388 端侧未检出，逐框容差待对齐 |
| C4 | 输出解析、NMS、检测框原图坐标还原、置信度阈值调整 | (已通过·模拟器) | 端侧输出解析/NMS/坐标还原生效：1920×1280 原图上框位置正确渲染；置信度阈值 0.25 过滤生效 |
| C5 | TaskPool 异步推理，防抖或串行排队 | (已通过·模拟器) | TaskPool worker 实际执行（`OK:already_init`），单次推理约 30 s（模拟器翻译层开销）；串行 + latest-wins 生效 |
| C6 | 预处理/推理/后处理耗时，同步/异步界面响应对比 | (部分) | 耗时面板记录 preprocess/inference/postprocess/total 并在记录中落库（total_ms 已上传）；同步 vs TaskPool 对比数据未采集；`getUptime` 在 phone 上降级（SDK 警告） |
| C7 | 检测框、类别、置信度展示及分类计数 | (已通过·模拟器) | 截图为证：`tests/evidence/2026-11-01-round4/ui_detection_boxes.png`；分类计数 potted plant ×1、scissors ×1，置信度随框展示 |
| C8 | 修正类别、删除误检项 | (已通过·模拟器) | 历史详情改类/删除链路通过（第二阶段）；本轮产生真实可编辑记录（RDB boxes=2） |
| C9 | RDB 保存缩略图、物品清单、识别时间；按时间和类别查询 | (部分) | 保存落 RDB + 原图 211KB/缩略图 17KB 持久化（`Saved record ..., boxes=2`）；历史列表/详情渲染通过；保存后重启的持久化证据待补 |
| C10 | 批量上传、recordId 幂等、本地待传队列、联网自动重传 | (已通过·模拟器) | 端云联调通过：保存 → 入队 → 自动上传 `POST /api/records` created，33 ms 完成（修复保存绕过 `onRecordSaved` 的断点）；断网/失败延迟重试生效 |
| C11 | 启动检查模型版本，下载并替换模型 | (部分) | `services/network/ModelClient.ets` 实现 ModelUpdatePort 并在 EntryAbility 注册；模拟器 E2E：启动日志 `ModelClient: 模型已是最新: 1.0.0`。下载/替换路径代码完成（`HttpClient.getBinary` + SHA-256 校验 + 原子替换 + `RecognitionService.replaceModel`），因后端仅有同 hash 版本，成功下载待补第二个模型文件后验证 |
| C12 | 云端历史与统计，时间/类别筛选及分页 | (已通过·模拟器) | `RecordClient` 实现 CloudRecordPort；云端页实测显示 `共 4 条记录 · 8 个检测项`，明细（时间/来源/类别/TaskPool/total_ms/尺寸）与端侧记录一致，分页/统计/JWT 鉴权链路通 |
| C13 | 统一接口错误码及关键流程验证 | (部分) | RecognitionErrorCode/RecordErrorCode/NetworkErrorCode 映射已实现；上传失败时记录错误码并进入延迟重试；未逐条核对全部错误分支（round-2 §5） |

**剩余待补验证项**（2026-11-01 全链路 E2E 之后）：
- 相机预览/拍照：模拟器无虚拟相机帧，需真机（C1）
- 逐框容差对齐：laptop/keyboard 中低置信框端侧未检出（C3）
- 保存后重启的 RDB 持久化确认（C9）
- 同步 vs TaskPool 耗时对比数据采集（C6）
- ModelClient 真实下载/替换：需后端提供第二个模型文件（C11）
- ohosTest 推理单测执行（Q-19，长期未解）

## 后端（FastAPI · Python）

| # | 功能 | 状态 | 证据 |
| --- | --- | --- | --- |
| B1 | 设备标识 + 密钥换取 JWT、自动刷新、401 响应 | ✅ 通过 | 10 pytest 用例通过；登录/刷新/鉴权失败全路径覆盖（test_auth.py） |
| B2 | 批量上传、recordId 幂等、冲突不覆盖、计数重算 | ✅ 通过 | 11 pytest 用例通过；duplicate/conflict/invalid 三种状态 + rawDetectionCount 校验覆盖（test_records.py） |
| B3 | 时间/类别/来源筛选、分页、稳定排序 | ✅ 通过 | 分页 hasMore + 闭区间时间 + deleted 排除类别筛选覆盖 |
| B4 | 模型版本查询与下载 | ✅ 通过 | 3 pytest 用例通过；文件缺失返回 404（test_models.py） |
| B5 | `/health` 公开健康检查 | ✅ 通过 | GET /health → `{"status":"ok"}`，/docs 可交互 |

**后端已知缺口**：
- ~~无 `/api/statistics` 统计接口（契约预留）~~ **已实现**（2026-11-01）：`GET /api/statistics?fromMs&toMs`，与客户端 CloudStatistics 对齐
- ~~无 `/api/records/{recordId}` 详情接口~~ **已实现**（2026-11-01）：`GET /api/records/{recordId}`，含完整检测项（rawIndex 升序）
- SQLite 单机 + 并发写依赖 SQLite 锁（生产应切换 PostgreSQL）
- `DEVICE_SECRET` 全局共享（生产需预注册或邀请码）

---

> **完成判定**：客户端以「真机 arm64-v8a + SDK 26 有端侧推理 RESULT/BOX 输出 + 保存后重启持久化」为完成门禁（见 `docs/phase-1-review.md`）。后端以「pytest 全绿 + Swagger 可交互」为完成门禁（已达成）。
>
> 最后更新：2026-11-01（补 `ModelClient`/`RecordClient` 两个端口实现类，模拟器 E2E 验证云端查询与模型版本检查；后端 pytest 32 通过）。
