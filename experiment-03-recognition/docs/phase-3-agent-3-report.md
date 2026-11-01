# Agent 3｜第三阶段 UI 交接报告

> 身份：Agent 3（用户界面）。日期：2026-10-22（Asia/Shanghai）。
> 范围：`pages/Index.ets`、`components/recognition/`、`pages/RecordList.ets`、`pages/RecordDetail.ets`，另按任务新增 `pages/CloudRecords.ets`。
> 设备：HarmonyOS 模拟器 `VoiceCalculator_API24`（arm64，API 24）；构建使用项目脚本 `./scripts/build-app.sh`。

## 1. 结论

- 任务一：第二阶段 UI 与 `RecordService` API 逐项核对通过，**无需修改**现有保存、列表、详情逻辑。
- 任务二：新增云端记录查询页与 UI 侧查询端口；时间范围、类别筛选、分页、云端统计、加载/空/错误/未接入状态均已实现。`services/network/`（AuthStore/HttpClient）与 `services/sync/`（SyncQueue/UploadService/SyncManager）已由 Agent 4 交付，但尚无 `RecordClient`/`ModelClient` 或 `CloudRecordPort` 实现，页面按 `phase-3-contract.md` 第 4 节约定降级为“云端服务尚未配置”，不自行实现 HTTP。
- 任务三：网络异常提示（原文“网络异常，记录将在恢复后自动上传”）、鉴权失败引导重新登录、模型更新可用/下载进度/完成/失败 UI 均已实现并接入端口。
- 构建通过；模拟器验证了云端页降级态与脚手架数据下的完整交互，以及模型更新进度 UI。
- 未验证：真实 HTTP/JWT、真实云端统计、真实模型下载（依赖 Agent 0 的 `services/network/` 与 Agent 4 的 `services/sync/`）。

## 2. 任务一：第二阶段 UI 联调核对

| 验收点 | 实现位置 | 核对结果 |
| --- | --- | --- |
| 保存按钮仅在识别成功后出现 | `Index.handleSave` + 条件 `status === SUCCEEDED && result !== undefined` | 通过：空结果、运行中、不可用均不显示 |
| 保存成功 Toast | `Index.handleSave` → `this.notify('已保存到历史记录')`，按钮转为“已保存到历史记录” | 通过 |
| 保存失败回滚图片 | RDB 写失败时 `assetStore.deleteImages(context, assets.originalPath, assets.thumbnailPath)` 后再提示 | 通过：与 `phase-2-contract.md` §4.3 一致 |
| “历史记录”跳转 `pages/RecordList` | `Index.openHistory` → `pushUrl({ url: 'pages/RecordList' })` | 通过；路由已在 `main_pages.json` 注册 |
| 列表分页 `list(page, pageSize, sourceFilter?)` | `RecordList.reload` / `loadMore`，`PAGE_SIZE = 20` | 通过；`querySeq` 防筛选/翻页竞态 |
| 列表展示缩略图/时间/来源/物品数/模式/耗时 | `RecordList.recordRow`：`RecordThumb`、`formatRecordTime`、`formatSource`、`${editedTopClassLabel} 等 N 项`、`formatExecutionMode`、`formatMs` | 通过 |
| 来源筛选（相机/相册） | `FILTERS` + `applyFilter` → `list(1, PAGE_SIZE, sourceFilter)` | 通过 |
| 点击进入 `RecordDetail` | `openDetail` → `pushUrl('pages/RecordDetail', { recordId })` | 通过 |
| `getDetail(recordId)` 取原始框与编辑后框 | `RecordDetail.loadDetail` → `RecordService.getDetail`；`rawBoxes` / `editedBoxes` 分别保存 | 通过 |
| 编辑后框优先、可切换原始 | `viewRaw = false` 默认；`switchView(raw)` 重建 items；原始视图 `readOnly` | 通过 |
| 改类/删框 → `updateEdited` | `applyClassChange` / `setDeleted` → `persistEdits` → `RecordService.updateEdited(recordId, toModelBoxes(items))` | 通过；失败回滚并 Toast |
| 删除 → `delete(recordId)` | `confirmDeleteRecord` → `deleteRecord` → `RecordService.delete` → `router.back()` | 通过 |

