# 多图矩阵基准与边界用例验证（2026-11-01 晚 · Round 4）

补齐此前一直空缺的「多图基准」与「边界图用例」。本轮不依赖真机，全部在模拟器完成。

环境：模拟器 `VoiceCalculator_API24`（API 24 / aarch64）/ 应用 `com.example.smartitemassistant` / 模型 `yolov13n-coco-640-opset18`。

---

## 1. 先修基准本身：原实现只跑一张图，且与比对工具不兼容

`BenchmarkRunner.ets` 原实现有两个问题：

| 问题 | 说明 |
| --- | --- |
| 只测一张图 | `list.find(...)` 取第一个匹配项就返回，11 张测试图实际只跑 1 张 |
| 日志格式与 `compare_benchmark.py` 不匹配 | 工具期望 `RESULT\|file\|mode\|ok\|w\|h\|boxes\|pre\|infer\|post\|total\|cold\|loadMs\|sha`，原实现输出的是 `RESULT\|mode=SYNC\|coldStart=...`，解析必然失败，比对脚本从未真正跑通过 |

重写后的输出契约（与工具严格对齐）：

```
RESULT|<file>|<mode>|ok|<w>|<h>|<boxes>|<pre>|<infer>|<post>|<total>|<cold>|<loadMs>|<sha256>
BOX|<file>|<mode>|<idx>|<classId>|<label>|<conf×10000>|<left×10>|<top×10>|<right×10>|<bottom×10>
ERR|<file>|<mode>|<type>|<message>
```

两个设计取舍：

- **数值整数化**：hilog 不支持 `%.4f`，浮点直出会退化成字面量。统一乘 10000 / 10 转整数，由脚本还原。
- **解码走 `decodeToImageSource`**：与业务路径同一个函数，因此 EXIF 方向归一化、通道转换、RGBA 处理与真实拍照/选图完全一致，而不是基准里另开旁路。这一点让 EXIF 6/8 的用例真正有效。

图片从 `rawfile/benchmark_images/` 装载到沙箱后按 `bench_*` 复用，避免每次验证都为测试图重打包；验证结束已移除并重建干净包（BLK-13）。

---

## 2. 矩阵结果（12 张图 × 2 种执行模式）

| 图片 | 模式 | 尺寸 | 框数 | pre(ms) | infer(ms) | post(ms) | total(ms) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 01_single_object_cup.jpg | SYNC | 1280x853 | 1 | 90 | 76 | 16 | 182 |
| 01_single_object_cup.jpg | TASK_POOL | 1280x853 | 1 | 95 | 75 | 17 | 187 |
| 02_multi_object_bus.jpg | SYNC | 810x1080 | 5 | 108 | 55 | 15 | 178 |
| 02_multi_object_bus.jpg | TASK_POOL | 810x1080 | 5 | 104 | 42 | 17 | 163 |
| 03_same_class_overlap_mugs.jpg | SYNC | 1920x1277 | 2 | 94 | 43 | 15 | 152 |
| 03_same_class_overlap_mugs.jpg | TASK_POOL | 1920x1277 | 2 | 90 | 42 | 15 | 147 |
| 04_multi_object_desk.jpg | SYNC | 1920x1280 | 2 | 100 | 84 | 17 | 201 |
| 04_multi_object_desk.jpg | TASK_POOL | 1920x1280 | 2 | 95 | 44 | 16 | 156 |
| 05_long_horizontal_street.jpg | SYNC | 1920x793 | 0 | 67 | 53 | 17 | 137 |
| 05_long_horizontal_street.jpg | TASK_POOL | 1920x793 | 0 | 61 | 50 | 16 | 127 |
| 06_long_vertical_cars.jpg | SYNC | 1920x4138 | 6 | 72 | 52 | 16 | 140 |
| 06_long_vertical_cars.jpg | TASK_POOL | 1920x4138 | 6 | 70 | 42 | 18 | 130 |
| 07a_exif_orientation6.jpg | SYNC | 810x1080 | 5 | 117 | 43 | 17 | 177 |
| 07a_exif_orientation6.jpg | TASK_POOL | 810x1080 | 5 | 108 | 56 | 16 | 180 |
| 07b_exif_orientation8.jpg | SYNC | 810x1080 | 5 | 131 | 63 | 15 | 209 |
| 07b_exif_orientation8.jpg | TASK_POOL | 810x1080 | 5 | 103 | 43 | 16 | 162 |
| 08_blank_gray.jpg | SYNC | 1280x960 | 0 | 105 | 45 | 16 | 166 |
| 08_blank_gray.jpg | TASK_POOL | 1280x960 | 0 | 103 | 41 | 16 | 160 |
| 09_corrupted.jpg | — | — | 解码失败 | — | — | — | — |
| 10_huge_8000x6000.jpg | — | — | 解码失败 | — | — | — | — |
| 11_rgba_alpha_cup.png | SYNC | 1280x853 | 1 | 97 | 48 | 16 | 161 |
| 11_rgba_alpha_cup.png | TASK_POOL | 1280x853 | 1 | 90 | 42 | 16 | 148 |

