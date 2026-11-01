# Agent 3 第二阶段交接报告：保存入口与历史记录

## 1. 范围与交付

| 交付物 | 路径 | 状态 |
| --- | --- | --- |
| 保存识别入口 | `app/entry/src/main/ets/pages/Index.ets` | 已实现，构建通过 |
| 历史列表页 | `app/entry/src/main/ets/pages/RecordList.ets` | 已实现，模拟器渲染通过 |
| 历史详情页 | `app/entry/src/main/ets/pages/RecordDetail.ets` | 已实现，模拟器渲染通过 |
| 列表/详情辅助组件 | `app/entry/src/main/ets/components/recognition/RecordFormat.ets`、`RecordImage.ets`、`RecordThumb.ets` | 已实现 |
| 编辑清单只读模式 | `app/entry/src/main/ets/components/recognition/DetectionList.ets` | 已扩展 `readOnly` |
| 页面路由 | `app/entry/src/main/resources/base/profile/main_pages.json` | 已注册 3 个页面 |
| 文档 | 本文件；`docs/phase-1-agent-3-report.md` 增补第二阶段小节；`AGENTS.md` 地图 | 已更新 |

最终构建：`BUILD SUCCESSFUL in 3 s 883 ms`（仅剩既有 ArkTS 警告，见 §5）。

## 2. 保存识别入口（Index.ets）

识别成功且 `result !== undefined` 时显示“保存识别结果”按钮，保存中禁用，成功后按钮变为“已保存”，避免重复写入；切换图片或重新识别会重置标记。

保存流程与 `docs/phase-2-contract.md` §4.3 一致：

1. `ImageAssetStore.getInstance().persistCapturedImage(context, currentImage)` 先落原图与缩略图；
2. `RecordService.getInstance().save(input, source.origin, original.relativePath, thumbnail.relativePath)`；
3. 写入的是**模型原始框** `result.boxes`，与页面编辑副本分离；同时记录 `modelId/modelSha256/imageWidth/imageHeight/coldStart/totalMs/executionMode`；
4. 成功 Toast“已保存到历史记录”；
5. `save` 失败时按契约再调用一次 `deleteImages` 清理刚写入的图片（幂等），并用 `RecordFormat.describeStorageError` 映射 `RecordErrorCode` 与 `ImageAssetError` 给出可读提示。

首页同时新增“历史记录 · 本地保存”入口，使用 `getUIContext().getRouter().pushUrl({ url: 'pages/RecordList' })`。

## 3. 历史列表页（RecordList.ets）

- `RecordService.getInstance().list(page, pageSize, sourceFilter?)` 分页加载，`PAGE_SIZE = 20`，底部“加载更多”按需追加。
- 展示缩略图、时间、来源、正式编辑后的物品数量与首类别、执行模式、总耗时与图片尺寸。
- 来源筛选：全部 / 相机 / 相册；`querySeq` 递增序号丢弃过期响应，避免筛选与翻页竞态。
- `onPageShow` 重新加载，详情页删除返回后列表自动刷新；`aboutToDisappear` 作废在途查询。
- 点击记录 `pushUrl({ url: 'pages/RecordDetail', params: { recordId } })`。
- 元素加载：`RecordThumb` 在 `aboutToAppear` 解析相对路径、`createImageSource` → 按需缩放 `createPixelMap(RGBA_8888)`，`aboutToDisappear` 释放，避免列表批量持有位图。

## 4. 历史详情页（RecordDetail.ets）

- `getDetail(recordId)` 获取 `rawBoxes` 与 `editedBoxes`；默认显示**编辑后框**，可切换“原始框”只读查看。
- 详情图由 `RecordImage.loadRecordPixelMap` 从沙箱原图加载，按最长边缩放；`RecognitionPreview` 复用 contain 映射绘制。
- 编辑：
  - 改类：`showTextPickerDialog` 选择 80 类之一 → 更新列表 → `updateEdited(recordId, toModelBoxes(items))`，成功后 Toast“修改已保存”；
  - 删除误检：置墓碑（会话内保留）→ 立即持久化；`toModelBoxes` 只输出未删除项；
  - 恢复原始结果：以加载时的 `editedBoxes` 快照重建并持久化；
  - 失败时回滚 `items` 并提示，`saving` 防止并发提交。
- 删除记录：二次确认后 `RecordService.delete(recordId)`（内部级联删除 RDB 与图片），Toast 后 `router.back()` 返回列表。
- 只读原始视图隐藏改类/删除按钮，避免误改模型输出。

## 5. 构建与警告

```sh
./scripts/build-app.sh
# BUILD SUCCESSFUL in 3 s 883 ms
```

保留的既有警告（非本次新增改动）：`CameraPreview.ets` 的 `getContext` 弃用与 `fill` API 兼容提示；`Index.ets` 中 `ClickEvent.timestamp` 在手机上不可用（第一阶段已记录）。

## 6. 模拟器验证

设备：`VoiceCalculator_API24`（arm64，API 24），未签名 HAP，`hdc install -r` + `aa start -b com.example.smartitemassistant -a EntryAbility -U 100`（`-U 100` 可规避模拟器偶发“ability not installed”）。

