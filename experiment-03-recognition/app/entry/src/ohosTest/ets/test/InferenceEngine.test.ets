/**
 * InferenceEngine 纯算法单元测试。
 *
 * 覆盖：RGB/NCHW 布局、长宽图 letterbox padding 舍入、坐标还原、
 * 同类重叠框 NMS 抑制、异类框保留、空结果、阈值边界。
 *
 * 不依赖 ONNX 原生库，可在任意环境运行。
 */
import { describe, it, expect } from '@ohos/hypium';
import { InferenceEngine, LetterboxInfo, RawDetection } from
  '../../../main/ets/services/inference/InferenceEngine';
import { PixelFormat } from '../../../main/ets/models/ImageTypes';
import {
  DetectionBox,
  InferenceOptions,
  InferenceExecutionMode
} from '../../../main/ets/models/DetectionTypes';

/** 默认推理选项。 */
function defaultOptions(): InferenceOptions {
  const opts: InferenceOptions = {
    executionMode: InferenceExecutionMode.SYNC,
    confidenceThreshold: 0.25,
    iouThreshold: 0.45,
    maxDetections: 300
  };
  return opts;
}

/** 创建指定宽高的纯色 RGB 图像。 */
function makeRgbImage(width: number, height: number, r: number, g: number, b: number): ArrayBuffer {
  const buf = new ArrayBuffer(width * height * 3);
  const arr = new Uint8Array(buf);
  for (let i = 0; i < width * height; i++) {
    arr[i * 3] = r;
    arr[i * 3 + 1] = g;
    arr[i * 3 + 2] = b;
  }
  return buf;
}

/** 构造模型输出 [1, 84, numAnchors] 的 Float32Array。 */
function makeModelOutput(
  detections: RawDetection[],
  numAnchors: number,
  numClasses: number
): ArrayBuffer {
  const output = new Float32Array((4 + numClasses) * numAnchors);
  for (let i = 0; i < detections.length && i < numAnchors; i++) {
    const d = detections[i];
    output[i] = d.cx;
    output[numAnchors + i] = d.cy;
    output[2 * numAnchors + i] = d.w;
    output[3 * numAnchors + i] = d.h;
    output[(4 + d.classId) * numAnchors + i] = d.confidence;
  }
  return output.buffer as ArrayBuffer;
}

