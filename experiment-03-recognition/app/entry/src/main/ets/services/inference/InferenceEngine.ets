/**
 * 推理算法核心：letterbox、预处理、输出解析、NMS、坐标还原。
 *
 * 本模块为纯函数实现，不依赖任何原生句柄，可在 UI 线程与 TaskPool 工作线程中复用。
 * 所有坐标空间均以 ImageSource 方向归一化后的原图像素为参考。
 */
import { PixelFormat } from '../../models/ImageTypes';
import { DetectionBox, InferenceOptions } from '../../models/DetectionTypes';
import { classLabel } from '../../models/ModelConstants';

/** letterbox 缩放与填充信息，供坐标逆变换使用。 */
export interface LetterboxInfo {
  /** 原图到模型输入的缩放比例。 */
  scale: number;
  /** 左侧填充（模型输入空间，像素）。 */
  padLeft: number;
  /** 顶部填充（模型输入空间，像素）。 */
  padTop: number;
  /** 右侧填充。 */
  padRight: number;
  /** 底部填充。 */
  padBottom: number;
  /** 缩放后的有效宽度。 */
  newWidth: number;
  /** 缩放后的有效高度。 */
  newHeight: number;
  /** 模型输入宽度。 */
  modelWidth: number;
  /** 模型输入高度。 */
  modelHeight: number;
}

/** 原始检测结果（模型输入空间，cxcywh）。 */
export interface RawDetection {
  classId: number;
  confidence: number;
  cx: number;
  cy: number;
  w: number;
  h: number;
}

/** 预处理输出：NCHW float32 张量与 letterbox 信息。 */
export interface PreprocessResult {
  /** NCHW 布局，长度 3*modelHeight*modelWidth。 */
  tensor: Float32Array;
  letterbox: LetterboxInfo;
}

/**
 * 推理算法工具类。所有方法均为静态，便于同步与 TaskPool 模式共享。
 */
export class InferenceEngine {
  /**
   * 计算 letterbox 缩放与填充。
   * 保持宽高比，缩放后居中放入 modelWidth×modelHeight，剩余区域填充 114。
   */
  static letterbox(imageWidth: number, imageHeight: number, modelWidth: number, modelHeight: number): LetterboxInfo {
    const scale = Math.min(modelWidth / imageWidth, modelHeight / imageHeight);
    const newWidth = Math.round(imageWidth * scale);
    const newHeight = Math.round(imageHeight * scale);
    // 与 Ultralytics 一致：减去 0.1 处理半像素舍入，使总填充恰好填满模型尺寸。
    const padLeft = Math.round((modelWidth - newWidth) / 2 - 0.1);
    const padTop = Math.round((modelHeight - newHeight) / 2 - 0.1);
    const padRight = modelWidth - newWidth - padLeft;
    const padBottom = modelHeight - newHeight - padTop;
    return { scale, padLeft, padTop, padRight, padBottom, newWidth, newHeight, modelWidth, modelHeight };
  }