| 截图 | 场景 | 结果 |
| --- | --- | --- |
| [01-index.jpeg](computer:///Users/avery/Desktop/hongmeng/SmartItemRecognitionAssistant/docs/assets/phase-2-agent-3/01-index.jpeg) | 首页 | “历史记录 · 本地保存”入口、模型就绪、模式与阈值正常 |
| [02-list-empty.jpeg](computer:///Users/avery/Desktop/hongmeng/SmartItemRecognitionAssistant/docs/assets/phase-2-agent-3/02-list-empty.jpeg) | 空列表 | “暂无历史记录”、来源筛选 chip、返回按钮正常 |
| [03-list-records.jpeg](computer:///Users/avery/Desktop/hongmeng/SmartItemRecognitionAssistant/docs/assets/phase-2-agent-3/03-list-records.jpeg) | 列表有记录 | 缩略图、时间、来源、`chair 等 1 项`、模式、耗时、尺寸正确 |
| [04-filter-camera.jpeg](computer:///Users/avery/Desktop/hongmeng/SmartItemRecognitionAssistant/docs/assets/phase-2-agent-3/04-filter-camera.jpeg) | 相机筛选 | 仅剩相机来源，计数变为 1 条 |
| [05-detail.jpeg](computer:///Users/avery/Desktop/hongmeng/SmartItemRecognitionAssistant/docs/assets/phase-2-agent-3/05-detail.jpeg) | 详情默认视图 | 元信息、原图、编辑后框、分类统计、检测明细齐全 |
| [06-detail-raw.jpeg](computer:///Users/avery/Desktop/hongmeng/SmartItemRecognitionAssistant/docs/assets/phase-2-agent-3/06-detail-raw.jpeg) | 原始框视图 | 提示“只读查看模型原始结果”，改类/删除按钮隐藏 |
| [07-delete-box.jpeg](computer:///Users/avery/Desktop/hongmeng/SmartItemRecognitionAssistant/docs/assets/phase-2-agent-3/07-delete-box.jpeg) | 删除误检 | 框消失、统计 0 项、“原始 1 · 修正 0 · 删除 1”、Toast“修改已保存”、恢复入口出现 |
| [08-class-dialog.jpeg](computer:///Users/avery/Desktop/hongmeng/SmartItemRecognitionAssistant/docs/assets/phase-2-agent-3/08-class-dialog.jpeg) | 改类对话框 | 80 类列表，当前类别预选中 |
| [09-class-changed.jpeg](computer:///Users/avery/Desktop/hongmeng/SmartItemRecognitionAssistant/docs/assets/phase-2-agent-3/09-class-changed.jpeg) | chair → couch | 框变编辑色、标签/清单/统计同步，“原 chair”标记，修正数 1，Toast“修改已保存” |
| [10-delete-record-confirm.jpeg](computer:///Users/avery/Desktop/hongmeng/SmartItemRecognitionAssistant/docs/assets/phase-2-agent-3/10-delete-record-confirm.jpeg) | 删除记录确认 | 文案说明将删除原图/缩略图且不可恢复 |
| [11-list-after-delete.jpeg](computer:///Users/avery/Desktop/hongmeng/SmartItemRecognitionAssistant/docs/assets/phase-2-agent-3/11-list-after-delete.jpeg) | 删除后返回 | 自动回到列表并保留筛选，相机筛选下为空 |

最终包回归（移除临时代码后重装）：首页与列表正常，全部筛选下剩余 2 条记录。

## 7. 验证限制

- 模拟器无摄像头设备（`/dev/video*` 不存在），相册 PhotoPicker 无图片可用，因此**未能从相机/相册取得真实图片**，也未端到端点击“保存识别结果”按钮。
- 为验证列表/详情渲染，临时在 Index 增加长按注入入口，使用与应用保存流程相同的 `ImageAssetStore.persistCapturedImage` + `RecordService.save` 写入两条记录（一条相册、一条相机）；该临时代码已全部移除并重新构建安装，生产入口不再包含注入逻辑。
- 阈值重算、TaskPool 真实耗时等第一阶段项目维持原结论。

## 8. 发现的问题与处理

1. **`ImageAssetStore.persistCapturedImage` 第二次调用失败（阻塞保存）**
   - 现象：保存第一条记录成功；之后每次保存报 `io-failed / 13900015`。
   - 根因：`fs.mkdirSync(recordsDir, true)` 在目录已存在时仍抛 `EEXIST`。
   - 处理：在 `services/imaging/ImageAssetStore.ets` 增加存在性判断后再 mkdir（最小改动，含注释）。修复后同进程连续两次保存均成功（日志：`Persisted rec_...` ×2、`Saved record ...` ×2）。该文件属 Agent 1，请其复核并补充设备侧回归用例。
2. **`rawfile/benchmark_trigger.txt` 导致启动即崩溃（Agent 2）**
   - 现象：HAP 含该空文件时，每次启动触发 `BenchmarkRunner` 的 NativeBridge 测试，进程在 `onProcessDied` 中死亡，页面无法显示。
   - 处理：按该文件源码注释“跑完删除该文件”的约定移出 HAP（备份于 `/tmp/benchmark_trigger.txt.agent3`），最终包不含 trigger。请 Agent 0/2 决定该调试触发器的最终形态（建议改为构建期开关，勿随生产 HAP 分发）。
3. **启动期调试钩子仍留在生产入口**
   - `EntryAbility.onWindowStageCreate` 每次启动都会执行 `runNativeSmokeTest()`（Agent 2）与 `runImageAssetStoreVerification()`（Agent 1，`services/imaging/VerifyImageAssetStore.ets`）。
   - 它们不阻塞页面，但会增加启动耗时，且验证会反复写入/删除 `records/` 下的临时图片。请对应负责人确认后移除，或改为仅 debug 构建启用。


## 9. 待验证项

- 真机/有相机的设备上点击“保存识别结果”的 Toast、重复保存保护与失败回滚。
- 大记录量下的分页、列表滚动性能与缩略图内存。
- 详情页编辑在真实模型结果上的一致性（本例使用注入记录）。
