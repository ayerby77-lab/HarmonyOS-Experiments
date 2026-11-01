# Agent 4 第三阶段交接报告 — 后端业务接口

> 负责人：Agent 4（数据与端云协同）。日期：2026-10-22 (Asia/Shanghai)。
> 范围：`backend/app/` 业务模块（配置、JWT 鉴权、SQLAlchemy 模型、FastAPI 路由、服务层、测试）。
> 开发数据库：SQLite `backend/data/app.db`。

## 1. 交付文件

### 新增

| 文件 | 职责 |
| --- | --- |
| `backend/app/core/config.py` | 环境变量配置（JWT、设备引导密钥、DB 路径、模型元数据与文件路径） |
| `backend/app/core/database.py` | SQLAlchemy 2.x 引擎 / 会话依赖 / `init_db()` 建表 |
| `backend/app/core/errors.py` | 统一错误码 `ErrorCode` 与 `ApiError` |
| `backend/app/core/auth.py` | Bearer 鉴权依赖 `get_current_device` |
| `backend/app/models/device.py` | `Device`（设备标识 + 密钥哈希） |
| `backend/app/models/record.py` | `Record`、`RecordDetection`（幂等键 `(device_id, record_id)`） |
| `backend/app/models/model_version.py` | `ModelVersion` |
| `backend/app/schemas/auth.py` | 登录 / 刷新 / 令牌响应 |
| `backend/app/schemas/records.py` | 批量上传、检测项、摘要、分页结构 |
| `backend/app/schemas/models.py` | 模型版本响应 |
| `backend/app/services/auth_service.py` | 设备登录、JWT 签发 / 校验 / 刷新 |
| `backend/app/services/record_service.py` | 批量幂等写入、筛选分页、计数重算 |
| `backend/app/services/model_service.py` | 当前模型版本与下载路径 |
| `backend/app/api/auth.py` | `POST /api/auth/login`、`POST /api/auth/refresh` |
| `backend/app/api/models.py` | `GET /api/models/version`、`GET /api/models/download` |
| `backend/app/api/records.py` | `POST /api/records`、`GET /api/records` |
| `backend/tests/conftest.py` + `test_auth.py` / `test_records.py` / `test_models.py` | 24 个接口测试 |

### 修改

| 文件 | 变更 |
| --- | --- |
| `backend/app/main.py` | 由仅 `/health` 扩展为应用工厂 `create_app()`：lifespan 建表并登记模型版本，统一异常处理，挂载三组路由 |
| `backend/requirements.txt` / `requirements.lock.txt` | 追加 SQLAlchemy 2.1.6、PyJWT 2.15.1、pytest 8.4.2、httpx 0.28.1 及传递依赖 |
| `backend/.env.example` | 补全可配置项说明 |

## 2. 目录结构

```
backend/app/
  main.py                 # create_app()、/health、异常处理、路由挂载
  core/  config.py database.py errors.py auth.py
  models/ device.py record.py model_version.py
  schemas/ auth.py records.py models.py
  services/ auth_service.py record_service.py model_service.py
  api/ auth.py models.py records.py
backend/tests/ conftest.py test_auth.py test_records.py test_models.py
backend/data/app.db       # 开发库（首次启动自动创建）
```

## 3. 配置项

| 环境变量 | 默认值 | 说明 |
| --- | --- | --- |
| `APP_ENV` | `development` | `production` 时关闭 `/docs` 与 `/openapi.json` |
| `JWT_SECRET` | 开发用占位串 | 生产必须覆盖，建议 ≥32 字节 |
| `ACCESS_TOKEN_TTL_S` | `1800` | access 令牌有效期（秒） |
| `REFRESH_TOKEN_TTL_S` | `604800` | refresh 令牌有效期（秒） |
| `DEVICE_SECRET` | 开发用占位串 | 新设备首次登录的引导密钥；生产必须覆盖 |
| `DB_PATH` | `backend/data/app.db` | SQLite 路径；也可用 `DATABASE_URL` 直接覆盖 |
| `MODEL_ID` | `yolov13n-coco-640-opset18` | 模型标识 |
| `MODEL_VERSION` | `1.0.0` | 当前版本 |
| `MODEL_SHA256` | `f39e5a…799b` | 与第一阶段模型一致 |
| `MODEL_PATH` | 客户端 rawfile 模型路径 | 下载接口读取的文件 |

