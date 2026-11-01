# 相机链路修复与 UI 全链路验证（2026-11-01 晚）

本轮目标：解决相机覆盖层缺陷（R3-04），并在模拟器上补齐此前缺失的 **UI 层检测框截图** 与 **保存→历史→详情→重启持久化** 证据。

环境：DevEco Studio 26.0.0.105 / SDK 26.0.0 / 模拟器 `VoiceCalculator_API24`（API 24, aarch64）/ 应用 `com.example.smartitemassistant`。

---

## 1. 根因定位：拍照永久卡在 CAPTURING

### 现象
点快门后界面永久转圈，等待 30s+ 无恢复，返回键仍可用（说明 UI 线程未卡死）。

### 逐层排除
| 假设 | 验证方式 | 结论 |
| --- | --- | --- |
| UI 线程被阻塞 | 点击「返回」可正常关闭覆盖层 | 排除 |
| 快门按钮未绑定事件 | 加日志后捕获到 `shutter clicked` | 排除 |
| `capture()` 抛错未捕获 | 日志显示 `capture resolved, settled=false`，7ms 内 resolve | **排除，且暴露真因** |
| 照片回调丢失 | 无任何 `photoAvailable` 相关日志 | **命中** |

### 真因
`PhotoOutput.capture()` 在模拟器上 **几毫秒内就 resolve**，但 `photoAvailable` 回调永不触发：

```
21:13:00.875 CameraPreview: shutter clicked, serviceState=ready
21:13:00.878 HStreamCapture::Capture Starting photo capture with capture ID: 9
21:13:00.890 Capture() ExifNode::Capture streamId = 2 and captureId = 9
（此后无 photoAvailable，也无错误回调）
```

原实现把「`capture()` resolve」当成「拍照完成」，于是：
- 组件侧超时定时器被提前 `clearTimeout`，兜底失效；
- 状态机停在 `CAPTURING`，转圈与快门禁用永久锁死。

### 修复
把完成条件从「capture() resolve」改为「**照片真正送达**」，并在服务层加送达超时。

`app/entry/src/main/ets/services/camera/CameraCaptureService.ets`
- 新增 `PHOTO_DELIVERY_TIMEOUT_MS = 6000`、`PhotoDeliveryWaiter`。
- `capture()` 改为 `await output.capture(setting)` 后再 `await delivered`，只有 `photoAvailable` 走完 `handlePhoto` 才 resolve。
- 新增 `beginPhotoDelivery()` / `settlePhotoDelivery()` / `cancelPhotoDelivery()`。
- `handlePhoto` 成功路径在回调页面之前 `settlePhotoDelivery()`；失败路径 `settlePhotoDelivery(err)`。
- `releaseLocked()` 先 `cancelPhotoDelivery()`，避免释放相机时 Promise 永久挂起。

`app/entry/src/main/ets/components/camera/CameraPreview.ets`
- 保留 8s 二次兜底（防御服务层异常），但只在真正拿到照片后才 `clearTimeout`。
- 超时/失败时**先**把 `serviceState` 复位为 `READY`，**再**回调父级，避免父级回调抛错导致状态锁死。

### 修复后实测
```
21:13:00.875 CameraPreview: shutter clicked, serviceState=ready
21:13:00.878 HStreamCapture::Capture Starting photo capture with capture ID: 9
21:13:06.875 CameraCaptureService: photo delivery timeout after 6000 ms
21:13:06.875 CameraPreview: capture rejected: 拍照超时：相机没有返回图像，请重试
```
截图 `camera_timeout_recovered.png`：转圈消失、快门恢复白色可用、顶部提示「拍照超时：相机没有返回图像，请重试」。

---

## 2. R3-04 布局重叠（真实缺陷，已修）

`uiLayout` 显示「返回」与「切换镜头」**坐标完全重合**：

```
- Button 切换镜头 [id:43] [top: 192, left: 63, width: 309, height: 140]
- Button 返回     [id:46] [top: 192, left: 63, width: 252, height: 154]
```

两者都用了 `position({ x: '5%', y: 16 })`，分属 `Index.ets` 与 `CameraPreview.ets`，叠在一起渲染成「返回镜头」。

修复：
- `CameraPreview` 的「切换镜头」改为 `Row` + `justifyContent(FlexAlign.End)` 靠右上角。
- 修复后：`切换镜头 left:891`、`返回 left:63`，不再重叠（见 `camera_timeout_recovered.png` 顶部）。

同时修掉 **同一条错误提示被渲染两遍**：组件内的提示条删除，统一由页面 `cameraErrorHint` 渲染，并把 `position({x:'50%'})` 改为左对齐 + `width('90%')`，避免长文案右侧被裁。`onCameraPhotoCaptured` 成功时清空 `cameraErrorHint`，防止重试成功后残留旧提示。

---

## 3. 补齐 UI 检测框证据（此前遗留）

