/**
 * 页面专用：可编辑检测项与分类统计。
 *
 * 依据 docs/phase-1-data-contract.md 第 3.6 / 8.1 节：
 * - 保留全部原始框，删除只置 deleted=true（墓碑），不物理移除；
 * - 几何与置信度始终引用原始模型结果，类别修正只改 classId/label；
 * - 分类计数每次从同一数组重算，不维护独立计数器。
 */
import { DetectionBox, DetectionResult } from '../../models/DetectionTypes';
import { classLabel } from '../../models/ModelConstants';

/** 页面上可编辑的检测项；rawIndex 等于原始结果中的下标。 */
export interface EditableDetection {
  rawIndex: number;
  /** 模型原始类别，不可变。 */
  rawClassId: number;
  rawLabel: string;
  /** 当前最终类别。 */
  classId: number;
  label: string;
  /** 模型对原始类别的置信度；修正类别后仍保留。 */
  confidence: number;
  left: number;
  top: number;
  right: number;
  bottom: number;
  /** 用户是否删除该误检项；删除项不显示、不计数。 */
  deleted: boolean;
  /** 最近一次修正或删除的时间；未编辑为 0。 */
  editedAtMs: number;
}

/** 按类别聚合的数量（仅未删除项）。 */
export interface ClassCount {
  classId: number;
  label: string;
  count: number;
}

/** 从原始模型结果创建页面副本（全部框，含后续墓碑）。 */
export function buildEditableDetections(boxes: DetectionBox[]): EditableDetection[] {
  const items: EditableDetection[] = [];
  for (let index = 0; index < boxes.length; index++) {
    const box: DetectionBox = boxes[index];
    items.push({
      rawIndex: index,
      rawClassId: box.classId,
      rawLabel: classLabel(box.classId),
      classId: box.classId,
      label: classLabel(box.classId),
      confidence: box.confidence,
      left: box.left,
      top: box.top,
      right: box.right,
      bottom: box.bottom,
      deleted: false,
      editedAtMs: 0
    });
  }
  return items;
}

/** 修正单个检测项的类别，返回新数组以触发 UI 刷新。 */
export function applyClassChange(items: EditableDetection[], rawIndex: number, classId: number): EditableDetection[] {
  const label: string = classLabel(classId);
  const now: number = Date.now();
  return items.map((item: EditableDetection): EditableDetection => {
    if (item.rawIndex !== rawIndex) {
      return item;
    }
    return {
      rawIndex: item.rawIndex,
      rawClassId: item.rawClassId,
      rawLabel: item.rawLabel,
      classId: classId,
      label: label,
      confidence: item.confidence,
      left: item.left,
      top: item.top,
      right: item.right,
      bottom: item.bottom,
      deleted: item.deleted,
      editedAtMs: now
    };
  });
}

/** 删除/恢复误检项：置墓碑标记，不物理移除，保留原始框与类别。 */
export function setDeleted(items: EditableDetection[], rawIndex: number, deleted: boolean): EditableDetection[] {
  const now: number = Date.now();
  return items.map((item: EditableDetection): EditableDetection => {
    if (item.rawIndex !== rawIndex) {
      return item;
    }
    return {
      rawIndex: item.rawIndex,
      rawClassId: item.rawClassId,
      rawLabel: item.rawLabel,
      classId: item.classId,
      label: item.label,
      confidence: item.confidence,
      left: item.left,
      top: item.top,
      right: item.right,
      bottom: item.bottom,
      deleted: deleted,
      editedAtMs: now
    };
  });
}

/** 当前展示、计数使用的检测项（排除墓碑）。 */
export function activeDetections(items: EditableDetection[]): EditableDetection[] {
  return items.filter((item: EditableDetection): boolean => !item.deleted);
}

/** 统计当前结果中每个类别的数量，按数量降序、类别编号升序。 */
export function countByClass(items: EditableDetection[]): ClassCount[] {
  const counts: ClassCount[] = [];
  for (const item of items) {
    if (item.deleted) {
      continue;
    }
    const existingIndex: number = counts.findIndex((entry: ClassCount): boolean => entry.classId === item.classId);
    if (existingIndex >= 0) {
      counts[existingIndex].count += 1;
    } else {
      counts.push({ classId: item.classId, label: item.label, count: 1 });
    }
  }
  counts.sort((a: ClassCount, b: ClassCount): number => {
    if (b.count !== a.count) {
      return b.count - a.count;
    }
    return a.classId - b.classId;
  });
  return counts;
}

/** 已删除（墓碑）项数量。 */
export function countDeleted(items: EditableDetection[]): number {
  let deleted: number = 0;
  for (const item of items) {
    if (item.deleted) {
      deleted += 1;
    }
  }
  return deleted;
}

/** 当前展示项中被用户修改类别的数量。 */
export function countEdited(items: EditableDetection[]): number {
  let edited: number = 0;
  for (const item of items) {
    if (!item.deleted && item.classId !== item.rawClassId) {
      edited += 1;
    }
  }
  return edited;
}

/** 是否发生过编辑（改类或删除），用于显示“恢复原始结果”。 */
export function hasAnyEdit(items: EditableDetection[]): boolean {
  return countEdited(items) > 0 || countDeleted(items) > 0;
}

/** 导出可持久化的检测框（排除墓碑，不再携带编辑元数据）。 */
export function toModelBoxes(items: EditableDetection[]): DetectionBox[] {
  return activeDetections(items).map((item: EditableDetection): DetectionBox => {
    return {
      classId: item.classId,
      label: item.label,
      confidence: item.confidence,
      left: item.left,
      top: item.top,
      right: item.right,
      bottom: item.bottom
    };
  });
}
