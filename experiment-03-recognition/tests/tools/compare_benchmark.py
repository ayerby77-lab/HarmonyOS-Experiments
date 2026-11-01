#!/usr/bin/env python3
"""从 hilog 中解析 benchmark 输出，与主机侧参考结果自动比对。"""
import re
import json
import sys

def parse_hilog(text):
    results = {}  # (file, mode) -> {info, boxes}
    current_key = None
    for line in text.splitlines():
        m = re.search(r'(RESULT|BOX|ERR)\|', line)
        if not m:
            continue
        # 从第一个 RESULT| 或 BOX| 或 ERR| 开始解析
        marker_pos = line.find(m.group(1) + '|')
        payload = line[marker_pos:]

        if payload.startswith('RESULT|'):
            parts = payload.split('|')
            # RESULT|file|mode|ok|w|h|boxes|preMs|inferMs|postMs|totalMs|cold|loadMs|sha
            _, file, mode, ok, w, h, box_count, pre, infer, post, total, cold, load, sha = parts[:14]
            key = (file, mode)
            results[key] = {
                'info': {
                    'file': file, 'mode': mode, 'ok': ok == 'true',
                    'w': int(w), 'h': int(h), 'box_count': int(box_count),
                    'pre': int(pre), 'infer': int(infer), 'post': int(post),
                    'total': int(total), 'cold': int(cold), 'load': int(load),
                    'sha': sha
                },
                'boxes': []
            }
            current_key = key
        elif payload.startswith('BOX|') and current_key:
            parts = payload.split('|')
            # BOX|file|mode|index|classId|label|conf|left|top|right|bottom
            _, file, mode, idx, cls, label, conf, left, top, right, bottom = parts[:11]
            results[current_key]['boxes'].append({
                'classId': int(cls),
                'confidence': int(conf) / 10000.0,
                'left': int(left) / 10.0,
                'top': int(top) / 10.0,
                'right': int(right) / 10.0,
                'bottom': int(bottom) / 10.0,
                'label': label
            })
        elif payload.startswith('ERR|'):
            parts = payload.split('|')
            _, file, mode, errtype, *rest = parts
            results[(file, mode)] = {'info': {'file': file, 'mode': mode, 'ok': False, 'error': '|'.join(rest)}, 'boxes': []}
    return results

def compute_iou(a, b):
    xx1 = max(a['left'], b['left'])
    yy1 = max(a['top'], b['top'])
    xx2 = min(a['right'], b['right'])
    yy2 = min(a['bottom'], b['bottom'])
    inter = max(0, xx2 - xx1) * max(0, yy2 - yy1)
    area_a = (a['right'] - a['left']) * (a['bottom'] - a['top'])
    area_b = (b['right'] - b['left']) * (b['bottom'] - b['top'])
    union = max(area_a + area_b - inter, 1e-9)
    return inter / union

def match_boxes(host_boxes, dev_boxes, iou_thr=0.4):
    """贪心匹配：同类、IoU>=thr。返回 (matched, missing, extra)。"""
    matched = []
    used = set()
    for hb in host_boxes:
        best_iou = 0
        best_idx = -1
        for i, db in enumerate(dev_boxes):
            if i in used or db['classId'] != hb['classId']:
                continue
            iou = compute_iou(hb, db)
            if iou > best_iou:
                best_iou = iou
                best_idx = i
        if best_iou >= iou_thr:
            used.add(best_idx)
            matched.append((hb, dev_boxes[best_idx], best_iou))
    missing = [hb for hb in host_boxes if not any(m[0] is hb for m in matched)]
    extra = [db for i, db in enumerate(dev_boxes) if i not in used]
    return matched, missing, extra

def main():
    with open(sys.argv[1]) as f:
        hilog_text = f.read()
    with open(sys.argv[2]) as f:
        host_data = json.load(f)

    dev = parse_hilog(hilog_text)
    print(f"=== 设备 benchmark 解析: {len(dev)} 条目 ===\n")

    host_by_file = {h['file']: h for h in host_data}

    # 每个 (file, mode) 分别比对
    for (file, mode), entry in sorted(dev.items()):
        info = entry['info']
        if not info.get('ok'):
            print(f"[{file} {mode}] FAIL: {info.get('error', 'unknown')}")
            continue
        h = host_by_file.get(file)
        if h is None:
            print(f"[{file} {mode}] host 无参考（图片不在本次列表）")
            continue
        print(f"--- {file}  mode={mode}  ({info['w']}x{info['h']}) ---")
        print(f"  boxes: device={info['box_count']}  host={len(h['boxes'])}  "
              f"  time: pre={info['pre']}ms infer={info['infer']}ms post={info['post']}ms total={info['total']}ms")

        # SHA 校验
        host_sha = 'f39e5a3b1763423b1e60769e81b08a5da012677dce0248f4b4a95c5ad5cb799b'
        sha_ok = info['sha'].lower() == host_sha
        print(f"  modelSha256: {'✓' if sha_ok else '✗'} {info['sha'][:16]}...")

        host_boxes = h['boxes']
        dev_boxes = entry['boxes']
        matched, missing, extra = match_boxes(host_boxes, dev_boxes)

        if not host_boxes and not dev_boxes:
            print(f"  ✓ 双空结果一致")
            continue

        for hb, db, iou in matched:
            conf_diff = abs(hb['confidence'] - db['confidence'])
            box_diff = max(
                abs(hb['left'] - db['left']),
                abs(hb['top'] - db['top']),
                abs(hb['right'] - db['right']),
                abs(hb['bottom'] - db['bottom'])
            )
            mark = '✓' if conf_diff < 0.03 and box_diff < 15 else '~'
            print(f"  {mark}  cls={hb['classId']} host_conf={hb['confidence']:.4f} dev={db['confidence']:.4f} "
                  f"Δconf={conf_diff:.4f} IoU={iou:.3f} maxΔbox={box_diff:.1f}")

        for hb in missing:
            print(f"  ✗ host-only  cls={hb['classId']} conf={hb['confidence']:.4f}")
        for db in extra:
            print(f"  ? dev-only  cls={db['classId']} conf={db['confidence']:.4f}")
        print()

if __name__ == '__main__':
    main()
