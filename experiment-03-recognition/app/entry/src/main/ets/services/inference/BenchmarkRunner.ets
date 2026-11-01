/**
 * Native real inference benchmark — 多图矩阵验证。
 *
 * 输出契约（与 tests/tools/compare_benchmark.py 的解析器严格对齐）：
 *   RESULT|<file>|<mode>|ok|<w>|<h>|<boxes>|<pre>|<infer>|<post>|<total>|<cold>|<loadMs>|<sha256>
 *   BOX|<file>|<mode>|<idx>|<classId>|<label>|<conf×10000>|<left×10>|<top×10>|<right×10>|<bottom×10>
 *   ERR|<file>|<mode>|<type>|<message>
 *
 * 为什么用整数编码：hilog 不支持 `%.4f` 这类精度修饰符，浮点直出会变成字面量或丢失精度。
 * 统一乘 10000 / 10 转整数，由比对脚本还原，避免日志层的格式陷阱。
 *
 * 图像解码走 decodeToImageSource（与业务路径同一个函数），因此 EXIF 方向归一化、
 * 通道转换与真实拍照/选图完全一致，而不是基准里另开一条旁路。
 *
 * 覆盖验证：
 *   - 多图矩阵：rawfile/benchmark_images 下全部图片 × {SYNC, TASK_POOL}
 *   - 边界用例：空白图、损坏文件、超大图、EXIF 6/8、RGBA 带 alpha
 *   - 冷启动语义：首次 coldStart=true，后续 false
 *   - 触发入口：EntryAbility 读 want.parameters['benchTrigger']
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';

import { RecognitionService } from './RecognitionService';
import { decodeToImageSource } from '../camera/ImageDecoder';
import { MODEL_SHA256, classLabel } from '../../models/ModelConstants';
import { ImageSource, ImageOrigin } from '../../models/ImageTypes';
import { DetectionResult, InferenceExecutionMode } from '../../models/DetectionTypes';

const TAG: string = 'BenchmarkRunner';
const DOMAIN: number = 0x0004;
/** rawfile 下的测试图目录；生产包不应包含（BLK-13）。 */
const BENCH_RAW_DIR: string = 'benchmark_images';
/** 沙箱内测试图前缀，用于复用上次拷贝。 */
const BENCH_PREFIX: string = 'bench_';

/** 一张待测图片。 */
interface BenchImage {
  /** 展示名（比对脚本按此名匹配参考结果）。 */
  name: string;
  /** 沙箱内绝对路径。 */
  path: string;
}

/** 判断扩展名是否为可解码图片。 */
function isImageName(name: string): boolean {
  const lower: string = name.toLowerCase();
  return lower.endsWith('.jpg') || lower.endsWith('.jpeg') || lower.endsWith('.png');
}

/** 输出一条失败记录；比对脚本按 ERR| 前缀收集。 */
function emitError(file: string, mode: string, type: string, message: string): void {
  hilog.error(DOMAIN, TAG, 'ERR|%{public}s|%{public}s|%{public}s|%{public}s', file, mode, type, message);
}

/**
 * 输出一次识别的 RESULT 与全部 BOX。
 *
 * 坐标与置信度按契约放大为整数：conf×10000、坐标×10（0.1px 精度）。
 */
function emitResult(file: string, mode: string, src: ImageSource, result: DetectionResult | null): void {
  if (result === null) {
    emitError(file, mode, 'inference-failed', 'recognize returned null');
    return;
  }
  hilog.info(DOMAIN, TAG,
    'RESULT|%{public}s|%{public}s|true|%{public}d|%{public}d|%{public}d|%{public}d|%{public}d|%{public}d|%{public}d|%{public}d|%{public}d|%{public}s',
    file, mode, src.width, src.height, result.boxes.length,
    result.timing.preprocessMs, result.timing.inferenceMs,
    result.timing.postprocessMs, result.timing.totalMs,
    result.timing.coldStart ? 1 : 0, result.timing.modelLoadMs, MODEL_SHA256);

  for (let i = 0; i < result.boxes.length; i++) {
    const b = result.boxes[i];
    hilog.info(DOMAIN, TAG,
      'BOX|%{public}s|%{public}s|%{public}d|%{public}d|%{public}s|%{public}d|%{public}d|%{public}d|%{public}d|%{public}d',
      file, mode, i, b.classId, classLabel(b.classId),
      Math.round(b.confidence * 10000),
      Math.round(b.left * 10), Math.round(b.top * 10),
      Math.round(b.right * 10), Math.round(b.bottom * 10));
  }
}

/**
 * 收集待测图片。
 *
 * 优先从 rawfile 读取并拷贝到沙箱（保证每次验证用的是包内那一份）；
 * rawfile 不存在时回退扫描沙箱内已有的 `bench_*` 文件，
 * 这样重复验证不必为了测试图反复重打包（BLK-13 要求生产包不含测试资产）。
 */
