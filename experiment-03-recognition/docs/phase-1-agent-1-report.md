# 第一阶段 Agent 1 交接报告：图像采集

日期：2026-10-22。范围：相册选图、Camera Kit 预览拍照、前后摄像头切换、权限、生命周期、EXIF 方向归一化。
依据 [`docs/phase-1-contract.md`](phase-1-contract.md) 第 2、4.1、5.3 节实现；共享类型未做任何修改。

## 1. 修改文件

| 文件 | 变更 |
| --- | --- |
| `app/entry/src/main/ets/services/camera/ImageDecoder.ets` | 新增。共享解码管线：尺寸防护、EXIF 读取与归一化、RGBA_8888 解码、紧凑像素导出、原生对象释放 |
| `app/entry/src/main/ets/services/camera/GalleryImageService.ets` | 新增。契约 4.1 相册服务单例，实现 `ImageCaptureApi` |
| `app/entry/src/main/ets/services/camera/CameraPermission.ets` | 新增。相机权限查询/请求/系统设置跳转 |
| `app/entry/src/main/ets/services/camera/CameraCaptureService.ets` | 新增。Camera Kit 封装：枚举、会话、预览、拍照、切换、释放 |
| `app/entry/src/main/ets/components/camera/CameraPreview.ets` | 新增。XComponent 预览组件，内嵌快门/切换按钮与权限错误面板 |
| `app/entry/src/main/module.json5` | 新增 `ohos.permission.CAMERA` 声明（reason + usedScene=inuse/EntryAbility） |
| `app/entry/src/main/resources/base/element/string.json` | 新增 `camera_permission_reason` 文案 |
| `AGENTS.md` | 代码地图状态更新（camera 服务、camera 组件、权限状态） |

未触碰：`models/**`、`pages/Index.ets`、`services/inference/**`、`tasks/**`、`EntryAbility.ets`。

## 2. 对外接口

### 2.1 相册（契约 4.1，Agent 3 已按契约引用）

```ts
class GalleryImageService implements ImageCaptureApi {
  static getInstance(): GalleryImageService;
  pickFromGallery(): Promise<ImageSource>;  // 取消 -> RecognitionFailure(CANCELLED, '已取消选图', true)
  capturePhoto(): Promise<ImageSource>;     // 固定以普通 Error 拒绝：相机拍照走 CameraPreview
}
```

- 取消：resolve 空 `photoUris` → `CANCELLED`，页面已有图片/结果不受影响（契约 4.1）。
- 打开相册失败、读取失败、解码失败、超大图（宽×高 > 40,000,000 像素）、损坏图：`IMAGE_INVALID`，`recoverable=true`。
- URI 有效期：`PhotoViewPicker.select()` 返回 URI 带读授权，服务在 select 返回的同一调用栈内立即 `fs.openSync` 打开并解码，不持久化 URI；后续阶段如需长期保存，应复制像素而非保留 URI。
- 返回前已释放 `PixelMap`、解码用 `image.ImageSource`、文件 fd（契约 5.3）。

### 2.2 相机预览组件（`components/camera/CameraPreview.ets`）

```ts
interface CameraCaptureResult { image: ImageSource }
interface CameraErrorEvent { kind: string; message: string; recoverable: boolean }
interface CameraReadyEvent { cameras: CameraDeviceInfo[]; activeCameraId: string }

CameraPreview({
  onPhotoCaptured?: (result: CameraCaptureResult) => void,
  onCameraError?: (error: CameraErrorEvent) => void,
  onCameraReady?: (event: CameraReadyEvent) => void
})
```

Agent 3 对接方式：放置组件并处理三个回调。`onCameraError.kind` 取值：`permission`（权限拒绝/禁用，页面应保留相册入口）、`no-camera`（无摄像头）、`open-failed`、`capture-failed`、`decode-failed`。后两者为拍照级错误，组件内提示且预览不中断；前几种组件显示可操作面板（重新授权 / 前往系统设置 / 重试），页面需保证相册入口仍可用。

组件自带：快门按钮（READY 才可点）、“切换镜头”按钮（摄像头数 > 1 才显示）、启动/拍照遮罩、错误提示条。

### 2.3 相机服务（`CameraCaptureService`，单例）

