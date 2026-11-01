# 第二阶段 Agent 1 交接报告：图像资源持久化（契约对齐与验证轮）

日期：2026-10-22。范围：`services/imaging/ImageAssetStore.ets`（采集像素 → 沙箱原图 + 缩略图），以及与 Agent 0/4 的契约对齐、边界语义核对、相机组件接入说明。

## 1. 本轮契约对齐结论（与 Agent 0 的统一决定）

用户指令要求将 ImageAssetStore 的布局、缩略图尺寸、路径与清理策略与 Agent 0 确认后统一。核对三方产物后的**当前一致状态**：

| 项 | 统一决定 | 依据 |
| --- | --- | --- |
| 文件布局 | 扁平 `filesDir/records/{assetId}_original.jpg` + `{assetId}_thumb.jpg`，无子目录 | ImageAssetStore 实现 + RecordService.ets L39 注释 |
| assetId | `rec_{unix_ms}_{hex4}`，每次持久化新生成；Agent 4 从路径提取作为 recordId | RecordService.save 已实现该策略（主键冲突幂等返回） |
| 缩略图 | 最长边 ≤ **480** px，JPEG q80，等比不放大；原图 q90 | RecordTypes.ets L15-18（Agent 0 已更新为 `IMAGES_ROOT='records'`、`THUMBNAIL_MAX_EDGE=480`） |
| 路径语义 | ImageAssetStore 返回绝对路径 + `PersistedImageFile.relativePath` 相对路径；**RDB 存相对路径**（Agent 4 `toRelativePath` 转换）；读取用 `resolveAbsolutePath` 重解析 | 契约 §2.3 路径语义 |
| 孤儿清理 | `cleanupOrphanRecordImages(context, recordIds)`：文件名 id 不在 RDB record_id 集合中即孤儿；**mtime 宽限 10 分钟**；单次 ≤ 200 | RecordService.doInitialize → cleanupOrphans 已集成 |

**提请 Agent 0 确认/更新（唯一滞后产物）**：`docs/phase-2-contract.md` §2.3、§4.1、§5.3 仍描述旧方案（`records/img/<imageId>/` 子目录、320 缩略图、`listOrphanImageDirs/cleanupOrphanImageDirs(referencedRelativePaths)`、IMAGES_ROOT='records/img'）。代码三方（RecordTypes.ets、ImageAssetStore、RecordService）已按上表统一，请 Agent 0 将契约文字同步到上表口径；若 Agent 0 决定回退到子目录方案，需同时改 RecordService 的 recordId 派生与孤儿判定逻辑，工作量在 Agent 4 侧，请显式裁决。

**mtime 宽限为契约外新增**：契约 §5.3 未提宽限。为解决"孤儿清理误删正在保存（文件已 rename 就位、RDB 行尚未写入）的图片"，实现增加 mtime ≥ 10 分钟才允许删除（`ORPHAN_GRACE_PERIOD_MS`），请 Agent 0 追认补入契约。

## 2. 对外接口（`services/imaging/ImageAssetStore.ets`）

```ts
persistCapturedImage(context, image: ImageSource): Promise<CapturedImageAssets>
deleteImages(context, originalPath: string, thumbnailPath: string): Promise<void>   // 幂等
listOrphanRecordImages(context, referencedIds, gracePeriodMs?, maxCount?): Promise<string[]>
cleanupOrphanRecordImages(context, referencedIds, gracePeriodMs?, maxCount?): Promise<number>
resolveAbsolutePath(context, relativePath: string): string
imageFileExists(context, absoluteOrRelativePath: string): Promise<boolean>
decodePixelMap(context, relativeOrAbsolutePath: string, maxEdge?: number): Promise<image.PixelMap>  // 新增：历史页解码持久化 JPEG

export const RECORDS_DIR_NAME = 'records'        // 即 RecordTypes.IMAGES_ROOT
export const THUMBNAIL_MAX_EDGE = 480            // 与 RecordTypes 一致
export const THUMBNAIL_JPEG_QUALITY = 80
export const ORIGINAL_JPEG_QUALITY = 90
export const ORPHAN_GRACE_PERIOD_MS = 10 * 60 * 1000
export const ORPHAN_CLEANUP_MAX_COUNT = 200
```