结论：第二阶段 UI 与 `RecordServiceApi`（`docs/phase-2-contract.md`）完全对齐，本阶段未改动其逻辑。

## 3. 任务二：云端记录查询 UI

### 3.1 新增文件

| 文件 | 职责 |
| --- | --- |
| `app/entry/src/main/ets/components/recognition/CloudQuery.ets` | UI 侧云端查询端口、DTO、注册表、错误映射 |
| `app/entry/src/main/ets/pages/CloudRecords.ets` | 云端记录页：时间/类别筛选、分页、统计、错误恢复 |

### 3.2 端口边界（UI 不处理 HTTP）

```ts
export interface CloudRecordPort {
  list(filter: CloudQueryFilter): Promise<CloudRecordPage>;
  statistics(filter: CloudStatisticsFilter): Promise<CloudStatistics>;
  reauthenticate(): Promise<void>;
}
export class CloudRecordRegistry {
  static register(port: CloudRecordPort): void;
  static resolve(): CloudRecordPort | undefined;
  static available(): boolean;
}
```

- 错误由实现方映射为 `CloudQueryFailure.kind`：`UNAVAILABLE` / `NETWORK` / `AUTH` / `SERVER` / `UNKNOWN`；页面通过 `describeCloudError` 统一转成提示与动作（重试 / 重新登录）。
- 页面不 import `@ohos.net.http`，不拼接 URL，不解析后端 JSON。
- 端口未注册时展示“云端服务尚未配置，当前仅支持本地历史记录”，并提供“返回本地历史”。

### 3.3 页面能力

- 时间范围：今天 / 近 7 天 / 近 30 天 / 全部（默认近 7 天）。
- 类别筛选：统计结果中的类别 chip 快捷筛选；“选择类别”打开 COCO 80 类选择器；“全部类别”复位。
- 分页：`PAGE_SIZE = 20`，上一页/下一页，显示“第 N 页 · 共 M 条”；`querySeq`/`statsSeq` 防旧响应覆盖。
- 云端统计：总记录数、总检测项、各类别数量 chip；统计失败单独降级提示，不影响列表。
- 状态：加载、空、错误（重试/重新登录）、未接入；进入页面自动查询。
- 列表项：时间、来源、物品数与 top 类别、执行模式、总耗时、原图尺寸、类别计数。
- 入口：`RecordList` 头部“云端记录”按钮 → `pages/CloudRecords`；路由已注册。

### 3.4 Agent 0/4 接入方式

1. 实现 `CloudRecordPort`（建议位于 `services/sync/CloudRecordService.ets` 或 `services/network/RecordClient.ets`），把后端 `GET /api/records` 映射为 `CloudRecordPage`，`GET /api/statistics` 映射为 `CloudStatistics`。
2. 在 `EntryAbility.onWindowStageCreate` 中调用 `CloudRecordRegistry.register(...)`；只需注册一次。
3. 错误映射：超时/断网 → `NETWORK`；401/403 → `AUTH`（`reauthenticate()` 走 `AuthService` 刷新或重新登录）；5xx/响应格式错误 → `SERVER`；接口未就绪 → `UNAVAILABLE`。

> 后端现状（`docs/phase-3-agent-4-report.md`）：已实现 `GET /api/records`（时间/类别/来源/分页），尚无 `/api/statistics` 与 `/api/records/{recordId}`；契约中的 `/api/v1` 前缀也未落地。实现端口时需按实际路径适配；统计接口缺失时 `statistics()` 应抛 `UNAVAILABLE`，页面会单独提示“统计不可用”。
>
> 当前网络层现状：`services/network/HttpClient.ets` 已提供带鉴权与 401 刷新重试的 `get/post`，`AuthStore` 负责令牌；`services/sync/UploadService.ets` 仅覆盖上传（`POST /api/records`）。云端查询端口可直接基于 `HttpClient` 实现，UI 无需改动。