- `enumerateCameras(context)`：过滤支持 `NORMAL_PHOTO` 的设备，输出 `{cameraId, position: back/front/other, displayName}`；只暴露一个摄像头时切换按钮自动隐藏。
- `start(context, cameraId, surfaceId)` / `switchCamera(...)` / `stop()`：内部串行队列执行，重复进入退出与快速切换不会产生并发会话。
- `capture()`：非 READY 以普通 Error 拒绝；`PhotoCaptureSetting` 显式 `mirror:false`、`QUALITY_LEVEL_HIGH`，`rotation` 由 `PhotoSession.getPhotoRotation()`（API 23+ 无参，系统取设备方向）计算，失败回退 `ROTATION_0`。
- 拍照经 `photoAvailable` 回调取 `photo.main`（`image.Image`）→ JPEG 字节 → `ImageDecoder` 管线 → 契约 `ImageSource`，随后释放 `image.Image` 与 `photo`。
- profile 选择：预览就近 1280×720、拍照就近 1920×1080（按面积，JPEG 格式优先），兼顾解码内存与 640 letterbox 输入。

## 3. 契约关键语义落实

- **像素格式**：全部输出 `RGBA_8888`，`rowStride = width*4`，`data` 紧凑长度 `rowStride*height`（契约允许 RGB/RGBA，统一 RGBA 简化实现）。
- **方向归一化层级**：由采集层（本模块 `ImageDecoder`）完成，Agent 2/3 不得再旋转。EXIF 映射：1 不变 / 2 水平翻转 / 3 转180 / 4 垂直翻转 / 5 水平翻转+顺时针270 / 6 顺时针90 / 7 垂直翻转+顺时针90 / 8 顺时针270，依据 image 模块 ORIENTATION 属性文档的变换描述。
- **镜像**：静态拍照 `isMirrored=false`（capture 显式 `mirror:false`）；前置镜像仅存在于系统预览层，不进像素。
- **不静默缩放**：解码不设 `desiredSize`；超大图以 `IMAGE_INVALID` 拒绝并提示换图（阈值 40M 像素，常规 12MP 照片可过）。
- **错误一致性**：取消 `CANCELLED`、图像类 `IMAGE_INVALID` 均为 `recoverable=true`；权限拒绝不经 `ImageSource` 表达，由组件/页面处理。

## 4. 验证结果

| 项目 | 结果 |
| --- | --- |
| `./scripts/build-app.sh` 全量构建（2026-10-22，本机） | 通过，`entry-default-unsigned.hap` 生成；camera 相关文件零告警 |
| 相册选图/取消/失败路径 | 代码路径完整，待模拟器/真机运行验证 |
| 相机预览/拍照/切换/生命周期 | 待模拟器/真机运行验证 |

## 5. 环境

- DevEco SDK API 26.0.0.105（`/Applications/DevEco-Studio.app/Contents/sdk`），工程 modelVersion/targetSdk 26.0.0、compatibleSdk 6.1.1(24)。
- 关键 API 均按 SDK 声明核对：`camera.getCameraManager`、`createSession<PhotoSession>(NORMAL_PHOTO)`、`createPhotoOutput(profile)`、`on('photoAvailable')`（`Photo.main: image.Image`）、`PhotoSession.getPhotoRotation()`、`PhotoViewPicker.select`、`image.createImageSource(fd/ArrayBuffer)`、`PixelMap.rotate/flip/readPixelsToBuffer`、`applicationStateChange`。

## 6. 待验证与已知限制

1. 全部相机路径待模拟器/真机运行验证：授权、预览、拍照解码方向、前后切换、重复进出、切后台恢复（应用内已按 `applicationStateChange` 释放并恢复）。
2. EXIF 5/7（翻转+旋转组合）按平台文档实现，实际样张罕见，待真机带方向照片验证。
3. `getPhotoRotation()` 无参形式（API 23+）依赖系统取设备方向；若目标设备行为异常，回退方案是传 window 角度，需 Agent 4 真机确认。
4. x86_64 模拟器若暴露虚拟摄像头，流程可用但未验证；无摄像头设备自动显示“未检测到可用摄像头”并保留相册入口。
5. `PhotoViewPicker` URI 授权语义在 SDK 声明中注明“永久授权但建议 getAssets”；当前按官方通用样例以 `fs.openSync` 直读，已实测构建通过，运行读取待设备确认。若个别设备拒绝直读，替代方案是 `photoAccessHelper.getAssets` 取 fd，改动仅限 `GalleryImageService`。
6. 拍照分辨率就近 1920×1080 选择；如后续识别精度需要更高分辨率，调整 `CameraCaptureService` 顶部常量即可。
7. `CameraCaptureService` 为单例单会话，与第一阶段单预览页面匹配；多预览并发不在本阶段范围。