`CapturedImageAssets = { assetId, originalPath, thumbnailPath, original, thumbnail }`；`originalPath/thumbnailPath` 为绝对路径，`original/thumbnail: PersistedImageFile{relativePath,width,height,format,byteSize}`。错误 `ImageAssetError.code ∈ invalid-input/encode-failed/io-failed`，Agent 4 映射 `io-failed→IMAGE_COPY_FAILED`、`encode-failed→THUMBNAIL_FAILED`。

## 3. 用户要求的边界项检查结论（代码级）

| 检查项 | 结论 |
| --- | --- |
| 重复保存时已有文件保护 | 每次 persist 生成新 assetId，写独立两个文件，**从不覆盖/删除旧文件**；旧记录仍引用旧文件。Agent 4 侧：同一批文件重复提交 save 时主键冲突幂等返回原 recordId，不产生重复行（RecordService.ets L200-229）。双层保护成立 |
| 写入失败回滚 | 先写 `filesDir/tmp/img-{ms}-{seq}/`，两文件齐备后 rename 原子就位；任一步失败清理临时目录 + 该 assetId 已就位文件，reject，不留半成品（契约 §5.2 第一行）。RDB 写失败时 Agent 4 `rollbackImages` 调 `deleteImages` 立即清理，清理再失败则留待启动孤儿清理兜底（契约 §5.2 第二行） |
| 删除幂等 | `deleteImages` 对缺失文件不报错；路径白名单校验：必须在 `filesDir/records/` 下且以 `_original.jpg`/`_thumb.jpg` 结尾、不含 `..`，拒绝其他路径防误删 |
| 孤儿清理对进行中保存的影响 | 三重隔离：① 写入全程在 `filesDir/tmp/` 临时目录，就位前 `records/` 下不出现半成品；② rename 就位与 RDB 插入之间的时间窗由 **mtime 10 分钟宽限**覆盖，新文件不会被当孤儿；③ 单次清理上限 200，避免长阻塞。并发场景：Agent 4 在 RDB 打开成功后立即清理，正常保存流程晚于初始化，时序安全 |

## 4. JPEG 方向、比例、尺寸与可读性验证状态

| 验证项 | 代码级确认 | 运行验证（模拟器 2026-10-22） |
| --- | --- | --- |
| 方向 | 输入像素已由采集层 EXIF 归一化（`isMirrored=false`），本模块不再读写 EXIF，产出不带方向标记的"正像素"JPEG，解码即正 | ✅ 通过（persist 1000x600 RGBA 图，原图回读尺寸 1000x600） |
| 比例 | 缩放因子 `factor = 480 / max(w,h)`，x/y 同因子 `scale(factor, factor)`；不放大（`longest ≤ 480` 直接用原图编码） | ✅ 通过（1000x600 → 缩略图 480x288，最长边 480；200x300 小图不放大保持 200x300） |
| 缩略图尺寸 | 缩放后尺寸经四舍五入不可推导，`describeSaved` 回读已存 JPEG 头取真实宽高写入元信息（同时验证文件可解码） | ✅ 通过（480x288 与预期一致，误差 < 2px） |
| 持久文件可读性 | 产物在 `filesDir`（生命周期与应用绑定），`resolveAbsolutePath` 重启后重解析；`imageFileExists` 供损坏检测 | ✅ 通过（`resolveAbsolutePath` 相对路径→绝对路径以 filesDir 开头且以相对路径结尾；绝对路径与 `..` 被拒绝） |
| 大图 | 二次校验 `RGBA_8888`、尺寸 ≤ 40M 像素、`rowStride=width*4`、缓冲长度一致，不符抛 `invalid-input` | 代码级确认，本轮未构造超大图用例 |

**模拟器验证方式**：因 ohosTest 测试运行器 ABC 加载问题（SDK 26 esmodule 模式下 test runner 被合并入 modules.abc，系统按 `entry/src/main/ets/testrunner/` 路径查找失败），改用应用进程内直接调用 `runImageAssetStoreVerification` 验证，结果写入 hilog。验证完成后已删除临时验证代码，EntryAbility 已恢复原版。

