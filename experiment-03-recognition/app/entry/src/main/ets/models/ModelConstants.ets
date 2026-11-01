/**
 * YOLOv13n 模型常量。与 docs/phase-1-model.md 保持一致。
 * 修改模型文件时必须同步更新 SHA-256 与输入输出信息。
 */
import { ModelInfo, InferenceOptions, InferenceExecutionMode } from './DetectionTypes';

export const MODEL_ID: string = 'yolov13n-coco-640-opset18';
export const MODEL_FILE_NAME: string = 'yolov13n.onnx';
export const MODEL_ASSET_PATH: string = 'models/yolov13n.onnx';
export const MODEL_SHA256: string = 'f39e5a3b1763423b1e60769e81b08a5da012677dce0248f4b4a95c5ad5cb799b';
export const MODEL_INPUT_NAME: string = 'images';
export const MODEL_OUTPUT_NAME: string = 'output0';
export const MODEL_INPUT_WIDTH: number = 640;
export const MODEL_INPUT_HEIGHT: number = 640;
export const MODEL_CLASS_COUNT: number = 80;
export const MODEL_OPSET: number = 18;
/** 输出通道数 = 4 bbox + 80 classes。 */
export const MODEL_OUTPUT_CHANNELS: number = 84;
/** stride 8/16/32 在 640×640 下的锚点总数 = 80² + 40² + 20²。 */
export const MODEL_NUM_ANCHORS: number = 8400;
/** 输出张量字节数 = 84 × 8400 × 4。 */
export const MODEL_OUTPUT_BYTES: number = 2822400;

/** 预处理参数：RGB、0..1、NCHW、letterbox 填充值 114、stride 32。 */
export const MODEL_LETTERBOX_PAD_VALUE: number = 114;
export const MODEL_STRIDE: number = 32;

export const DEFAULT_CONFIDENCE_THRESHOLD: number = 0.25;
export const DEFAULT_IOU_THRESHOLD: number = 0.7;
export const DEFAULT_MAX_DETECTIONS: number = 300;

export const MODEL_INFO: ModelInfo = {
  modelId: MODEL_ID,
  fileName: MODEL_FILE_NAME,
  assetPath: MODEL_ASSET_PATH,
  sha256: MODEL_SHA256,
  inputName: MODEL_INPUT_NAME,
  outputName: MODEL_OUTPUT_NAME,
  inputWidth: MODEL_INPUT_WIDTH,
  inputHeight: MODEL_INPUT_HEIGHT,
  classCount: MODEL_CLASS_COUNT,
  opset: MODEL_OPSET
};

export const DEFAULT_INFERENCE_OPTIONS: InferenceOptions = {
  confidenceThreshold: DEFAULT_CONFIDENCE_THRESHOLD,
  iouThreshold: DEFAULT_IOU_THRESHOLD,
  maxDetections: DEFAULT_MAX_DETECTIONS,
  executionMode: InferenceExecutionMode.TASK_POOL
};

/** COCO 80 类，下标即 DetectionBox.classId。顺序与模型元数据 names 一致。 */
export const COCO_CLASSES: string[] = [
  'person', 'bicycle', 'car', 'motorcycle', 'airplane', 'bus', 'train', 'truck', 'boat', 'traffic light',
  'fire hydrant', 'stop sign', 'parking meter', 'bench', 'bird', 'cat', 'dog', 'horse', 'sheep', 'cow',
  'elephant', 'bear', 'zebra', 'giraffe', 'backpack', 'umbrella', 'handbag', 'tie', 'suitcase', 'frisbee',
  'skis', 'snowboard', 'sports ball', 'kite', 'baseball bat', 'baseball glove', 'skateboard', 'surfboard',
  'tennis racket', 'bottle', 'wine glass', 'cup', 'fork', 'knife', 'spoon', 'bowl', 'banana', 'apple',
  'sandwich', 'orange', 'broccoli', 'carrot', 'hot dog', 'pizza', 'donut', 'cake', 'chair', 'couch',
  'potted plant', 'bed', 'dining table', 'toilet', 'tv', 'laptop', 'mouse', 'remote', 'keyboard',
  'cell phone', 'microwave', 'oven', 'toaster', 'sink', 'refrigerator', 'book', 'clock', 'vase',
  'scissors', 'teddy bear', 'hair drier', 'toothbrush'
];

/** 获取可展示的类别名；越界时返回 `class-{id}`，避免界面崩溃。 */
export function classLabel(classId: number): string {
  if (classId >= 0 && classId < COCO_CLASSES.length) {
    return COCO_CLASSES[classId];
  }
  return `class-${classId}`;
}