模拟器相机不可用，改用首页新增的 **「示例图片（内置样例，模拟器可用）」** 入口：

- 样例：`samples/04_multi_object_desk.jpg`，1920×1280
- 模式：TaskPool
- 结果：**2 项**
  - `scissors` 80.2% · 框 1564,695,1905,1051
  - `potted plant` 33.9% · 框 0,3,541,309
- 总耗时 **176 ms**

证据：`tests/evidence/2026-11-01-round4/ui_detection_boxes.png`（图上两个彩色检测框 + 类别标签）、`ui_result_list.png`（结果明细与「原始 2 · 修正 0 · 删除 0」）。

---

## 4. 保存 → 历史 → 详情 → 重启持久化（此前遗留，已通过）

| 步骤 | 证据 |
| --- | --- |
| 保存 | `ImageAssetStore: Persisted rec_1793539297363_d401: thumb 17193B, original 211420B`<br>`RecordService: Saved record rec_1793539297363_d401, boxes=2` |
| 历史列表 | `本地记录 · 2 条 · 按时间倒序`；最新一条 `2026-11-01 21:21 / 相册 / scissors 等 2 项 / TaskPool / 176 ms / 1920×1280` |
| 详情页 | `识别详情` + `模型 yolov13n-coco-640-opset18 · 冷启动否 · 1920×1280` + `编辑后框/原始框` 切换 + `共 2 项 · 2 类` |
| 重启后 | `aa force-stop` + 重启，历史仍为 **2 条**（21:21、21:15），内容一致 |

证据：`history_after_restart.png`。

---

## 5. 新发现的构建环境要求（重要）

命令行构建必须显式提供两项环境变量，否则报错：

| 缺失项 | 报错 | 修复 |
| --- | --- | --- |
| `DEVECO_SDK_HOME` | `00303217 Configuration Error: Invalid value of 'DEVECO_SDK_HOME'` | `export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk` |
| `JAVA_HOME` | `00308018 Unknown Error / Unable to locate a Java Runtime`（`PackageHap` 阶段） | `export JAVA_HOME=/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home` |

可用构建命令：

```sh
cd app
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
export JAVA_HOME=/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home
export PATH="$JAVA_HOME/bin:/Applications/DevEco-Studio.app/Contents/tools/node/bin:$PATH"
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw assembleHap \
  --mode module -p product=default -p buildMode=debug --no-daemon
```

仍需在**关闭沙箱**的终端执行，否则 `restool` 删除中间文件被拦截（R3-06 未根治）。

## 6. 模拟器交互避坑（本轮踩坑记录）

| 坑 | 现象 | 正解 |
| --- | --- | --- |
| `Emulator -click <id>` | 每次 `-uiLayout` 后 id 会重排，用旧 id 点击静默无效 | 同一次命令内先 dump 再点击，或改用 uinput |
| `Emulator -click "x y"` | 坐标系与布局不一致，可能误触其他控件 | 不用它，改 `hdc shell uinput -T -c <x> <y>` |
| 控件在视口外 | 点击无任何反应（页面可滚动，`top` 可 > 视口高度） | 先 `uinput -T -m 640 2200 640 900 300` 上滑，再 dump + 点击 |
| `Emulator -screenshot -screenshotPath` | 提示路径不存在，落到 `~/Pictures` | 用绝对路径，或事后从 `~/Pictures` 拷回 |
| `hilog` 打枚举 | `%{public}d` 输出为空 / `Number()` 得 `NaN` | `CameraServiceState` 是**字符串枚举**，用 `%{public}s` + `String(...)` |
| zsh 变量分词 | `set -- $COORDS` 不拆词，算术报 `bad math expression` | 用 `read -r T L W H <<< "$COORDS"` |

---

## 7. 结论与剩余项

### 本轮已关闭
- R3-04 相机覆盖层：按钮重叠 + 拍照永久卡死 + 提示重复，均已修复并有截图证据。
- 遗留项「UI 层检测框渲染截图」：已取证。
- 遗留项「保存→历史→详情→重启持久化」：已通过。

### 仍未解决
| 项 | 说明 |
| --- | --- |
| 模拟器相机拍照 | 相机 HAL `DistributeBuffers timeout, respondBufferList size=0`，预览黑屏、照片永不回调。属**模拟器虚拟相机限制**，非应用缺陷；应用已能优雅超时。真机需复核。 |
| R3-06 构建沙箱 | `restool` 删除中间文件仍需关闭沙箱；CI 需配置。 |
| 多图批量基准 | 仍只跑了样例图，IMG-02/03/05/06/08/11 待补。 |
| 真机验收 | 全部结论基于模拟器；签名仍未配置（`signingConfigs` 为空）。 |
| 云端端口 | 本轮日志显示 `CloudRecordPort available=true, ModelUpdatePort available=true`（此前 false），但真实网络链路未验证。 |

> 完成声明口径：本轮结论均为**模拟器运行通过 + 编译通过**，**真机运行未验证**。