---

# 2026-11-01 修复与验证补充（Q-18/BLK-10/BLK-11 轮次）

范围：`components/camera/`、`services/camera/`；未改 `Index.ets`（集成问题见第 4 节交接项）；未运行完整 Hvigor 构建，验证使用既有产物 `entry-default-unsigned.hap`（15:59，已含本轮两处修复）。

## 1. 修改文件

| 文件 | 变更 |
| --- | --- |
| `components/camera/CameraPreview.ets` | 修复 BLK-11/Q-18：新增 `appStateCallback` 回调引用与 `appStateRegistered`/`disposed` 字段；`aboutToAppear` try/catch 注册；`aboutToDisappear` 先置 `disposed` 再经 `unregisterAppStateChange()` 注销——优先带参 off，失败回退无参，双失败置模块级一次性标记（`appStateOffWithCallbackRejected`/`appStateOffUnsupported`）后续静默跳过，残留监听因 `disposed` 惰性返回 |
| `services/camera/GalleryImageService.ets` | 修复 BLK-10 挂起：新增 `selectWithTimeout()`（60s，`settled` 防重入），超时以 `RecognitionFailure(IMAGE_INVALID, '系统相册不可用或未响应，请重试或改用拍照')` 拒绝；catch 透传 `RecognitionFailure` 不再二次包装 |

## 2. SDK 签名核对结论

- SDK 26 d.ts（`api/application/ApplicationContext.d.ts`）：`off(type: 'applicationStateChange', callback?: ApplicationStateChangeCallback): void`（@since 10），带参与无参两种形态均合法。
- API 24 x86_64 模拟器运行时实测：**两种形态均抛 BusinessError 401**（带参报 "must be function"，无参报 401），属系统镜像缺陷而非用法错误。修复策略按官方主形态（带参注销）优先，异常运行时降级一次后静默。

## 3. 验证结果（模拟器 / 真机分列）

验证环境：DevEco 模拟器 `VoiceCalculator_API24`（API 24，x86_64，暴露虚拟摄像头 lcam001/lcam002），hdc 127.0.0.1:5555。**真机：无设备，全部真机项待验证。**

### 3.1 任务一：off('applicationStateChange') 401（BLK-11/Q-18）— 模拟器通过

同一进程（pid 31869）最终 HAP 实测：

- 拍照完成退出 1 次 + 反复进出 5 次：仅进程**首次**退出出现 1 条 `off with callback rejected, fallback to no-arg: {"code":401}`（info）+ 1 条 `off applicationStateChange unsupported...`（warn），后续 5 次进出**零异常日志**（模块级标记生效）。
- 全程 8 次 `preview started`（初进 + 切换×2 + 5 次重进）均正常，会话释放/重开无残留。
- `faultlog` 无新增（最新仍为 2026-10-22 旧记录），无崩溃。
- 真机（SDK 26）预期带参注销一次成功不进入回退分支；待真机复核。

### 3.2 任务二：权限 DENIED / DENIED_WITHOUT_DIALOG — 模拟器通过（含面板不可达交接项）

- 重装重置后首次拒绝：`Camera permission denied, dialogShown=true`（DENIED）✓；再次拒绝：`dialogShown=false`（DENIED_WITHOUT_DIALOG）✓。
- 设置跳转 want 验证：`aa start -b com.huawei.hmos.settings -a com.huawei.hmos.settings.MainAbility -U application_info_entry --ps pushParams com.example.smartitemassistant` 成功拉起本应用信息页 ✓（`openCameraSettings` 参数有效）。
- 经设置 UI 手动授权后全链路：拍照入口 → `Enumerated 2 photo cameras` → `Open camera lcam001` → `preview started` ✓（授权路径通畅，覆盖层进入预览而非卡在权限面板）。
- **交接 Agent 3（面板不可达）**：`Index.onCameraError` 对 `kind='permission'` 立即 `cameraVisible=false` 关闭覆盖层，导致组件内 NEED_PERMISSION/NEED_SETTINGS 面板（含"重新授权"/"前往系统设置"按钮）永远不可达，"可跳转设置页"在页面层落空。建议：`kind='permission'|'no-camera'|'open-failed'|'session-failed'` 时保留覆盖层由组件面板接管（仅 Toast 不关闭无法满足任务书"可跳转设置页"）。

### 3.3 任务三：相册取消与无图库环境 — 错误路径模拟器通过，CANCELLED 代码审查确认

