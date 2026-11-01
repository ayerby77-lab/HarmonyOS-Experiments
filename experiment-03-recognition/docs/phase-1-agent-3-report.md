# Agent 3｜客户端交互与识别界面 交接报告

> 身份：Agent 3（页面、检测可视化、用户操作、状态展示）。
> 范围：第一阶段识别界面，对应任务第 1–11 项与验收项。
> 时间：2026-10-22（Asia/Shanghai）。构建、逻辑测试与模拟器截图均在本机执行。
> 设备：HarmonyOS 模拟器 `VoiceCalculator_API24`（arm64，API 24）。

## 1. 结论

- 识别主页面与 7 个识别组件已实现，默认入口连接真实 `RecognitionService`，不含测试替身。
- 页面覆盖初始化、就绪、识别中、成功、空结果、错误与不可用状态；错误提示均带恢复操作。
- 检测框按 contain 规则映射到实际显示区域，横图、竖图、方图截图确认框与图像内容贴合。
- 类别修正、误检删除、恢复均基于同一 `items` 数组重算，框、清单、分类计数保持一致。
- 请求通过 `requestId + imageId + pageActive + currentImage` 四重校验，旧结果不会覆盖新图片。
- 阈值变化清空编辑并在滑块释放后自动按新阈值重跑；运行中排队重跑，失败时保留“阈值已变化”提示。
- 构建通过、纯逻辑测试 23/23 通过、模拟器可安装运行并截图。
- 真实端侧推理未验证：模型复制/校验在模拟器失败（Agent 2 的 `ModelLoader`），页面显示“识别不可用：模型文件缺失”。

## 2. 修改与新增文件

| 文件 | 操作 | 说明 |
| --- | --- | --- |
| `app/entry/src/main/ets/pages/Index.ets` | 重写 | 页面状态机、服务接入、请求防串图、阈值策略、编辑操作、UI 探针、页面布局 |
| `app/entry/src/main/ets/components/recognition/BoxGeometry.ets` | 新增 | contain 布局计算、框映射、置信度与耗时格式化 |
| `app/entry/src/main/ets/components/recognition/EditableDetection.ets` | 新增 | 可编辑检测项、墓碑删除、类别修正、分类计数 |
| `app/entry/src/main/ets/components/recognition/RecognitionPreview.ets` | 新增 | 图片预览、检测框与标签绘制、点击选中 |
| `app/entry/src/main/ets/components/recognition/PreviewPixelMap.ets` | 新增 | `ImageSource` → `PixelMap`（含 rowStride 去填充） |
| `app/entry/src/main/ets/components/recognition/StatusBanner.ets` | 新增 | 状态横幅与恢复操作按钮 |
| `app/entry/src/main/ets/components/recognition/DetectionList.ets` | 新增 | 检测清单、改类/删除/恢复、原始/修正/删除计数 |
| `app/entry/src/main/ets/components/recognition/ClassCountBar.ets` | 新增 | 按类别统计 chip |
| `app/entry/src/main/ets/components/recognition/TimingPanel.ets` | 新增 | 三阶段耗时、总耗时、模式、阈值、模型与 UI 响应指标 |
| `docs/assets/phase-1-agent-3/*.jpeg` | 新增 | 模拟器验证截图（11 张） |
| `docs/phase-1-agent-3-report.md` | 新增 | 本报告 |

未改动：共享类型 `models/`、采集服务与 `components/camera/`（Agent 1）、推理服务（Agent 2）、RDB 与存储服务（Agent 4）、构建配置。`Index.ets` 保留 Agent 0 接入的 `CameraPreview` 全屏拍照覆盖层。

## 3. 组件与导出接口

### 3.1 页面状态

`Index` 维护的公开状态（`@State`）：

- 识别：`status`、`availability`、`result`、`errorCode/errorMessage/errorDetail`。
- 图像：`hasImage`、`imageWidth/Height`、`previewPixelMap`、`previewPreparing`、`previewError`。
- 编辑：`items`、`originalCount`、`selectedId`。
- 配置：`confidenceThreshold`、`executionMode`、`thresholdStale`。
- 探针：`probeRunning`、`uiTapLastMs/MaxMs/Samples`、`uiTimerMaxMs/Samples`。
- 相机：`cameraVisible`、`cameraErrorHint`。

私有请求状态：`currentImage`、`currentRequestId`、`currentImageId`、`requestSeq`、`pageActive`、`probeTimerId`、`probeLastTickMs`、`pendingThresholdRerun`。