## 4. 鉴权设计

```
POST /api/auth/login  {deviceId, deviceSecret}
  ├─ 设备不存在：deviceSecret == DEVICE_SECRET → 自动登记（存 sha256(deviceId:secret)）→ 发令牌
  ├─ 设备存在且密钥匹配 → 更新 lastLoginAtMs → 发令牌
  └─ 设备存在但密钥不匹配 / 未登记且引导密钥错误 → 401 DEVICE_AUTH_FAILED
POST /api/auth/refresh {refreshToken} → 校验 typ=refresh + 设备仍启用 → 轮换一对新令牌
```

- 令牌 claims：`sub=deviceId`、`typ=access|refresh`、`iat`、`exp`，HS256。
- 所有业务路由使用 `Depends(get_current_device)`；缺少令牌 `TOKEN_MISSING`，签名/类型错误 `TOKEN_INVALID`，过期 `TOKEN_EXPIRED`，设备停用 `DEVICE_DISABLED`，均为 401。
- 记录查询强制 `device_id == 当前设备`，设备间数据隔离。

## 5. 数据模型

### devices

| 列 | 说明 |
| --- | --- |
| `device_id` PK | 设备标识 |
| `secret_hash` | `sha256(deviceId:secret)`，不存明文 |
| `created_at_ms` / `last_login_at_ms` / `active` | 登记与登录状态 |

### records（幂等键 `UNIQUE(device_id, record_id)`）

| 列组 | 列 |
| --- | --- |
| 标识 | `id` PK、`device_id` FK、`record_id`、`payload_hash`、`revision` |
| 时间 | `captured_at_ms`、`recognized_at_ms`（索引）、`saved_at_ms`、`edited_at_ms`、`received_at_ms` |
| 图像 | `image_width`、`image_height`、`is_mirrored`、`image_origin` |
| 模型/参数 | `model_id`、`model_sha256`、`confidence_threshold`、`iou_threshold`、`max_detections`、`execution_mode` |
| 耗时 | `preprocess_ms`、`inference_ms`、`postprocess_ms`、`total_ms`、`cold_start`、`model_load_ms` |
| 结果 | `raw_detection_count`、`edited` |

### record_detections

| 列 | 说明 |
| --- | --- |
| `record_pk` FK ON DELETE CASCADE | 记录级联删除 |
| `detection_id`、`raw_index` | `UNIQUE(record_pk, raw_index)` |
| `raw_class_id` / `raw_label` | 模型原始类别（可追溯） |
| `class_id` / `label` | 用户编辑后的最终类别 |
| `confidence`、`left/top/right/bottom` | 原始置信度与归一化坐标 |
| `deleted`、`class_corrected`、`edited_at_ms` | 墓碑与编辑标记 |

### model_versions

`version` 唯一、`model_id`、`sha256`、`file_name`、`size_bytes`、`opset`、`input_width/height`、`class_count`、`released_at_ms`、`is_current`。启动时按配置自动 seed。

## 6. 接口清单

| 方法 | 路径 | 鉴权 | 说明 |
| --- | --- | --- | --- |
| GET | `/health` | 公开 | `{"status":"ok"}` |
| POST | `/api/auth/login` | 无 | 设备标识 + 密钥换令牌 |
| POST | `/api/auth/refresh` | 无（凭 refresh 令牌） | 轮换令牌 |
| GET | `/api/models/version` | Bearer | 当前模型版本、SHA-256、下载地址 |
| GET | `/api/models/download` | Bearer | 文件下载；缺失返回 404 `MODEL_NOT_FOUND` |
| POST | `/api/records` | Bearer | 批量上传（≤50 条），逐条幂等 |
| GET | `/api/records` | Bearer | `fromMs`/`toMs`/`classId`/`source`/`page`/`pageSize` 筛选分页 |

### POST /api/records 语义