  /**
   * 图像预处理：颜色通道转换、双线性缩放、letterbox 填充、归一化、NCHW 排布。
   *
   * @param data 原始像素 ArrayBuffer（RGB 或 RGBA，行优先）。
   * @param rowStride 每行字节数。
   * @param width 原图宽度。
   * @param height 原图高度。
   * @param pixelFormat 像素格式。
   * @param modelWidth 模型输入宽度。
   * @param modelHeight 模型输入高度。
   * @returns NCHW float32 张量（0..1）与 letterbox 信息。
   */
  static preprocess(
    data: ArrayBuffer,
    rowStride: number,
    width: number,
    height: number,
    pixelFormat: PixelFormat,
    modelWidth: number,
    modelHeight: number
  ): PreprocessResult {
    const letterbox = InferenceEngine.letterbox(width, height, modelWidth, modelHeight);
    const channels = pixelFormat === PixelFormat.RGB_888 ? 3 : 4;
    const src = new Uint8Array(data);

    const planeSize = modelHeight * modelWidth;
    const tensor = new Float32Array(3 * planeSize);
    // letterbox 填充值 114，归一化后为 114/255。
    const padValue = 114.0 / 255.0;
    tensor.fill(padValue);

    const scale = letterbox.scale;
    const padLeft = letterbox.padLeft;
    const padTop = letterbox.padTop;
    const newWidth = letterbox.newWidth;
    const newHeight = letterbox.newHeight;
    const invScale = 1.0 / scale;

    for (let y = 0; y < newHeight; y++) {
      const srcY = y * invScale;
      const y0 = Math.floor(srcY);
      const y1 = Math.min(y0 + 1, height - 1);
      const wy = srcY - y0;
      const row0 = y0 * rowStride;
      const row1 = y1 * rowStride;

      for (let x = 0; x < newWidth; x++) {
        const srcX = x * invScale;
        const x0 = Math.floor(srcX);
        const x1 = Math.min(x0 + 1, width - 1);
        const wx = srcX - x0;

        const col0 = x0 * channels;
        const col1 = x1 * channels;

        // 双线性插值
        const r00 = src[row0 + col0];
        const g00 = src[row0 + col0 + 1];
        const b00 = src[row0 + col0 + 2];
        const r01 = src[row0 + col1];
        const g01 = src[row0 + col1 + 1];
        const b01 = src[row0 + col1 + 2];
        const r10 = src[row1 + col0];
        const g10 = src[row1 + col0 + 1];
        const b10 = src[row1 + col0 + 2];
        const r11 = src[row1 + col1];
        const g11 = src[row1 + col1 + 1];
        const b11 = src[row1 + col1 + 2];

        const w00 = (1 - wx) * (1 - wy);
        const w01 = wx * (1 - wy);
        const w10 = (1 - wx) * wy;
        const w11 = wx * wy;

        const r = r00 * w00 + r01 * w01 + r10 * w10 + r11 * w11;
        const g = g00 * w00 + g01 * w01 + g10 * w10 + g11 * w11;
        const b = b00 * w00 + b01 * w01 + b10 * w10 + b11 * w11;

        const destX = padLeft + x;
        const destY = padTop + y;
        const destIdx = destY * modelWidth + destX;

        tensor[destIdx] = r / 255.0;
        tensor[planeSize + destIdx] = g / 255.0;
        tensor[2 * planeSize + destIdx] = b / 255.0;
      }
    }

    return { tensor, letterbox };
  }

  /**
   * 解析模型输出 [1, 84, 8400]。
   * 内存布局：output[channel * 8400 + anchor]，channel 0-3 为 cx,cy,w,h，4-83 为类别分数。
   * 类别分数已 Sigmoid，置信度取 80 类最大值（无 objectness）。
   */
  static parseOutput(
    outputBuffer: ArrayBuffer,
    numAnchors: number,
    numClasses: number
  ): RawDetection[] {
    const output = new Float32Array(outputBuffer);
    const detections: RawDetection[] = new Array(numAnchors);

    for (let i = 0; i < numAnchors; i++) {
      const cx = output[i];
      const cy = output[numAnchors + i];
      const w = output[2 * numAnchors + i];
      const h = output[3 * numAnchors + i];

      let maxScore = -1.0;
      let maxClass = 0;
      for (let c = 0; c < numClasses; c++) {
        const score = output[(4 + c) * numAnchors + i];
        if (score > maxScore) {
          maxScore = score;
          maxClass = c;
        }
      }

      detections[i] = { classId: maxClass, confidence: maxScore, cx, cy, w, h };
    }

    return detections;
  }