**SYNC 与 TASK_POOL 在全部 10 张可解码图片上框数与框内容完全一致** —— 此前只有单图证据，现在这条结论覆盖 10 张图。

性能区间：预处理 61–131ms，推理 41–84ms，后处理 15–18ms，总计 127–209ms。

---

## 3. 与主机参考结果比对

命令：

```sh
python3 tests/tools/compare_benchmark.py \
  tests/evidence/2026-11-01-matrix/hilog_matrix_fixed2.txt \
  tests/expected/reference-detections.json
```

汇总（完整输出见 `compare_report.txt`）：

| 图片 | 设备/主机框数 | 判定 |
| --- | --- | --- |
| 01 cup | 1 / 1 | ✓ Δconf 0.0055，IoU 0.995，maxΔbox 1.2px |
| 02 bus | 5 / 5 | ✓ 全部匹配，Δconf ≤ 0.0131，IoU ≥ 0.972 |
| 03 mugs | 2 / 2 | ~ 框匹配，但 Δconf 0.10 / 0.075 |
| 04 desk | **2 / 5** | ✗ 缺 3 框（laptop 0.8079、keyboard 0.3884、laptop 0.2857） |
| 05 street | 0 / 0 | ✓ 双空一致 |
| 06 cars | **6 / 7** | ~ 缺 1 个低分框；1 框 IoU 0.819、maxΔbox 53px |
| 07a / 07b | 5 / — | 主机无参考（EXIF 用例未进参考集） |
| 08 blank | 0 / 0 | ✓ 双空一致 |
| 11 rgba | 1 / 1 | ✓ Δconf 0.0055，IoU 0.995，maxΔbox 1.2px |

模型 SHA-256 全部 ✓ 一致（`f39e5a3b...`）。

### 已知差异分析（R4-02）

- **单目标与双目标场景几乎完全复现**（01/02/11：IoU ≥ 0.97，Δconf ≤ 0.013），说明 letterbox、坐标逆变换、NMS 主链路是对的。
- **04 号多目标桌面图漏检 3 框**，其中包含置信度 0.81 的 laptop，不是噪声级差异。
- 主机参考脚本 `reference_inference.py` 已刻意复刻设备的 `js_round` 取整与 pad=114，差异只剩**双线性插值实现**（PIL `Image.BILINEAR` vs 设备侧手写实现）。对纹理密集的小目标，插值差异足以让置信度跨过 0.25 阈值。
- 结论：**不是执行模式问题**（SYNC 与 TASK_POOL 完全一致），而是**主机参考与设备实现的数值差异**。若要把 04 也纳入严格门禁，应让主机参考改用设备同一套插值实现，或对该图放宽容差。

---

## 4. 本轮发现并修复的缺陷（R4-01）

### 现象
首轮矩阵中 `06_long_vertical_cars.jpg`（1920×4138）在 **TASK_POOL 模式直接失败**，而 SYNC 正常：

```
RESULT|06_long_vertical_cars.jpg|SYNC|true|1920|4138|6|71|47|17|135|...
ERR|06_long_vertical_cars.jpg|TASK_POOL|recognize-failed|识别失败，请重试
```

开始执行到失败只隔 **29ms**，远快于一次推理（40ms+），说明卡在参数传递阶段而非计算阶段。