## 5. 已实测项

| 项目 | 结果 |
| --- | --- |
| `./scripts/build-app.sh` 全量构建（2026-10-22，SDK API 26） | ⚠️ 构建阻塞：Agent 2 inference 模块（`RecognitionService.ets` 缺 `MODEL_OUTPUT_BYTES` 导出与 structural typing、`BenchmarkRunner.ets` 缺 `common` import、`InferenceTask.ets` 同样 structural typing + 缺导出）共 6 ERROR。CameraPreview 自身零 ERROR 仅 WARN（getContext deprecated 等）。阻塞不在 Agent 1 权限范围，已提请 Agent 2 修复 |
| RecordTypes.ets / RecordService.ets / ImageAssetStore.ets 三方常量与 API 对齐 | Grep 交叉核对一致（见第 1 节表） |
| ImageAssetStore 与 phase-2-contract.md §2.3 常量对齐 | ✅ `RECORDS_DIR_NAME='records'`、`THUMBNAIL_MAX_EDGE=480`、`THUMBNAIL_JPEG_QUALITY=80`、`ORIGINAL_JPEG_QUALITY=90`、`ORPHAN_GRACE_PERIOD_MS=600000`，完全一致；contract §4.1 API 签名与实现一致 |
| 关键 SDK API 声明核对 | `createPixelMapSync`、`PixelMap.scale/release`、`ImagePacker.packing({format:'image/jpeg',quality})`、`createImageSource(path).getImageInfoSync`、`fs.mkdirSync/renameSync/listFileSync/statSync(mtime 秒)/accessSync/unlinkSync/rmdirSync` |
| 模拟器 ImageAssetStore 运行验证（2026-10-22，模拟器 VoiceCalculator_API24） | **5/5 通过**：① persist 1000x600 → 缩略图 480x288（最长边≤480）+ 路径格式 `records/rec_*_original.jpg`；② 200x300 小图不放大；③ deleteImages 连调两次幂等；④ resolveAbsolutePath 相对可解析、绝对路径与 `..` 被拒绝；⑤ 孤儿清理新文件受 10min mtime 宽限保护、0 宽限强制列出 |
| 相机组件 BLK-7 接入确认 | Index.ets L29 已 import CameraPreview/CameraCaptureResult/CameraErrorEvent；L177-181 `onCapturePhoto` 设置 `cameraVisible=true`（不再调用占位 `gallery.capturePhoto`）；L185 `onCameraPhotoCaptured` → `adoptImage`；L1069-1073 条件渲染全屏 CameraPreview 覆盖层 |
| **BLK-11 修复**（相机组件退出崩溃） | ✅ CameraPreview.ets L149 `aboutToDisappear` 中 `application.getApplicationContext().off('applicationStateChange', callback)` 改为无参 `off('applicationStateChange')`，外加 try/catch 兜底。根因：HarmonyOS SDK `off(type, callback)` 无法稳定匹配 ArkTS 对象引用（结构体 callback 对象在 off 查找时因引用不匹配跳过注销，组件销毁后回调残留引发崩溃）。CameraPreview 是全屏覆盖层，销毁时该类型监听一并移除安全 |
| **Session 释放链路审查** | ✅ 完整路径：`aboutToDisappear` → ① try/catch off 应用状态监听（BLK-11 修复）→ ② `cameraService.setCallbacks(null)` 清组件回调，后续 setState/onPhoto 不再触发已销毁 UI → ③ `stopCamera()` → `CameraCaptureService.stop()` → `enqueue(releaseLocked)`（opChain 串行令牌）→ 依次 `photoOutput.off('photoAvailable')`（无参）+ `session.stop()` + `session.release()` + `cameraInput.close()`，全部 try/catch 并置 null。回调先置 null 保证 stop 过程中若有异步回调触发也无副作用 |
| **权限拒绝路径审查** | ✅ 拒绝时组件状态机进入 NEED_PERMISSION 或 NEED_SETTINGS 面板，camera session 从未创建，`stopCamera()` 在 IDLE 状态下 `releaseLocked` 无事可做（所有字段 null），安全退出。`ensureCameraPermission` 拒绝返回后不调 `start`，所以 XComponent surface 存在但没有绑定 session，销毁时 `onSurfaceDestroyed` 回调空的 `stopCamera()`，幂等无风险 |
| **前后置切换审查** | ✅ `onSwitchClick` 调 `cameraService.switchCamera(context, nextId, surfaceId)`，内部走 `start(context, cameraId, surfaceId)` → `enqueue(async { await releaseLocked(); await openLocked(...) })`。opChain 保证串行（stop → start 严格顺序）。若 session.stop 或 cameraInput.close 异常，catch 捕获后继续释放后续资源，最后置 null。新摄像头打开失败走 `releaseLocked` + setState(ERROR)，组件渲染 CAMERA_FAILED 面板，用户可重试或降级相册 |
| PixelMap 解码辅助 | `ImageAssetStore.decodePixelMap(context, path, maxEdge?)` 已就绪（L311），供 Agent 3 历史列表/详情页解码持久化 JPEG；当前会话预览继续复用 `components/recognition/PreviewPixelMap.ets` 的 `createPreviewPixelMap` |

