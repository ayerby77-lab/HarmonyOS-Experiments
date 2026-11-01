/**
 * 页面专用：把原图像素坐标映射到图片在容器内的实际显示区域。
 *
 * 契约依据 docs/phase-1-contract.md 第 2.3 节：静态图以 contain 显示，
 * 必须扣除上下/左右留白，且不得再次旋转或镜像。
 */

/** contain 布局参数，单位均为 vp（容器测量值）与检测框像素的换算关系。 */
export interface ContainLayout {
  valid: boolean;
  /** 原图像素到显示 vp 的缩放比例。 */
  scale: number;
  /** contain 产生的水平留白。 */
  offsetX: number;
  /** contain 产生的垂直留白。 */
  offsetY: number;
  /** 图片实际显示宽度。 */
  contentWidth: number;
  /** 图片实际显示高度。 */
  contentHeight: number;
}

/** 映射后的显示矩形，单位 vp。 */
export interface DisplayRect {
  left: number;
  top: number;
  width: number;
  height: number;
}

const EMPTY_RECT: DisplayRect = { left: 0, top: 0, width: 0, height: 0 };

/** 计算 contain 布局；任一尺寸非法时返回 valid=false，调用方不得绘制检测框。 */
export function computeContainLayout(
  imageWidth: number,
  imageHeight: number,
  viewWidth: number,
  viewHeight: number
): ContainLayout {
  const valid: boolean = imageWidth > 0 && imageHeight > 0 && viewWidth > 0 && viewHeight > 0;
  if (!valid) {
    return { valid: false, scale: 0, offsetX: 0, offsetY: 0, contentWidth: 0, contentHeight: 0 };
  }
  const scale: number = Math.min(viewWidth / imageWidth, viewHeight / imageHeight);
  if (!Number.isFinite(scale) || scale <= 0) {
    return { valid: false, scale: 0, offsetX: 0, offsetY: 0, contentWidth: 0, contentHeight: 0 };
  }
  const contentWidth: number = imageWidth * scale;
  const contentHeight: number = imageHeight * scale;
  return {
    valid: true,
    scale: scale,
    offsetX: (viewWidth - contentWidth) / 2,
    offsetY: (viewHeight - contentHeight) / 2,
    contentWidth: contentWidth,
    contentHeight: contentHeight
  };
}

/**
 * 将原图像素检测框映射为显示矩形。
 * 坐标按契约已裁剪在图片内；这里再做一次显示区域裁剪，避免描边越界。
 */
export function mapBoxToDisplay(
  left: number,
  top: number,
  right: number,
  bottom: number,
  layout: ContainLayout
): DisplayRect {
  if (!layout.valid || !Number.isFinite(left) || !Number.isFinite(top) ||
    !Number.isFinite(right) || !Number.isFinite(bottom) || right <= left || bottom <= top) {
    return EMPTY_RECT;
  }
  const x1: number = layout.offsetX + left * layout.scale;
  const y1: number = layout.offsetY + top * layout.scale;
  const x2: number = layout.offsetX + right * layout.scale;
  const y2: number = layout.offsetY + bottom * layout.scale;
  const clampedLeft: number = Math.max(layout.offsetX, Math.min(x1, layout.offsetX + layout.contentWidth));
  const clampedTop: number = Math.max(layout.offsetY, Math.min(y1, layout.offsetY + layout.contentHeight));
  const clampedRight: number = Math.max(clampedLeft,
    Math.min(x2, layout.offsetX + layout.contentWidth));
  const clampedBottom: number = Math.max(clampedTop,
    Math.min(y2, layout.offsetY + layout.contentHeight));
  return {
    left: clampedLeft,
    top: clampedTop,
    width: Math.max(1, clampedRight - clampedLeft),
    height: Math.max(1, clampedBottom - clampedTop)
  };
}

/** 置信度展示为百分比文本。 */
export function formatConfidence(confidence: number): string {
  if (!Number.isFinite(confidence)) {
    return '--';
  }
  return `${(confidence * 100).toFixed(1)}%`;
}

/** 耗时展示：小于 100 ms 保留一位小数，其余取整。 */
export function formatMs(ms: number): string {
  if (!Number.isFinite(ms) || ms < 0) {
    return '--';
  }
  return ms < 100 ? `${ms.toFixed(1)} ms` : `${ms.toFixed(0)} ms`;
}