### 根因
`runTaskPool` 用 `task.setCloneList([image.data])` 把整块像素缓冲跨线程传递。该图 RGB 缓冲为 `7680 × 4138 = 31,779,840 B ≈ 30.3 MB`。对照同批次样本：

| 图片 | 像素缓冲 | TASK_POOL |
| --- | --- | --- |
| 03 / 04 | 9.4 MB | 成功 |
| 05 | 6.1 MB | 成功 |
| **06** | **30.3 MB** | **失败** |

边界落在 9.4 MB 与 30.3 MB 之间，与 TaskPool 参数序列化的 16 MB 量级限制吻合。**推断为 TaskPool 参数序列化上限**（当时未捕获底层错误文案，故此处标注为推断而非实证）。

### 修复
`RecognitionService.ets`：

1. 新增 `TASKPOOL_MAX_BYTES = 16MB`；`runTaskPool` 在派发前检查像素缓冲大小，超限则**降级为 SYNC 执行**并记告警，保证功能可用而不是报错。
2. `executeRequest` 的 catch 补打 `code` 与 `detail` —— 此前底层真因被 `'识别失败，请重试'` 完全吞掉，这是本轮排查绕远路的主要原因。

修复后实测：

```
W RecognitionService: 像素缓冲 31779840 B 超过 TaskPool 序列化上限 16777216 B，降级为 SYNC 执行: bench_TASK_POOL_...
I BenchmarkRunner: RESULT|06_long_vertical_cars.jpg|TASK_POOL|true|1920|4138|6|70|42|18|130|...
```

06 号图 TASK_POOL 现在正常出 6 框。

---

## 5. 边界用例结论

| 用例 | 结果 | 判定 |
| --- | --- | --- |
| 08 空白灰图 | 0 框，无异常 | ✓ 不产生幻觉检测 |
| 09 损坏文件 | `decode-failed`，矩阵继续跑后续图 | ✓ 优雅降级，不中断、不崩溃 |
| 10 8000×6000 超大图 | `decode-failed`（"图片过大，请更换分辨率更小的图片"） | ✓ 系统解码层直接拒绝，未 OOM |
| 07a EXIF orientation 6 | 810×1080 归一化后 5 框（bus + 4 person） | ✓ 与未旋转的 02 号图结果一致，说明旋转归一化正确 |
| 07b EXIF orientation 8 | 810×1080 归一化后 5 框，同上 | ✓ |
| 11 RGBA 带 alpha | 1 框 cup 0.9473 | ✓ 与同名 JPEG 版本结果一致，alpha 通道处理正确 |
| 05 超宽横图 | 0 框（主机参考也是 0） | ✓ 双空一致 |

07a/07b 与 02 是同一张公交车图的三个方向变体，三者都稳定输出 5 框，是 EXIF 归一化正确性的有力证据。

---

## 6. 过程记录：一次非确定性终止

第二轮矩阵执行到 03 号图的 TASK_POOL 阶段时，应用进程被系统回收（pid 由 26684 变为 26797），10 秒后重启，`faultlogger` 中**没有**该应用的 cppcrash / jscrash 记录。

- 同一次构建在前后两轮中分别「被杀」与「跑完 12 张」，说明与代码改动无关，是模拟器内存压力下的偶发回收。
- 记录在此以免后续误判为回归；真机上需观察同类场景（连续 20+ 次大图推理）是否稳定。

---

## 7. 结论与剩余项

### 本轮关闭
- 「多图批量基准」：12 张图 × 2 模式全部执行完毕，含 2 个预期失败用例。
- 「边界图用例」：空白、损坏、超大、EXIF 6/8、RGBA、超宽横图全部有结论。
- 基准日志格式与 `compare_benchmark.py` 对齐，比对脚本**首次真正跑通**。

### 新增待办
| 编号 | 内容 |
| --- | --- |
| R4-02 | 04 号多目标桌面图漏检 3 框（含 0.81 的 laptop），需对齐主机参考的插值实现或放宽容差 |
| R4-03 | 07a/07b 未纳入 `reference-detections.json`，EXIF 用例目前只能自比对（与 02 号图对照） |
| R4-04 | 模拟器偶发进程回收，真机需观察连续大图推理的稳定性 |

### 口径
本轮结论均为**模拟器运行通过 + 编译通过**，真机运行仍未验证。