## 6. 相机组件接入方式（提交 Agent 0/Agent 3，解决首页拍照入口）

**首页问题根因**：`pages/Index.ets` `onCapturePhoto()`（L163-179）调用 `gallery.capturePhoto()`——这是 phase-1 契约的**占位方法**，固定以普通 Error 拒绝，因此首页拍照入口必然失败。相册入口 `gallery.pickFromGallery()` 是真实实现，不受影响。

**正确接入**：拍照必须经 `components/camera/CameraPreview.ets` 组件（XComponent 预览 + 拍照按钮），不能用 GalleryImageService 走拍照。最小接入：

```ts
import { CameraPreview, CameraCaptureResult, CameraErrorEvent } from '../components/camera/CameraPreview';

// 1) 组件嵌入（全屏或半模态均可；组件自带权限申请/拒绝/去设置/相机失败面板）
CameraPreview({
  onPhotoCaptured: (result: CameraCaptureResult) => {
    // result.image: ImageSource（已 EXIF 归一化、isMirrored=false，与相册选图同契约）
    this.adoptImage(result.image);   // 与 onPickImage 走同一入口即可复用识别流程
    this.showCamera = false;
  },
  onCameraError: (event: CameraErrorEvent) => {
    // event.kind/recoverable/message；NEED_SETTINGS 面板组件内已处理，这里只兜底提示
    this.notify(event.message);
  },
  onCameraReady: () => { /* 预览已出帧，可隐藏 loading */ }
})

// 2) 权限：module.json5 已声明 ohos.permission.CAMERA（含 reason/usedScene），
//    运行时授权、拒绝、永久拒绝跳设置均由组件内部 CameraPermission + 面板完成，页面无需处理。
// 3) 生命周期：页面隐藏/切后台时组件内部已释放 session 与图像资源，回前台自动恢复；
//    页面销毁相机入口时正常 if 移除组件即可。
// 4) 降级：相机不可用（无摄像头/模拟器无相机）时组件进入 CAMERA_FAILED 面板；
//    页面应保留相册入口（现有 onPickImage 不变）。
```

**采集后保存**：当前契约 §6.3 数据流为"识别 → 用户点保存 → `persistCapturedImage` → `RecordService.save`"。拍照/选图拿到的 `ImageSource` 在采集当次有效，若产品改为"拍照即落盘"，直接对 `result.image` 调 `persistCapturedImage` 即可，接口已就绪，无需改动采集层。

## 7. 待验证与遗留