### 3.2 纯逻辑模块

```ts
// BoxGeometry.ets
interface ContainLayout { valid: boolean; scale: number; offsetX: number; offsetY: number; }
interface DisplayRect { left: number; top: number; width: number; height: number; }
computeContainLayout(viewW, viewH, imageW, imageH): ContainLayout
mapBoxToDisplay(box, layout, imageW, imageH): DisplayRect
formatConfidence(confidence): string
formatMs(ms): string

// EditableDetection.ets
interface EditableDetection {
  rawIndex: number; rawClassId: number; rawLabel: string;
  classId: number; label: string; confidence: number;
  left: number; top: number; right: number; bottom: number;
  deleted: boolean; editedAtMs: number;
}
interface ClassCount { classId: number; label: string; count: number; }
buildEditableDetections(boxes): EditableDetection[]
applyClassChange(items, rawIndex, classId): EditableDetection[]
setDeleted(items, rawIndex, deleted): EditableDetection[]
activeDetections(items): EditableDetection[]
countByClass(items): ClassCount[]
countDeleted(items): number
countEdited(items): number
hasAnyEdit(items): boolean
```

### 3.3 组件

| 组件 | 入参 | 回调 |
| --- | --- | --- |
| `RecognitionPreview` | `@Link pixelMap`、`imageWidth/Height`、`items`、`selectedId`、`preparing`、`previewError` | `onSelect(id)` |
| `StatusBanner` | `status`、`headline`、`description`、`detail`、三个操作开关、`actionBusy` | `onInitialize`、`onPickImage`、`onRetryRecognize` |
| `DetectionList` | `items`、`selectedId`、`originalCount`、`editedCount`、`deletedCount` | `onSelect`、`onEditClass`、`onDelete`、`onRestore` |
| `ClassCountBar` | `counts`、`total` | 无 |
| `TimingPanel` | `result`、`selectedMode`、探针 6 项 | 无 |

`PreviewPixelMap.createPreviewPixelMap(source)` 返回 `image.PixelMap`；当 `rowStride > width * bpp` 时逐行复制为紧凑缓冲区，再以 RGBA_8888 创建，方向与镜像完全沿用采集层结果。

## 4. 功能实现要点