async function collectImages(context: common.Context): Promise<BenchImage[]> {
  const found: BenchImage[] = [];

  try {
    const names: string[] = await context.resourceManager.getRawFileList(BENCH_RAW_DIR);
    const images: string[] = names.filter(isImageName).sort();
    for (const name of images) {
      const view: Uint8Array = await context.resourceManager.getRawFileContent(`${BENCH_RAW_DIR}/${name}`);
      const path: string = `${context.filesDir}/${BENCH_PREFIX}${name}`;
      const file = fileIo.openSync(path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, view.buffer as ArrayBuffer,
        { offset: view.byteOffset, length: view.byteLength });
      fileIo.closeSync(file);
      found.push({ name: name, path: path });
    }
    if (found.length > 0) {
      hilog.info(DOMAIN, TAG, '从 rawfile 装载 %{public}d 张测试图', found.length);
      return found;
    }
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'rawfile 无测试图: %{public}s', (e as Error).message);
  }

  try {
    const files: string[] = fileIo.listFileSync(context.filesDir);
    const cached: string[] = files.filter((n: string) => n.startsWith(BENCH_PREFIX) && isImageName(n)).sort();
    for (const name of cached) {
      found.push({ name: name.substring(BENCH_PREFIX.length), path: `${context.filesDir}/${name}` });
    }
    if (found.length > 0) {
      hilog.info(DOMAIN, TAG, '复用沙箱内 %{public}d 张测试图', found.length);
    }
  } catch (e) {
    hilog.warn(DOMAIN, TAG, '扫描沙箱测试图失败: %{public}s', (e as Error).message);
  }

  return found;
}

/** 用业务同一条解码链路加载图片；失败返回 null 并记录原因。 */
async function loadImage(path: string): Promise<ImageSource | null> {
  let source: image.ImageSource | null = null;
  try {
    source = image.createImageSource(path);
    const decoded: ImageSource = await decodeToImageSource(source, ImageOrigin.GALLERY);
    return decoded;
  } catch (e) {
    hilog.error(DOMAIN, TAG, '解码失败 %{public}s: %{public}s', path, (e as Error).message);
    return null;
  } finally {
    if (source !== null) {
      try {
        await source.release();
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'release image source failed: %{public}s', JSON.stringify(e));
      }
    }
  }
}

/** 对一张图跑指定执行模式；异常转成 ERR 记录，不中断矩阵。 */
async function runOne(
  recognition: RecognitionService,
  file: string,
  mode: string,
  executionMode: InferenceExecutionMode,
  src: ImageSource
): Promise<void> {
  const requestId: string = `bench_${mode}_${Date.now()}`;
  try {
    const result: DetectionResult = await recognition.recognize(src, {
      confidenceThreshold: 0.25,
      iouThreshold: 0.7,
      maxDetections: 300,
      executionMode: executionMode
    }, requestId);
    emitResult(file, mode, src, result);
  } catch (e) {
    emitError(file, mode, 'recognize-failed', (e as Error).message);
  }
}

export async function runBenchmark(context: common.Context): Promise<void> {
  hilog.info(DOMAIN, TAG, '===== Multi-image Benchmark START =====');

  const recognition: RecognitionService = RecognitionService.getInstance();
  recognition.setContext(context);
  const avail = await recognition.initialize();
  hilog.info(DOMAIN, TAG, 'initialize ok=%{public}s', avail.available ? 'true' : 'false');
  if (!avail.available) {
    hilog.error(DOMAIN, TAG, 'SKIP: 模型不可用');
    return;
  }

  const images: BenchImage[] = await collectImages(context);
  if (images.length === 0) {
    hilog.error(DOMAIN, TAG, 'SKIP: 未找到测试图');
    return;
  }
  hilog.info(DOMAIN, TAG, '测试图 %{public}d 张: %{public}s', images.length,
    images.map((it: BenchImage) => it.name).join(','));

  for (let i = 0; i < images.length; i++) {
    const item: BenchImage = images[i];
    hilog.info(DOMAIN, TAG, '--- [%{public}d/%{public}d] %{public}s ---',
      i + 1, images.length, item.name);

    const src: ImageSource | null = await loadImage(item.path);
    if (src === null) {
      emitError(item.name, 'SYNC', 'decode-failed', 'image decode failed');
      continue;
    }
    hilog.info(DOMAIN, TAG, '尺寸 %{public}dx%{public}d, rowStride=%{public}d, exif=%{public}d',
      src.width, src.height, src.rowStride, src.exifOrientation);

    await runOne(recognition, item.name, 'SYNC', InferenceExecutionMode.SYNC, src);
    await runOne(recognition, item.name, 'TASK_POOL', InferenceExecutionMode.TASK_POOL, src);
  }

  hilog.info(DOMAIN, TAG, '===== Multi-image Benchmark Complete: %{public}d images =====',
    images.length);
}