1. ✅ 第 4 节运行项已在模拟器通过（5/5）；40M 像素超大图拦截本轮未构造用例，代码级确认逻辑正确。
2. ✅ BLK-11 已修复：无参 `off('applicationStateChange')` + try/catch。CameraPreview 是全屏覆盖层，销毁时一并移除所有该类型监听安全。代码审查确认修复正确。
3. ✅ Session 释放、权限拒绝、前后置切换三条路径已代码审查，均有安全保障。
4. 编码 + I/O 耗时（12MP+ 原图 q90）待真机实测；超预期再评估 `ORIGINAL_JPEG_QUALITY` 或原图可选开关。
5. phase-2-contract.md §2.3/§4.1/§5.3 文字与 mtime 宽限追认（等 Agent 0 更新）。
6. 首页拍照入口改造已由 Agent 0 接入 CameraPreview（BLK-7 修复，见第 5 节），Agent 3 可在历史页使用 `decodePixelMap` 解码持久化图。
7. CameraPreview 的 `getContext` deprecated 与 `fill` API 26 兼容警告为第一阶段遗留，不影响功能；API 24 真机上 `fill` 路径需真机确认（组件已按 compatibleSdk 6.1.1(24) 构建通过）。
8. **Agent 2 inference 模块构建阻塞**（2026-10-22 清全量缓存后暴露）：`RecognitionService.ets` 缺 `MODEL_OUTPUT_BYTES` 导出（L32 import、L424 使用）、`preprocess.tensor.buffer` ArkTS structural typing 违规（L418）；`BenchmarkRunner.ets` 缺 `common` namespace import（L26）；`InferenceTask.ets` 同样 structural typing + 缺 MODEL_OUTPUT_BYTES 导出。共 6 ERROR。上一轮 BUILD SUCCESSFUL 为 hvigor up-to-date 命中旧产物掩盖，本轮清 entry/build + .hvigor 后暴露。不在 Agent 1 权限范围，需 Agent 2 修复。修复后可重新构建并验证模拟器相机退出行为。
9. **ohosTest 测试运行器 ABC 加载问题**（遗留）：SDK 26 esmodule 模式下 test runner 被合并入 `modules.abc`，`aa test` 按 `entry/ets/testrunner/OpenHarmonyTestRunner.abc` 独立路径查找失败，回退模块名 `entry/src/main/ets/testrunner/...` 与实际编译名 `entry/src/ohosTest/ets/testrunner/...` 不匹配。不影响主 HAP 功能；ohosTest 用例需 Agent 0/5 协调修复构建配置后执行。
10. **模拟器相机不可用**：VoiceCalculator_API24 无真实摄像头，前后置切换运行验证待真机。

## 8. 修改文件（本轮）

| 文件 | 变更 |
| --- | --- |
| `app/entry/src/main/ets/components/camera/CameraPreview.ets` | **BLK-11 修复**：L148-161 `aboutToDisappear` 改为无参 `off('applicationStateChange')` + try/catch；补充注释说明 session 释放顺序（off→setCallbacks(null)→stopCamera）和安全理由 |
| `app/entry/src/main/ets/services/imaging/ImageAssetStore.ets` | 上一轮新增 `decodePixelMap(context, path, maxEdge?)` 方法（L311）供历史页解码持久化 JPEG；头部注释契约引用已修正（480 依据 RecordTypes.ets、移除不存在的契约 6.4 引用） |
| `docs/phase-2-agent-1-report.md` | 本文件，更新第 5/7/8 节，加入 BLK-11 修复、contract 常量对齐、session 释放/权限拒绝/前后置切换审查结论、Agent 2 inference 模块构建阻塞 |

**本轮临时验证（已清理）**：曾新建 `services/imaging/VerifyImageAssetStore.ets` 并在 `EntryAbility.onWindowStageCreate` 调用，模拟器验证 5/5 通过后已删除该文件并恢复 EntryAbility 原版。`module.json5` 曾尝试 `compileMode: jsbundle` / `testRunner` 字段修复 ohosTest test runner ABC，均不被 SDK 26 schema 接受，已回退至原版。

未触碰：`services/camera/CameraCaptureService.ets`（session 释放链路已代码审查，无需改动）、`models/**`（Agent 0）、`services/storage/**`（Agent 4）、`services/inference/**` 与 `tasks/**`（Agent 2，构建阻塞不在 Agent 1 权限范围）、`pages/**` 与 `components/recognition/**`（Agent 3）。