1. **入口**：拍照（`CameraPreview` 覆盖层）、相册（`GalleryImageService.pickFromGallery`）、预览、开始识别、阈值滑块、同步/TaskPool 双按钮。
2. **状态**：`StatusBanner` 覆盖 `IDLE/INITIALIZING/READY/RUNNING/SUCCEEDED/EMPTY/ERROR/UNAVAILABLE`，并显示恢复按钮。
3. **坐标映射**：`computeContainLayout` 取 `scale = min(viewW/imageW, viewH/imageH)` 居中；`mapBoxToDisplay` 将原图像素框映射并裁剪；不重复旋转或镜像。
4. **绘制与统计**：预览叠加框与“类别 置信度”，`ClassCountBar` 显示各类别数量。
5. **编辑一致性**：框、清单、统计都读取同一 `items`；改类只改 `classId/label` 并记录 `editedAtMs`；删除置 `deleted=true`（墓碑），恢复时重建非墓碑副本。
6. **原始/编辑结果**：`rawIndex/rawClassId/rawLabel/confidence/几何` 始终保留原始模型值，编辑只作用于展示字段，符合 `docs/phase-1-data-contract.md`。
7. **耗时**：`TimingPanel` 展示预处理/推理/后处理/总耗时、冷启动、模型加载、结果阈值、执行模式、原图尺寸与模型 ID。
8. **UI 响应指标**：点击排队延迟（`ClickEvent.timestamp` 与 `systemDateTime.getUptime`）与 100 ms 主线程定时器峰值/样本数，独立于推理耗时展示。
9. **防串图**：`startRecognition` 生成 `req-${Date.now()}-${seq}`；结果写回前校验 `requestId`、`imageId`、`pageActive` 和 `currentImage.imageId`；切图与退出调用 `invalidateOutstandingRequest()` 并停止探针。
10. **阈值策略**：滑块变化（Begin/Moving）清空编辑；释放时若展示结果阈值与新阈值不一致则重跑；运行中置 `pendingThresholdRerun`，当前请求结束后按最新阈值重跑；失败时按旧结果重算 `thresholdStale`。
11. **错误恢复**：`MODEL_MISSING/MODEL_INVALID` 提示放置模型后重新加载并可能需重启；`UNSUPPORTED_ABI` 提示更换 arm64 设备；`IMAGE_INVALID` 提供重新选图；识别失败提供重试。详见 [Index.ets](file:///Users/avery/Desktop/hongmeng/SmartItemRecognitionAssistant/app/entry/src/main/ets/pages/Index.ets#L639-L666)。

## 5. 验证记录

### 5.1 构建

```sh
./scripts/build-app.sh
# BUILD SUCCESSFUL in 3 s 463 ms
# EXIT=0
```

警告（均非本次新增业务错误）：

- `Index.ets:532:41 This API is unavailable to phone.`（`ClickEvent.timestamp`，已校验有限值后使用；不可用时仅跳过点击排队样本，定时器指标仍有效）。
- `components/camera/CameraPreview.ets` 的 `getContext` 弃用与 `fill` SDK 26 警告（Agent 1 文件）。
- `services/inference/ModelLoader.ets` 的 crypto 能力提示（Agent 2 文件）。
- 依赖 HAR 与本模块 `page_show` 字符串资源重复声明。

### 5.2 纯逻辑测试

将当前 `BoxGeometry.ets`、`EditableDetection.ets`、`DetectionTypes.ets`、`ModelConstants.ets` 复制为 `.ts` 后用 DevEco 内置 TypeScript 编译执行：

```sh
node /Applications/DevEco-Studio.app/Contents/tools/ohpm/node_modules/typescript/lib/tsc.js \
  --target ES2020 --module commonjs --outDir out test.ts && node out/test.js
# RESULT passed=23 failed=0
```

覆盖：横/竖/方图 contain 布局、框映射裁剪、非法输入、置信度/耗时格式化、改类、墓碑删除、恢复、分类计数重算、修正/删除计数。

### 5.3 模拟器运行与截图

模拟器 `VoiceCalculator_API24`（arm64，API 24），通过 `hdc install` 安装未签名 HAP，`snapshot_display` 截图。

| 截图 | 场景 | 结果 |
| --- | --- | --- |
| [01-entry.jpeg](computer:///Users/avery/Desktop/hongmeng/SmartItemRecognitionAssistant/docs/assets/phase-1-agent-3/01-entry.jpeg) | 首屏、模型缺失 | 显示“识别不可用：模型文件缺失”、恢复按钮“重新加载模型”、拍照/相册、模式与阈值；布局正常 |
| [02-landscape.jpeg](computer:///Users/avery/Desktop/hongmeng/SmartItemRecognitionAssistant/docs/assets/phase-1-agent-3/02-landscape.jpeg) | 横图 + 3 个检测框 | 上下留白正确，框贴合色块，标签不越界 |
| [03-portrait.jpeg](computer:///Users/avery/Desktop/hongmeng/SmartItemRecognitionAssistant/docs/assets/phase-1-agent-3/03-portrait.jpeg) | 竖图 + 2 个检测框 | 左右留白正确，框比例与位置一致 |
| [04-square.jpeg](computer:///Users/avery/Desktop/hongmeng/SmartItemRecognitionAssistant/docs/assets/phase-1-agent-3/04-square.jpeg) | 方图 + 2 个检测框 | 无留白，框贴合显示区域 |
| [05-metrics-edit.jpeg](computer:///Users/avery/Desktop/hongmeng/SmartItemRecognitionAssistant/docs/assets/phase-1-agent-3/05-metrics-edit.jpeg) | 成功结果、耗时、探针、清单 | 三阶段/总耗时、模式、阈值、原图尺寸分区展示；UI 指标独立区块 |
| [06-class-dialog.jpeg](computer:///Users/avery/Desktop/hongmeng/SmartItemRecognitionAssistant/docs/assets/phase-1-agent-3/06-class-dialog.jpeg) | 打开类别选择器 | 80 类列表，当前类别预选中 |
| [07-class-changed.jpeg](computer:///Users/avery/Desktop/hongmeng/SmartItemRecognitionAssistant/docs/assets/phase-1-agent-3/07-class-changed.jpeg) | person 改为 bicycle | 框内标签、清单、分类 chip 同步为 bicycle，修正数为 1 |
| [08-deleted-count.jpeg](computer:///Users/avery/Desktop/hongmeng/SmartItemRecognitionAssistant/docs/assets/phase-1-agent-3/08-deleted-count.jpeg) | 删除一个误检 | 清单显示“原始 2 · 修正 0 · 删除 1”，分类计数降为 1 |
| [09-deleted-preview.jpeg](computer:///Users/avery/Desktop/hongmeng/SmartItemRecognitionAssistant/docs/assets/phase-1-agent-3/09-deleted-preview.jpeg) | 删除后预览 | 被删框不再绘制，仅保留剩余框（截图含模拟器手势残影，非页面元素） |
| [10-ui-probe.jpeg](computer:///Users/avery/Desktop/hongmeng/SmartItemRecognitionAssistant/docs/assets/phase-1-agent-3/10-ui-probe.jpeg) | 探针采样 | 点击样本 12 个（最大 18/64 ms）、定时器峰值与样本数独立显示 |
| [11-production-entry.jpeg](computer:///Users/avery/Desktop/hongmeng/SmartItemRecognitionAssistant/docs/assets/phase-1-agent-3/11-production-entry.jpeg) | 生产 HAP 首屏 | 显示“识别不可用：模型文件缺失”与“重新加载模型”，确认默认入口为真实服务 |

说明：由于 Agent 2 的 `ModelLoader` 在模拟器上复制模型报 `Invalid argument`、SHA-256 校验报 `create C obj failed`，无法获得真实推理结果。横/竖/方图与编辑/删除截图使用临时视觉脚手架注入 `ImageSource`（纯色块）与 mock `DetectionResult` 获得；该脚手架已完整移除，最终构建与 [11-production-entry.jpeg](computer:///Users/avery/Desktop/hongmeng/SmartItemRecognitionAssistant/docs/assets/phase-1-agent-3/11-production-entry.jpeg) 均来自生产代码（`grep -R "AGENT3_VISUAL_HARNESS"` 无结果）。

## 6. 场景检查结果

| 验收项 | 结果 | 证据 |
| --- | --- | --- |
| 横/竖/方图检测框对齐 | 通过（模拟注入图像） | 02、03、04 |
| 类别编辑更新框、清单、统计 | 通过 | 06、07 |
| 删除误检更新计数 | 通过 | 08、09 |
| 空结果可继续操作 | 通过（`EMPTY` 仍保留选图/重试入口） | 逻辑与状态分支检查 |
| 异步推理期间界面可响应 | 未实测（真实推理不可用）；探针与 TaskPool 通道已就绪 | 05、10 |
| 默认入口接入真实服务 | 通过 | 11 |
| 防旧结果覆盖新图 | 通过（代码校验）；未做双图并发实测 | `isCurrentOutcome` |
| 阈值变化重算 | 通过（代码路径）；未做真实结果实测 | `handleThresholdChange` |

## 7. 设备限制与未验证项

- 真实端侧推理未发生：模拟器上模型复制与 SHA-256 校验失败，归 Agent 2 处理；页面仅能验证不可用状态与恢复入口。
- 同步模式阻塞 UI 的真实表现未测量：需要模型可用后在真机对比同步/TaskPool 的点击与定时器指标。
- `ClickEvent.timestamp` 在手机上被标注不可用，点击排队样本可能为空；定时器指标仍可独立反映主线程阻塞。
- 拍照链路未验证：`GalleryImageService.capturePhoto` 仍拒绝调用，页面使用 Agent 0 接入的 `CameraPreview` 覆盖层；相机权限与真机取景待 Agent 1 验证。
- 长按/手势与系统返回键退出场景未单测；页面在 `aboutToDisappear` 已作废请求并释放 PixelMap。

## 8. 第二阶段扩展（保存与历史）

第二阶段在保持本报告页面结构不变的前提下新增：

- `pages/Index.ets`：识别成功后“保存识别结果”按钮，按 `docs/phase-2-contract.md` §4.3 先持久化图片再写 RDB，失败回滚并映射错误；新增“历史记录 · 本地保存”入口。
- `pages/RecordList.ets`：`RecordService.list` 分页、来源筛选、缩略图/时间/数量/模式/耗时展示、详情跳转。
- `pages/RecordDetail.ets`：原始/编辑后框切换、改类、删除误检、恢复、删除记录。
- `components/recognition/RecordFormat.ets`、`RecordImage.ets`、`RecordThumb.ets`：格式化、记录图加载与缩略图组件。
- `resources/base/profile/main_pages.json`：注册 `pages/RecordList`、`pages/RecordDetail`。

详细交付、验证截图、发现的两个外部阻塞（ImageAssetStore 重复保存失败、benchmark trigger 启动崩溃）见 `docs/phase-2-agent-3-report.md`。