- BLK-10 复现：点击"相册选图"→ 系统 picker shield 动画（`pickerBundleName:com.huawei.hmos.photos`）→ sheet 白屏停加载，`select()` 永不 resolve/reject。
- **超时修复运行验证**：60s 后页面错误区入树：`系统相册不可用或未响应，请重试或改用拍照` + detail `picker select timeout after 60000ms` + `重新选图` 按钮 ✓ 明确提示而非崩溃/永久挂起；无 faultlog。
- CANCELLED 路径（代码审查，模拟器无法触发）：`select()` 正常返回空 `photoUris` → `RecognitionFailure(CANCELLED,'已取消选图')`（[GalleryImageService.ets:57-60]）；`Index.handleImageFailure` 对 CANCELLED 仅 `notify('已取消，保留当前图片与结果')`，不动已有图片/结果 ✓ 符合契约 4.1。
- 备注：验证后段系统回收本应用进程（pid 31869→12148）并重新拉起，faultlog 无记录，判定为模拟器环境噪音，非本次改动引入。

### 3.4 任务四：EXIF 方向（07a/07b）— 宿主机参考通过，设备侧受 BLK-10 阻塞

- Pillow 参考（`tests/assets/images/`）：
  - `07a_exif_orientation6.jpg`：raw **1080x810**，EXIF orientation=6（Right-top）→ 归一化 **810x1080**
  - `07b_exif_orientation8.jpg`：raw **1080x810**，EXIF orientation=8（Left-bottom）→ 归一化 **810x1080**
- `ImageDecoder` 映射审查一致：6→`rotate(90)`、8→`rotate(270)`，两者宽高交换，归一化后均应为 810x1080；`parseExifOrientation` 对平台 ORIENTATION 字符串 'Right-top'/'Left-bottom' 的映射正确。
- 设备侧相册链路 EXIF 验证受 BLK-10 阻塞（picker 不返回任何图片）；相机实拍路径同管线已验证：`Decoded camera image camera-...: 720x1280, exif=0`（虚拟摄像头 JPEG 无 EXIF，走 exif=0 不旋转分支）✓。
- 真机复现步骤：真机安装 HAP → 相册导入 07a/07b → 分别选图 → 页面尺寸标签应显示 810×1080 且图像方向正直（07a 顺时针 90、07b 顺时针 270）。

### 3.5 任务五：四段证据（模拟器）

| 段落 | 结果 | 关键日志/证据 |
| --- | --- | --- |
| 拍照 | ✓ | 快门 → `Decoded camera image camera-1793520567907-1: 720x1280, exif=0` → 主页采用并显示预览（截图预览区为摄像头测试图非占位） |
| 预览 | ✓ | `Open camera lcam001, preview 1280x720` → `preview started`；截图预览区像素 (177,177,170) 为实时测试图 |
| 前后切换 | ✓ | 点"切换镜头"：`Open camera lcam002 ... preview started`；再点切回 lcam001；双向各一次成功 |
| 相册选图 | ✓（错误路径） | BLK-10 白屏复现 + 60s 超时明确提示（见 3.3）；正常选图/CANCELLED 待真机 |

真机四段复现步骤：配置签名安装 HAP → 首页点"拍照"授权 → 预览就绪点快门 → 点"切换镜头" → 返回主页点"相册选图"选 07a/07b → 核对解码尺寸 810x1080 与方向。

## 4. 交接 Agent 3 的 Index.ets 改动建议（本 Agent 未改 Index.ets）

1. `onCameraError`：`kind='permission'|'no-camera'|'open-failed'|'session-failed'` 时不要 `cameraVisible=false`，保留覆盖层让组件面板（重新授权/前往系统设置/重试）可达；Toast 可保留。
2. 覆盖层"返回"按钮（`Index.ets` position `{x:'5%', y:16}`）与组件"切换镜头"按钮（同位）完全重叠，返回在上层导致双摄设备切换不可达。建议"返回"挪至右上角（`x:'80%'`）或由组件统一定位。

## 5. 剩余阻塞

1. 真机（arm64，SDK 26）全部路径待验证：权限两分支面板跳转、预览/拍照/切换、07a/07b EXIF 实测、相册正常选图与 CANCELLED。
2. BLK-10（模拟器相册能力缺失）未解： picker 永不返回，60s 超时为缓解措施；CANCELLED 与正常选图链路只能真机验证。
3. 上一节遗留项 2（EXIF 5/7）、3（getPhotoRotation 设备方向）仍待真机。