## 4. 任务三：错误提示与用户体验

| 场景 | 行为 | 实现 |
| --- | --- | --- |
| 网络不可用 | 提示“网络异常，记录将在恢复后自动上传”，提供“重试”；空态文案说明恢复后自动上传 | `CLOUD_OFFLINE_MESSAGE` + `CloudRecords` 错误卡片 |
| 鉴权失败 | 提示“登录已过期，需要重新授权”，显示“重新登录”；成功后自动刷新列表与统计 | `CLOUD_AUTH_MESSAGE` + `relogin()` → `port.reauthenticate()` |
| 云端服务未接入 | 显示“云端服务尚未配置，当前仅支持本地历史记录” | `CLOUD_UNAVAILABLE_MESSAGE` |
| 模型更新 | 新版本提示（版本/原因/体积）→“立即更新”→ 线性进度百分比 → 完成或失败重试 | `ModelUpdate.ets`、`ModelUpdateBanner.ets`、`Index.checkModelUpdate/startModelUpdate` |

模型更新端口：

```ts
export interface ModelUpdatePort {
  check(currentModelId: string, currentSha256: string): Promise<ModelUpdateInfo | null>;
  download(info: ModelUpdateInfo, onProgress: (fraction: number) => void): Promise<void>;
}
```

- `Index` 启动时查询一次；未注册或查询失败静默跳过，不影响离线识别。
- 下载完成后展示“模型 X 已更新，已重新加载”，并调用 `RecognitionService.initialize(true)`。
- 下载失败展示原因与“重试”；旧模型在替换成功前保持可用（实现方负责原子替换与 SHA-256 校验）。
- Agent 0 接入：实现 `ModelUpdatePort`（建议 `services/network/ModelUpdate.ets` 或 `ModelClient.ets` 适配），启动时 `ModelUpdateRegistry.register(...)`。

## 5. 验证记录

### 5.1 构建

```sh
./scripts/build-app.sh
# BUILD SUCCESSFUL in 3 s 27 ms（最终生产版，脚手架已移除）
```

无新增 ArkTS 警告；既有警告仍来自 `CameraPreview`（Agent 1）与 `Index` 的 `ClickEvent.timestamp`（SDK 提示）。

### 5.2 模拟器验证

设备：`VoiceCalculator_API24`（arm64，API 24），`hdc install -r` 安装未签名 HAP，`aa start -a EntryAbility -b com.example.smartitemassistant -U 100` 启动，`snapshot_display` 截图。