- 请求体：`{"schemaVersion": 1, "records": [...]}`，字段按 `docs/api-plan.md` 完整定义。
- 逐条结果 `status`：`created` / `duplicate` / `conflict` / `invalid`，HTTP 200（部分成功）。
- 幂等判定：规范化 JSON（键排序、紧凑分隔符）的 SHA-256 相同 → `duplicate`，返回已有 `serverRevision`；不同 → `conflict`，不覆盖。
- 校验：`rawDetectionCount == len(detections)`、`rawIndex`/`detectionId` 唯一、`right>=left`、`bottom>=top`、`schemaVersion==1`；失败为 `invalid`，不影响同批其他条。
- `counts` 由服务端按 `deleted=false` 的最终 `classId` 重算（count 降序、classId 升序），不信任客户端计数。

### GET /api/records

- 排序：`recognizedAtMs DESC, recordId DESC`（同毫秒翻页稳定）。
- `classId` 仅匹配 `deleted=false` 的最终类别；时间范围为闭区间；`pageSize` 上限 100。
- 响应：`{items, page, pageSize, total, hasMore}`，`items[].counts` 为服务端重算结果。
- `fromMs > toMs` → 400 `VALIDATION_ERROR`。

## 7. 统一错误码

| code | 状态码 | 场景 | 客户端对应 |
| --- | --- | --- | --- |
| `TOKEN_MISSING` | 401 | 缺少 Bearer | 上传层重新登录 |
| `TOKEN_INVALID` | 401 | 签名/类型/主体错误 | 重新登录 |
| `TOKEN_EXPIRED` | 401 | access 过期 | 用 refresh 续期 |
| `DEVICE_AUTH_FAILED` | 401 | 设备密钥错误 | 提示重新配置 |
| `DEVICE_DISABLED` | 401 | 设备停用 | 永久失败 |
| `RECORD_NOT_FOUND` | 404 | 预留（详情接口后续） | 同名 `RecordErrorCode` |
| `RECORD_CONFLICT` | 单条状态 | recordId 相同、载荷不同 | 转永久失败 |
| `RECORD_INVALID` | 单条状态 | 不变量校验失败 | 丢弃该条 |
| `SCHEMA_VERSION_UNSUPPORTED` | 422 | 批次或单条 schemaVersion 不支持 | 升级客户端 |
| `MODEL_NOT_FOUND` | 404 | 模型文件缺失 | 对应 `RecognitionErrorCode.MODEL_MISSING` |
| `VALIDATION_ERROR` | 400/422 | 参数格式或语义非法 | 修正请求 |
| `STORAGE_WRITE_FAILED` | 单条状态 | 数据库写入异常 | 对应 `RecordErrorCode.DB_WRITE_FAILED` |
| `SERVICE_UNAVAILABLE` | 503 | 预留（数据库不可用） | 对应 `RecordErrorCode.DB_INIT_FAILED` |

错误响应统一为 `{"code", "message", "detail"}`。

## 8. 验证结果（本机，2026-10-22）

### 8.1 接口测试

```sh
cd backend && .venv/bin/python -m pytest tests -q
```

```
24 passed, 1 warning in 0.50s
```

覆盖：健康检查公开、登录成功/错误密钥、未知设备引导密钥、缺令牌/无效令牌 401、刷新换取可用 access、拒绝用 access 刷新、设备隔离、幂等上传、冲突不覆盖、计数不一致 invalid、部分成功、批次 schemaVersion 422、时间闭区间、类别筛选（含 deleted 排除）、计数重算、分页稳定性与 hasMore、来源筛选、非法时间范围、模型版本 seed、下载缺失 404。

### 8.2 启动与文档

```sh
cd backend && .venv/bin/python -m uvicorn app.main:app --host 127.0.0.1 --port 8000
```

| 检查 | 结果 |
| --- | --- |
| `GET /health` | 200 `{"status":"ok"}` |
| `GET /docs` | 200（Swagger UI 可交互） |
| `GET /openapi.json` | 200，路径：`/api/auth/login`、`/api/auth/refresh`、`/api/models/download`、`/api/models/version`、`/api/records`、`/health` |

### 8.3 真实进程冒烟

对运行中的服务执行：登录 → 上传 1 条 → 列表查询 → 类别筛选，均 200：

```
login: access token 179 字符
POST /api/records → {"status":"created","serverRevision":"1"}
GET  /api/records?page=1&pageSize=5 → total=1, counts=[{classId:41,label:"cup",count:1}]
GET  /api/records?classId=41 → total=1
```