  /**
   * 按类别 NMS。先按置信度过滤，再对每个类别单独做贪心 NMS。
   */
  static nmsByClass(
    detections: RawDetection[],
    confidenceThreshold: number,
    iouThreshold: number,
    maxDetections: number
  ): RawDetection[] {
    const filtered: RawDetection[] = [];
    for (let i = 0; i < detections.length; i++) {
      if (detections[i].confidence >= confidenceThreshold) {
        filtered.push(detections[i]);
      }
    }

    // 按类别分组
    const classMap = new Map<number, RawDetection[]>();
    for (const d of filtered) {
      let group = classMap.get(d.classId);
      if (group === undefined) {
        group = [];
        classMap.set(d.classId, group);
      }
      group.push(d);
    }

    const kept: RawDetection[] = [];
    classMap.forEach((group: RawDetection[]) => {
      group.sort((a: RawDetection, b: RawDetection) => b.confidence - a.confidence);
      const classKept: RawDetection[] = [];
      for (let i = 0; i < group.length; i++) {
        const box = group[i];
        let suppress = false;
        for (let j = 0; j < classKept.length; j++) {
          if (InferenceEngine.computeIoU(box, classKept[j]) > iouThreshold) {
            suppress = true;
            break;
          }
        }
        if (!suppress) {
          classKept.push(box);
        }
      }
      for (let i = 0; i < classKept.length; i++) {
        kept.push(classKept[i]);
      }
    });

    // 全局按置信度降序，截断到 maxDetections
    kept.sort((a: RawDetection, b: RawDetection) => b.confidence - a.confidence);
    if (kept.length > maxDetections) {
      kept.length = maxDetections;
    }
    return kept;
  }

  /** 计算两个 cxcywh 框的 IoU。 */
  static computeIoU(a: RawDetection, b: RawDetection): number {
    const ax1 = a.cx - a.w / 2;
    const ay1 = a.cy - a.h / 2;
    const ax2 = a.cx + a.w / 2;
    const ay2 = a.cy + a.h / 2;

    const bx1 = b.cx - b.w / 2;
    const by1 = b.cy - b.h / 2;
    const bx2 = b.cx + b.w / 2;
    const by2 = b.cy + b.h / 2;

    const x1 = Math.max(ax1, bx1);
    const y1 = Math.max(ay1, by1);
    const x2 = Math.min(ax2, bx2);
    const y2 = Math.min(ay2, by2);

    const interW = Math.max(0, x2 - x1);
    const interH = Math.max(0, y2 - y1);
    const intersection = interW * interH;

    const areaA = (ax2 - ax1) * (ay2 - ay1);
    const areaB = (bx2 - bx1) * (by2 - by1);
    const union = areaA + areaB - intersection;

    if (union <= 0) {
      return 0;
    }
    return intersection / union;
  }

  /**
   * 将模型输入空间的检测框还原到原图像素空间并裁剪。
   * 丢弃退化框（right <= left 或 bottom <= top）。
   */
  static restoreCoordinates(
    detections: RawDetection[],
    letterbox: LetterboxInfo,
    imageWidth: number,
    imageHeight: number
  ): DetectionBox[] {
    const boxes: DetectionBox[] = [];
    const scale = letterbox.scale;

    for (let i = 0; i < detections.length; i++) {
      const d = detections[i];
      const x1 = (d.cx - d.w / 2 - letterbox.padLeft) / scale;
      const y1 = (d.cy - d.h / 2 - letterbox.padTop) / scale;
      const x2 = (d.cx + d.w / 2 - letterbox.padLeft) / scale;
      const y2 = (d.cy + d.h / 2 - letterbox.padTop) / scale;

      // 裁剪到原图范围
      const left = Math.max(0, Math.min(imageWidth, x1));
      const top = Math.max(0, Math.min(imageHeight, y1));
      const right = Math.max(0, Math.min(imageWidth, x2));
      const bottom = Math.max(0, Math.min(imageHeight, y2));

      if (right <= left || bottom <= top) {
        continue;
      }

      boxes.push({
        classId: d.classId,
        label: classLabel(d.classId),
        confidence: d.confidence,
        left,
        top,
        right,
        bottom
      });
    }
    return boxes;
  }

  /**
   * 完整后处理流水线：解析 → 置信度过滤 → 按类别 NMS → 坐标还原 → 裁剪。
   */
  static postprocess(
    outputBuffer: ArrayBuffer,
    letterbox: LetterboxInfo,
    imageWidth: number,
    imageHeight: number,
    numAnchors: number,
    numClasses: number,
    options: InferenceOptions
  ): DetectionBox[] {
    const raw = InferenceEngine.parseOutput(outputBuffer, numAnchors, numClasses);
    const kept = InferenceEngine.nmsByClass(raw, options.confidenceThreshold, options.iouThreshold, options.maxDetections);
    return InferenceEngine.restoreCoordinates(kept, letterbox, imageWidth, imageHeight);
  }
}
