/**
 * 图像输入共享契约。由 Agent 0 维护，Agent 1 生产、Agent 2 消费、Agent 3 展示。
 */

/** 像素格式。本阶段只允许无 Alpha 预乘问题的 RGB/RGBA 紧凑排列。 */
export enum PixelFormat {
  RGB_888 = 'rgb888',
  RGBA_8888 = 'rgba8888'
}

/** 图像来源，仅用于诊断和界面提示，不参与坐标计算。 */
export enum ImageOrigin {
  CAMERA = 'camera',
  GALLERY = 'gallery'
}

/**
 * 方向归一化后的图像。
 *
 * 不变式：
 * - `data` 为行优先、无行尾填充之外的额外数据，长度必须等于 `rowStride * height`。
 * - 像素原点在左上角，x 向右，y 向下。
 * - 像素已按 EXIF 方向旋转/翻转，使 `width/height` 对应正常观看方向。
 * - 前置相机拍照结果默认不镜像；若生产方确实镜像了像素，必须令 `isMirrored = true`。
 * - `data` 是共享契约中唯一的大块像素载体，生产方不得在返回后继续写入。
 */
export interface ImageSource {
  /** 单次采集的唯一标识，用于旧结果丢弃和日志关联。 */
  imageId: string;
  origin: ImageOrigin;
  /** 方向归一化后的像素宽度。 */
  width: number;
  /** 方向归一化后的像素高度。 */
  height: number;
  pixelFormat: PixelFormat;
  /** 每行字节数。RGB 至少 width*3，RGBA 至少 width*4。 */
  rowStride: number;
  /** 紧邻排列的像素数据，所有行之间只有 rowStride 指定的填充。 */
  data: ArrayBuffer;
  /** 像素是否已做水平镜像。检测坐标与像素数据处于同一坐标系。 */
  isMirrored: boolean;
  /** 原始 EXIF Orientation（1-8）；无法获取时为 0。归一化后仅用于诊断。 */
  exifOrientation: number;
  /** 采集完成时间，Unix 毫秒。 */
  capturedAtMs: number;
}