## 9. 与客户端契约的差异与协调项

| 项 | 说明 | 建议 |
| --- | --- | --- |
| 路由前缀 | 用户指令为 `/api/auth|models|records`；`docs/api-plan.md` 原规划为 `/api/v1/...`。本实现按最新指令 | Agent 0 更新 `api-plan.md`，或后续加 `/api/v1` 别名 |
| `RecordSaveInput` 字段不足 | 本地 RDB 只存 boxes/尺寸/模型/耗时；上传需要 `requestId`、`imageId`、阈值、`recognizedAtMs` | RDB v2 增列或上传时由页面从 `DetectionResult` 补齐 |
| `recordId` 格式 | 客户端为 `rec_{ms}_{hex4}`；api-plan 样例为 UUID | 服务端不校验格式（仅长度），两者都接受 |
| 计数 | 客户端 `counts` 仅作参考，服务端重算 | 客户端以服务端返回为准 |
| 模型更新 | 本阶段只提供版本查询与下载 | 客户端模型更新/校验属后续阶段 |

## 10. 已知限制

1. **设备引导密钥是全局共享值**：`DEVICE_SECRET` 允许任意新 `deviceId` 自动登记，仅适合开发/内测；生产需改为预注册或邀请码。
2. **无令牌吊销**：refresh 轮换但旧 refresh 在过期前仍可用；未实现黑名单/版本号。
3. **SQLite 单机**：并发写依赖 SQLite 锁，生产应切换 PostgreSQL；`init_db()` 使用 `create_all`，后续接 Alembic 迁移。
4. **模型下载需本地文件存在**：`MODEL_PATH` 指向的 ONNX 被 `.gitignore` 排除，CI/新环境需先放置模型文件，否则下载接口返回 404。
5. **无详情/统计接口**：本次按任务范围只实现列表查询；`GET /api/records/{recordId}`、`GET /api/statistics` 仍待实现。
6. **`/docs` 仅开发环境**：`APP_ENV=production` 时关闭，符合 api-plan 约定。
7. **测试使用临时 SQLite**：每个测试独立库，未覆盖并发冲突（IntegrityError 分支为代码路径保证）。

## 11. 运行方式

```sh
cd backend
source .venv/bin/activate
python -m pip install -r requirements.lock.txt
python -m uvicorn app.main:app --reload --host 127.0.0.1 --port 8000

# 测试
python -m pytest tests -q
```

首次启动自动创建 `backend/data/app.db` 并登记模型版本。开发环境默认引导密钥为 `dev-device-secret-change-me`（与 `.env.example` 一致）。

## 12. 验收结论

| 验收项 | 状态 |
| --- | --- |
| 后端启动成功 | ✅ uvicorn 正常启动，lifespan 建表与 seed 完成 |
| 核心接口测试通过 | ✅ 24 passed |
| `/docs` 可交互 | ✅ 200，OpenAPI 含全部 6 条路径 |
| 幂等上传 | ✅ duplicate / conflict 语义测试通过 |
| 时间/类别筛选与分页 | ✅ 闭区间、deleted 排除、稳定排序、hasMore 测试通过 |

未执行：真机客户端对接后端、生产数据库与反向代理部署。

---

## 13. 客户端同步层（2026-10-22 追加）

### 13.1 后端复核结论（任务一）

- `python -m pytest tests -q` → **24 passed**（0.50s，含 StarletteDeprecationWarning 一条）。
- 六条接口与后端实现一致：`POST /api/auth/login`、`POST /api/auth/refresh`、
  `GET /api/models/version`、`GET /api/models/download`、`POST /api/records`、`GET /api/records`。
- **与 `docs/phase-3-contract.md` 的差异（需 Agent 0 确认修订契约）**：