export default function InferenceEngineTest(): void {
  describe('InferenceEngine.letterbox', () => {
    it('宽图（1280x720）letterbox 填充正确', 0, () => {
      const lb = InferenceEngine.letterbox(1280, 720, 640, 640);
      // scale = min(640/1280, 640/720) = min(0.5, 0.8889) = 0.5
      expect(lb.scale).assertEqual(0.5);
      // newWidth = round(1280*0.5)=640, newHeight=round(720*0.5)=360
      expect(lb.newWidth).assertEqual(640);
      expect(lb.newHeight).assertEqual(360);
      // padLeft = round((640-640)/2 - 0.1) = round(-0.1) = 0
      expect(lb.padLeft).assertEqual(0);
      // padTop = round((640-360)/2 - 0.1) = round(140-0.1) = round(139.9) = 140
      expect(lb.padTop).assertEqual(140);
      // padRight = 640 - 640 - 0 = 0
      expect(lb.padRight).assertEqual(0);
      // padBottom = 640 - 360 - 140 = 140
      expect(lb.padBottom).assertEqual(140);
    });

    it('长图（720x1280）letterbox 填充正确', 0, () => {
      const lb = InferenceEngine.letterbox(720, 1280, 640, 640);
      // scale = min(640/720, 640/1280) = min(0.8889, 0.5) = 0.5
      expect(lb.scale).assertEqual(0.5);
      expect(lb.newWidth).assertEqual(360);
      expect(lb.newHeight).assertEqual(640);
      // padLeft = round((640-360)/2 - 0.1) = 140
      expect(lb.padLeft).assertEqual(140);
      expect(lb.padTop).assertEqual(0);
      expect(lb.padRight).assertEqual(140);
      expect(lb.padBottom).assertEqual(0);
    });

    it('正方形图无 padding', 0, () => {
      const lb = InferenceEngine.letterbox(640, 640, 640, 640);
      expect(lb.scale).assertEqual(1.0);
      expect(lb.newWidth).assertEqual(640);
      expect(lb.newHeight).assertEqual(640);
      expect(lb.padLeft).assertEqual(0);
      expect(lb.padTop).assertEqual(0);
      expect(lb.padRight).assertEqual(0);
      expect(lb.padBottom).assertEqual(0);
    });
  });

  describe('InferenceEngine.preprocess', () => {
    it('RGB 纯色图像 NCHW 布局正确', 0, () => {
      // 8x8 纯红色图像
      const data = makeRgbImage(8, 8, 255, 0, 0);
      const result = InferenceEngine.preprocess(
        data,
        8 * 3,
        8,
        8,
        PixelFormat.RGB_888,
        640,
        640
      );
      const planeSize = 640 * 640;
      // 正方形图，scale = 80, 但有效区域只有 8x8
      // 取左上角有效像素（0,0），在模型空间中 padLeft=padTop=(640-8*80)/2=0
      // 实际上 8*80=640，刚好填满，无 padding
      const lb = result.letterbox;
      expect(lb.padLeft).assertEqual(0);
      expect(lb.padTop).assertEqual(0);

      // 检查 (0,0) 像素的 R 通道 = 255/255 = 1.0
      const rVal = result.tensor[0];
      expect(rVal).assertClose(1.0, 0.01);
      // G 通道 = 0
      const gVal = result.tensor[planeSize];
      expect(gVal).assertClose(0.0, 0.01);
      // B 通道 = 0
      const bVal = result.tensor[2 * planeSize];
      expect(bVal).assertClose(0.0, 0.01);
    });

    it('padding 区域填充 114/255', 0, () => {
      // 宽图 16x8，scale=40, newWidth=640, newHeight=320, padTop=160
      const data = makeRgbImage(16, 8, 0, 0, 0);
      const result = InferenceEngine.preprocess(
        data,
        16 * 3,
        16,
        8,
        PixelFormat.RGB_888,
        640,
        640
      );
      const lb = result.letterbox;
      // 取 padding 区域（第一行，y=0，在 padTop 之上）
      // (0,0) 在模型空间中是 padding（因为 padTop=160，有效区域从 y=160 开始）
      const planeSize = 640 * 640;
      const padR = result.tensor[0]; // R 通道 padding 位置
      expect(padR).assertClose(114.0 / 255.0, 0.01);
    });

    it('NCHW 张量长度正确', 0, () => {
      const data = makeRgbImage(8, 8, 255, 255, 255);
      const result = InferenceEngine.preprocess(
        data,
        8 * 3,
        8,
        8,
        PixelFormat.RGB_888,
        640,
        640
      );
      expect(result.tensor.length).assertEqual(3 * 640 * 640);
    });
  });

  describe('InferenceEngine.parseOutput', () => {
    it('解析 [1,84,N] 输出，取最大类别分数', 0, () => {
      const det: RawDetection = {
        classId: 5,
        confidence: 0.9,
        cx: 100,
        cy: 200,
        w: 50,
        h: 60
      };
      const output = makeModelOutput([det], 8400, 80);
      const parsed = InferenceEngine.parseOutput(output, 8400, 80);
      expect(parsed[0].cx).assertClose(100, 0.001);
      expect(parsed[0].cy).assertClose(200, 0.001);
      expect(parsed[0].w).assertClose(50, 0.001);
      expect(parsed[0].h).assertClose(60, 0.001);
      expect(parsed[0].classId).assertEqual(5);
      expect(parsed[0].confidence).assertClose(0.9, 0.001);
    });
  });

  describe('InferenceEngine.nmsByClass', () => {
    it('同类重叠框被抑制，保留高置信度', 0, () => {
      const b1: RawDetection = { classId: 0, confidence: 0.9, cx: 100, cy: 100, w: 50, h: 50 };
      const b2: RawDetection = { classId: 0, confidence: 0.8, cx: 102, cy: 102, w: 50, h: 50 };
      const b3: RawDetection = { classId: 0, confidence: 0.3, cx: 300, cy: 300, w: 50, h: 50 };
      const kept = InferenceEngine.nmsByClass([b1, b2, b3], 0.25, 0.45, 300);
      // b1 和 b2 高度重叠（IoU > 0.45），只保留 b1（0.9 > 0.8）
      // b3 独立保留
      expect(kept.length).assertEqual(2);
      expect(kept[0].confidence).assertClose(0.9, 0.001);
    });

    it('异类重叠框均保留', 0, () => {
      const b1: RawDetection = { classId: 0, confidence: 0.9, cx: 100, cy: 100, w: 50, h: 50 };
      const b2: RawDetection = { classId: 1, confidence: 0.8, cx: 102, cy: 102, w: 50, h: 50 };
      const kept = InferenceEngine.nmsByClass([b1, b2], 0.25, 0.45, 300);
      // 不同类别，NMS 不互相抑制
      expect(kept.length).assertEqual(2);
    });

    it('低于置信度阈值的框被过滤', 0, () => {
      const b1: RawDetection = { classId: 0, confidence: 0.9, cx: 100, cy: 100, w: 50, h: 50 };
      const b2: RawDetection = { classId: 0, confidence: 0.2, cx: 300, cy: 300, w: 50, h: 50 };
      const kept = InferenceEngine.nmsByClass([b1, b2], 0.25, 0.45, 300);
      expect(kept.length).assertEqual(1);
      expect(kept[0].confidence).assertClose(0.9, 0.001);
    });

    it('阈值边界：恰好等于阈值的框保留', 0, () => {
      const b1: RawDetection = { classId: 0, confidence: 0.25, cx: 100, cy: 100, w: 50, h: 50 };
      const kept = InferenceEngine.nmsByClass([b1], 0.25, 0.45, 300);
      expect(kept.length).assertEqual(1);
    });

    it('空输入返回空数组', 0, () => {
      const kept = InferenceEngine.nmsByClass([], 0.25, 0.45, 300);
      expect(kept.length).assertEqual(0);
    });

    it('超过 maxDetections 被截断', 0, () => {
      const dets: RawDetection[] = [];
      for (let i = 0; i < 10; i++) {
        const d: RawDetection = {
          classId: i,
          confidence: 0.9 - i * 0.01,
          cx: i * 100,
          cy: 0,
          w: 50,
          h: 50
        };
        dets.push(d);
      }
      const kept = InferenceEngine.nmsByClass(dets, 0.25, 0.45, 3);
      expect(kept.length).assertEqual(3);
    });
  });

  describe('InferenceEngine.restoreCoordinates', () => {
    it('模型空间框正确还原到原图空间', 0, () => {
      // 正方形图，无 padding，scale=1
      const lb: LetterboxInfo = {
        scale: 1.0,
        padLeft: 0,
        padTop: 0,
        padRight: 0,
        padBottom: 0,
        newWidth: 640,
        newHeight: 640,
        modelWidth: 640,
        modelHeight: 640
      };
      const d: RawDetection = { classId: 0, confidence: 0.9, cx: 100, cy: 100, w: 50, h: 60 };
      const boxes = InferenceEngine.restoreCoordinates([d], lb, 640, 640);
      expect(boxes.length).assertEqual(1);
      // x1 = 100 - 25 = 75, y1 = 100 - 30 = 70
      // x2 = 100 + 25 = 125, y2 = 100 + 30 = 130
      expect(boxes[0].left).assertClose(75, 0.001);
      expect(boxes[0].top).assertClose(70, 0.001);
      expect(boxes[0].right).assertClose(125, 0.001);
      expect(boxes[0].bottom).assertClose(130, 0.001);
    });

    it('有 padding 时坐标正确还原', 0, () => {
      // 宽图 1280x720，scale=0.5, padTop=140, padLeft=0
      const lb: LetterboxInfo = {
        scale: 0.5,
        padLeft: 0,
        padTop: 140,
        padRight: 0,
        padBottom: 140,
        newWidth: 640,
        newHeight: 360,
        modelWidth: 640,
        modelHeight: 640
      };
      // 模型空间中 cx=100, cy=200, w=50, h=50
      // x1 = (100-25-0)/0.5 = 150, y1 = (200-25-140)/0.5 = 70
      const d: RawDetection = { classId: 0, confidence: 0.9, cx: 100, cy: 200, w: 50, h: 50 };
      const boxes = InferenceEngine.restoreCoordinates([d], lb, 1280, 720);
      expect(boxes.length).assertEqual(1);
      expect(boxes[0].left).assertClose(150, 0.001);
      expect(boxes[0].top).assertClose(70, 0.001);
      expect(boxes[0].right).assertClose(250, 0.001);
      expect(boxes[0].bottom).assertClose(170, 0.001);
    });

    it('超出原图的框被裁剪', 0, () => {
      const lb: LetterboxInfo = {
        scale: 1.0,
        padLeft: 0,
        padTop: 0,
        padRight: 0,
        padBottom: 0,
        newWidth: 640,
        newHeight: 640,
        modelWidth: 640,
        modelHeight: 640
      };
      // 框中心在 (630, 630)，宽高 100，会超出右下角
      const d: RawDetection = { classId: 0, confidence: 0.9, cx: 630, cy: 630, w: 100, h: 100 };
      const boxes = InferenceEngine.restoreCoordinates([d], lb, 640, 640);
      expect(boxes.length).assertEqual(1);
      expect(boxes[0].right).assertClose(640, 0.001);
      expect(boxes[0].bottom).assertClose(640, 0.001);
    });

    it('退化框（w<=0 或 h<=0）被丢弃', 0, () => {
      const lb: LetterboxInfo = {
        scale: 1.0,
        padLeft: 0,
        padTop: 0,
        padRight: 0,
        padBottom: 0,
        newWidth: 640,
        newHeight: 640,
        modelWidth: 640,
        modelHeight: 640
      };
      // w=0 的退化框
      const d: RawDetection = { classId: 0, confidence: 0.9, cx: 100, cy: 100, w: 0, h: 50 };
      const boxes = InferenceEngine.restoreCoordinates([d], lb, 640, 640);
      expect(boxes.length).assertEqual(0);
    });
  });

  describe('InferenceEngine.postprocess 完整流水线', () => {
    it('全零输出返回空结果', 0, () => {
      const lb: LetterboxInfo = {
        scale: 1.0,
        padLeft: 0,
        padTop: 0,
        padRight: 0,
        padBottom: 0,
        newWidth: 640,
        newHeight: 640,
        modelWidth: 640,
        modelHeight: 640
      };
      const output = new Float32Array(84 * 8400).buffer as ArrayBuffer;
      const opts = defaultOptions();
      const boxes = InferenceEngine.postprocess(output, lb, 640, 640, 8400, 80, opts);
      expect(boxes.length).assertEqual(0);
    });

    it('单个高置信度检测正确还原', 0, () => {
      const lb: LetterboxInfo = {
        scale: 1.0,
        padLeft: 0,
        padTop: 0,
        padRight: 0,
        padBottom: 0,
        newWidth: 640,
        newHeight: 640,
        modelWidth: 640,
        modelHeight: 640
      };
      const det: RawDetection = {
        classId: 0,
        confidence: 0.95,
        cx: 320,
        cy: 320,
        w: 100,
        h: 100
      };
      const output = makeModelOutput([det], 8400, 80);
      const opts = defaultOptions();
      const boxes = InferenceEngine.postprocess(output, lb, 640, 640, 8400, 80, opts);
      expect(boxes.length).assertEqual(1);
      expect(boxes[0].left).assertClose(270, 0.001);
      expect(boxes[0].top).assertClose(270, 0.001);
      expect(boxes[0].right).assertClose(370, 0.001);
      expect(boxes[0].bottom).assertClose(370, 0.001);
      expect(boxes[0].confidence).assertClose(0.95, 0.001);
    });
  });
}