| 截图 | 场景 | 结果 |
| --- | --- | --- |
| [01-cloud-unavailable.jpeg](computer:///Users/avery/Desktop/hongmeng/SmartItemRecognitionAssistant/docs/assets/phase-3-agent-3/01-cloud-unavailable.jpeg) | 生产构建，端口未注册 | 显示“云端服务尚未配置”，本地入口可用 |
| [02-cloud-list.jpeg](computer:///Users/avery/Desktop/hongmeng/SmartItemRecognitionAssistant/docs/assets/phase-3-agent-3/02-cloud-list.jpeg) | 脚手架数据：26 条、5 类统计 | 范围 chip、类别 chip、统计、列表、分页均正常 |
| [03-cloud-class-filter.jpeg](computer:///Users/avery/Desktop/hongmeng/SmartItemRecognitionAssistant/docs/assets/phase-3-agent-3/03-cloud-class-filter.jpeg) | 选择 cup 类别 | 结果 9 条，类别 chip 高亮，下一页禁用，统计保持全量 |
| [04-cloud-page-2.jpeg](computer:///Users/avery/Desktop/hongmeng/SmartItemRecognitionAssistant/docs/assets/phase-3-agent-3/04-cloud-page-2.jpeg) | 翻到第 2 页 | “第 2 页 · 共 26 条”，上一页可用、下一页禁用 |
| [05-cloud-offline.jpeg](computer:///Users/avery/Desktop/hongmeng/SmartItemRecognitionAssistant/docs/assets/phase-3-agent-3/05-cloud-offline.jpeg) | 端口抛 NETWORK | 提示“网络异常，记录将在恢复后自动上传”+“重试”；统计单独降级 |
| [06-cloud-auth.jpeg](computer:///Users/avery/Desktop/hongmeng/SmartItemRecognitionAssistant/docs/assets/phase-3-agent-3/06-cloud-auth.jpeg) | 端口抛 AUTH | 提示“登录已过期，需要重新授权”+“重新登录” |
| [07-model-update-available.jpeg](computer:///Users/avery/Desktop/hongmeng/SmartItemRecognitionAssistant/docs/assets/phase-3-agent-3/07-model-update-available.jpeg) | 有新模型 | 显示 v1.1.0、精度提升、12.0 MB、“立即更新” |
| [08-model-update-progress.jpeg](computer:///Users/avery/Desktop/hongmeng/SmartItemRecognitionAssistant/docs/assets/phase-3-agent-3/08-model-update-progress.jpeg) | 下载中 | 进度条与“正在下载模型 30% · 完成后自动重新加载” |
| [09-model-update-installed.jpeg](computer:///Users/avery/Desktop/hongmeng/SmartItemRecognitionAssistant/docs/assets/phase-3-agent-3/09-model-update-installed.jpeg) | 下载完成 | 显示“模型 1.1.0 已更新，已重新加载” |

说明：02–06 与 07–09 的数据态使用临时 `TEMP-VERIFY` 脚手架（注册演示 `CloudRecordPort` / `ModelUpdatePort`）驱动，用于验证真实渲染与交互；脚手架已完整移除，`grep -rn "TEMP-VERIFY\|DemoCloudPort\|DemoModelUpdatePort" app/entry/src/main/ets` 无结果，最终构建与 01 截图来自生产代码。

### 5.3 未验证项

- 真实 HTTP 请求、JWT、401 自动刷新、超时与断网重连（`HttpClient`/`AuthStore` 已交付，但云端查询端口尚未实现）。
- 真实云端分页/统计与上传后查询（依赖云端查询端口与后端统计接口）。
- 真实模型下载、原子替换、SHA-256 校验与重新加载（依赖 Agent 0/2 提供 `ModelUpdatePort` 实现）。
- 真机交互与弱网表现。

## 6. 修改文件

| 文件 | 操作 |
| --- | --- |
| `app/entry/src/main/ets/components/recognition/CloudQuery.ets` | 新增 |
| `app/entry/src/main/ets/components/recognition/ModelUpdate.ets` | 新增 |
| `app/entry/src/main/ets/components/recognition/ModelUpdateBanner.ets` | 新增 |
| `app/entry/src/main/ets/pages/CloudRecords.ets` | 新增 |
| `app/entry/src/main/ets/pages/RecordList.ets` | 增加“云端记录”入口与条数副标题 |
| `app/entry/src/main/ets/pages/Index.ets` | 接入模型更新检查/下载进度/完成后重新初始化 |
| `app/entry/src/main/resources/base/profile/main_pages.json` | 注册 `pages/CloudRecords` |
| `docs/assets/phase-3-agent-3/*.jpeg` | 新增 9 张验证截图 |
| `docs/phase-3-agent-3-report.md` | 新增本报告 |

未改动：`models/**`、`services/**`、`backend/**`、`components/camera/**`。

## 7. 遗留与协调项

1. `services/network/`、`services/sync/` 已交付基础能力，但尚无 `CloudRecordPort`/`ModelUpdatePort` 实现；需 Agent 0/4 按第 3.4、4 节注册端口后，云端查询与模型更新才会启用。
2. 后端缺少 `/api/statistics` 与记录详情接口；若后续不实现统计，端口可返回 `UNAVAILABLE`，页面已能独立降级。
3. 契约路径为 `/api/v1/...`，后端实现为 `/api/...`；由 Agent 0 统一契约或后端加别名，UI 不受影响。
4. 云端记录不含原图/缩略图（当前仅同步元数据与检测框），因此云端列表不展示缩略图；如需图片需后端提供下载接口。
