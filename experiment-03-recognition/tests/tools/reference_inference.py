#!/usr/bin/env python3
"""Reference YOLOv13n inference for acceptance tests.

Implements the post-processing contract in docs/phase-1-contract.md section 6
(RGB, letterbox 114, [1,84,8400], class-wise NMS, inverse letterbox) and prints
expected boxes in original-image pixels. Used to derive tests/expected/reference-detections.json.

This is a host-side oracle, not shipped code. Requires numpy, Pillow and onnxruntime:
  python3 -m venv .venv && .venv/bin/pip install numpy pillow onnxruntime
  .venv/bin/python tests/tools/reference_inference.py <model.onnx> <image...>
"""
import argparse
import json
import math
import sys

import numpy as np
from PIL import Image

INPUT = 640
PAD = 114
CONF = 0.25
IOU = 0.7
MAX_DET = 300


def js_round(value):
    """JavaScript Math.round: halves round toward +Infinity (Python round() is banker's)."""
    return math.floor(value + 0.5)


def letterbox(img):
    w, h = img.size
    scale = min(INPUT / w, INPUT / h)
    new_w, new_h = js_round(w * scale), js_round(h * scale)
    pad_left = js_round((INPUT - new_w) / 2 - 0.1)
    pad_top = js_round((INPUT - new_h) / 2 - 0.1)
    canvas = Image.new('RGB', (INPUT, INPUT), (PAD, PAD, PAD))
    canvas.paste(img.convert('RGB').resize((new_w, new_h), Image.BILINEAR), (pad_left, pad_top))
    return canvas, scale, pad_left, pad_top


def nms(boxes, scores, iou_thr):
    order = scores.argsort()[::-1]
    keep = []
    while order.size > 0:
        i = order[0]
        keep.append(int(i))
        rest = order[1:]
        if rest.size == 0:
            break
        xx1 = np.maximum(boxes[i, 0], boxes[rest, 0])
        yy1 = np.maximum(boxes[i, 1], boxes[rest, 1])
        xx2 = np.minimum(boxes[i, 2], boxes[rest, 2])
        yy2 = np.minimum(boxes[i, 3], boxes[rest, 3])
        inter = np.clip(xx2 - xx1, 0, None) * np.clip(yy2 - yy1, 0, None)
        area_i = (boxes[i, 2] - boxes[i, 0]) * (boxes[i, 3] - boxes[i, 1])
        area_r = (boxes[rest, 2] - boxes[rest, 0]) * (boxes[rest, 3] - boxes[rest, 1])
        iou = inter / np.maximum(area_i + area_r - inter, 1e-9)
        order = rest[iou <= iou_thr]
    return keep


def run(session, path, conf=CONF, iou=IOU):
    img = Image.open(path).convert('RGB')
    w, h = img.size
    canvas, scale, pl, pt = letterbox(img)
    tensor = (np.asarray(canvas, dtype=np.float32) / 255.0).transpose(2, 0, 1)[None, ...]
    pred = session.run([session.get_outputs()[0].name],
                       {session.get_inputs()[0].name: tensor})[0][0].T
    class_ids = pred[:, 4:].argmax(axis=1)
    confs = pred[:, 4:].max(axis=1)
    mask = confs >= conf
    pred, class_ids, confs = pred[mask], class_ids[mask], confs[mask]
    cx, cy, bw, bh = pred[:, 0], pred[:, 1], pred[:, 2], pred[:, 3]
    boxes = np.stack([cx - bw / 2, cy - bh / 2, cx + bw / 2, cy + bh / 2], axis=1).astype(np.float32)
    boxes[:, [0, 2]] = ((boxes[:, [0, 2]] - pl) / scale).clip(0, w)
    boxes[:, [1, 3]] = ((boxes[:, [1, 3]] - pt) / scale).clip(0, h)
    keep = []
    for c in np.unique(class_ids):
        idx = np.where(class_ids == c)[0]
        keep.extend(idx[k] for k in nms(boxes[idx], confs[idx], iou))
    keep = sorted(keep, key=lambda i: -confs[i])[:MAX_DET]
    return {
        'file': path.split('/')[-1],
        'width': w,
        'height': h,
        'scale': round(scale, 6),
        'padLeft': pl,
        'padTop': pt,
        'boxes': [{
            'classId': int(class_ids[i]),
            'confidence': round(float(confs[i]), 4),
            'left': round(float(boxes[i, 0]), 1),
            'top': round(float(boxes[i, 1]), 1),
            'right': round(float(boxes[i, 2]), 1),
            'bottom': round(float(boxes[i, 3]), 1),
        } for i in keep],
    }


def main():
    import onnxruntime as ort
    parser = argparse.ArgumentParser()
    parser.add_argument('model')
    parser.add_argument('images', nargs='+')
    args = parser.parse_args()
    session = ort.InferenceSession(args.model, providers=['CPUExecutionProvider'])
    results = []
    for path in args.images:
        try:
            results.append(run(session, path))
        except Exception as error:  # damaged/oversized fixtures are expected to fail
            results.append({'file': path.split('/')[-1], 'error': repr(error)})
    json.dump(results, sys.stdout, ensure_ascii=False, indent=2)
    print()


if __name__ == '__main__':
    main()