| 契约（Agent 0 冻结） | 后端实现（用户任务一指定） | 建议 |
| --- | --- | --- |
| `POST /api/v1/auth/token`，请求体 `{deviceId, clientKey}` | `POST /api/auth/login`，`{deviceId, deviceSecret}` | 契约改路径与字段名，或后端加别名 |
| `POST /api/v1/auth/refresh` | `POST /api/auth/refresh`（语义一致） | 契约改路径 |
| `GET /api/v1/models/latest` | `GET /api/models/version` | 契约改路径 |
| `GET /api/v1/models/{version}/download` | `GET /api/models/download`（当前版本） | 契约改路径 |
| `POST /api/v1/records/batch`，扁平体（`boxes`/`modelSha256` 顶层） | `POST /api/records`，结构体（`model{}`/`options{}`/`timing{}`/`detections[]`） | 契约改上传体 schema（服务端实现更贴合 phase-1 数据契约的可追溯要求） |
| `SyncStatus` 由 Agent 0 在 RecordTypes.ets 扩展 | 尚未扩展；暂在 `services/sync/SyncQueue.ets` 本地定义 | Agent 0 扩展后 sync 改为 re-export |
| RDB 增 `cloud_synced` 等三列（契约 §6） | 未迁移；队列状态持久化在 Preferences | 后续 RDB v2 一并迁移 |

### 13.2 新增文件（任务二）

| 文件 | 职责 |
| --- | --- |
| `services/network/AuthStore.ets` | deviceId 生成持久化、token 存取（Preferences，密钥不进 RDB）、login/refresh/ensureValidToken；裸 http 调 `/api/auth/*`，不依赖 HttpClient（避免循环） |
| `services/network/HttpClient.ets` | Bearer 附加、401 → refresh 重试一次（并发去重）、统一 `NetworkFailure` 错误码（OFFLINE/UNAUTHORIZED/FORBIDDEN/NOT_FOUND/REJECTED/SERVER/INVALID_RESPONSE）映射后端错误体 |
| `services/sync/SyncQueue.ets` | 上传队列：Preferences 持久化（数组形式，ArkTS 不支持索引签名）、enqueue 幂等、退避 5s/30s/5min 最多 3 次、PENDING/UPLOADED/CONFLICT/FAILED |
| `services/sync/UploadService.ets` | 串行 flush（flushing 去重）、逐条组装 `RecordUploadItem` 调 `POST /api/records`、按 created/duplicate/conflict/invalid 更新队列；网络级失败中断本轮 |
| `services/sync/SyncManager.ets` | 统一调度：initialize（注入 context、注册 netAvailable 监听、启动即 flush 一次 = requeueStale 语义）、`onRecordSaved`、`syncNow()` 手动（清零退避窗口）、`snapshot()` 供 UI |

### 13.3 保存触发（任务三）

`RecordService.save` 成功（含 pathId 幂等返回路径）后调用模块级 `enqueueForSync(recordId)`
→ `SyncQueue.enqueue`；入队失败仅记日志、不影响保存结果。依赖方向
storage → sync/SyncQueue（SyncQueue 不引用 storage，无循环）。实际上传需
`SyncManager.initialize()` 已执行（建议 Agent 0 在 EntryAbility 接入，见 13.5）。

### 13.4 上传体组装默认值（RDB v1 字段缺口）

`assembleUploadItem(RecordDetail)`：`requestId`/`imageId` 取 recordId；
`capturedAtMs`/`recognizedAtMs`/`savedAtMs` 取 createdAtMs；`isMirrored=false`；
阈值取推理默认 0.25/0.45/100；`timing` 仅 `totalMs`/`coldStart` 可信，分段为 0；
`counts` 由 editedBoxes 重算（count 降序、classId 升序，与服务端规则一致）。
**待 RDB v2 增列后替换为真实值**（同 §9 协调项）。

### 13.5 接入与验证

- 构建：`./scripts/build-app.sh` → BUILD SUCCESSFUL（772ms，33 tasks），
  sync/network 五个文件 + RecordService 挂钩零 ArkTS 错误。
- 后端复测：24 passed。
- 建议 Agent 0 在 `EntryAbility.onWindowStageCreate` 增加
  `void SyncManager.getInstance().initialize(this.context);`，`onDestroy` 增加
  `SyncManager.getInstance().dispose();`（属共享入口，未越权修改）。
- 待验证（需设备/模拟器 + 运行中的后端）：保存后自动上传、断网入队与恢复重传、
  401 自动刷新、conflict 状态展示。本机无法启动模拟器 + 后端联调，标记待验证。
