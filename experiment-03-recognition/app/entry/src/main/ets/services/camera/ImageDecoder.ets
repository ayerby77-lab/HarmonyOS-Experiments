/**
 * 采集层共享解码管线：image.ImageSource → 契约 ImageSource。
 *
 * 职责（契约 2.1/2.2）：
 * - 解码为 RGBA_8888，不静默缩放；
 * - 读取 EXIF Orientation 并对 PixelMap 做方向归一化，使 (0,0) 为正常观看方向左上角；
 * - 输出紧凑排列的 ArrayBuffer（rowStride = width * 4），返回前释放所有原生对象；
 * - 超大图、损坏图、格式不支持统一以 IMAGE_INVALID 拒绝。
 */
import { image } from '@kit.ImageKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ImageOrigin, ImageSource, PixelFormat } from '../../models/ImageTypes';
import { RecognitionErrorCode, RecognitionFailure } from '../../models/DetectionTypes';

const TAG: string = 'ImageDecoder';
const DOMAIN: number = 0x0000;

/** 超大图像素数上限；超过时以 IMAGE_INVALID 拒绝，避免大内存分配失败。 */
export const MAX_IMAGE_PIXELS: number = 40000000;

/** RGBA_8888 每像素字节数。 */
const BYTES_PER_PIXEL: number = 4;

let imageSeq: number = 0;

function nextImageId(origin: ImageOrigin): string {
  imageSeq += 1;
  return `${origin}-${Date.now()}-${imageSeq}`;
}

/**
 * 将 getImageProperty(ORIENTATION) 返回的字符串解析为 EXIF 方向值 1-8；无法识别返回 0。
 * 取值形如 "Top-left"、"Right-top"、"Unknown Value 0"。
 */
export function parseExifOrientation(raw: string): number {
  switch (raw) {
    case 'Top-left': return 1;
    case 'Top-right': return 2;
    case 'Bottom-right': return 3;
    case 'Bottom-left': return 4;
    case 'Left-top': return 5;
    case 'Right-top': return 6;
    case 'Right-bottom': return 7;
    case 'Left-bottom': return 8;
    default: return 0;
  }
}

/**
 * 按 EXIF 方向对 PixelMap 做归一化（依据 image 模块 ORIENTATION 属性文档的变换描述）。
 * 1 不变；2 水平翻转；3 旋转 180；4 垂直翻转；
 * 5 水平翻转后顺时针 270；6 顺时针 90；7 垂直翻转后顺时针 90；8 顺时针 270。
 */
async function applyExifOrientation(pixelMap: image.PixelMap, exif: number): Promise<void> {
  switch (exif) {
    case 2:
      await pixelMap.flip(true, false);
      break;
    case 3:
      await pixelMap.rotate(180);
      break;
    case 4:
      await pixelMap.flip(false, true);
      break;
    case 5:
      await pixelMap.flip(true, false);
      await pixelMap.rotate(270);
      break;
    case 6:
      await pixelMap.rotate(90);
      break;
    case 7:
      await pixelMap.flip(false, true);
      await pixelMap.rotate(90);
      break;
    case 8:
      await pixelMap.rotate(270);
      break;
    default:
      break;
  }
}

/**
 * 解码已打开的 image.ImageSource 为契约 ImageSource。
 *
 * 不释放入参 `source`：由调用方管理其生命周期（相机 JPEG 与相册 fd 的释放路径不同）。
 *
 * @param source 已打开的 image.ImageSource（fd 或 JPEG 字节流）。
 * @param origin 图像来源（camera/gallery）。
 * @returns 方向归一化后的 ImageSource；失败时以 RecognitionFailure(IMAGE_INVALID) 拒绝。
 */
export async function decodeToImageSource(source: image.ImageSource, origin: ImageOrigin): Promise<ImageSource> {
  // 1. 尺寸检查，避免超大图分配失败。
  let size: image.Size;
  try {
    const info: image.ImageInfo = await source.getImageInfo(0);
    size = info.size;
  } catch (e) {
    throw new RecognitionFailure(RecognitionErrorCode.IMAGE_INVALID, '图片信息读取失败，请更换图片', true,
      `getImageInfo error: ${JSON.stringify(e)}`);
  }
  if (size.width <= 0 || size.height <= 0) {
    throw new RecognitionFailure(RecognitionErrorCode.IMAGE_INVALID, '图片损坏或尺寸无效，请更换图片', true,
      `invalid size ${size.width}x${size.height}`);
  }
  if (size.width * size.height > MAX_IMAGE_PIXELS) {
    throw new RecognitionFailure(RecognitionErrorCode.IMAGE_INVALID, '图片过大，请更换分辨率更小的图片', true,
      `pixels ${size.width}x${size.height} exceed ${MAX_IMAGE_PIXELS}`);
  }

  // 2. EXIF 方向（缺失或读取失败按未知处理，不旋转）。
  let exif: number = 0;
  try {
    const raw: string = await source.getImageProperty(image.PropertyKey.ORIENTATION);
    exif = parseExifOrientation(raw);
  } catch (e) {
    hilog.debug(DOMAIN, TAG, 'No EXIF orientation: %{public}s', JSON.stringify(e));
  }

  // 3. 解码为 RGBA_8888；不设置 desiredSize，禁止静默缩放。
  let pixelMap: image.PixelMap | null = null;
  try {
    const decodingOptions: image.DecodingOptions = {
      editable: true,
      desiredPixelFormat: image.PixelMapFormat.RGBA_8888
    };
    pixelMap = await source.createPixelMap(decodingOptions);
  } catch (e) {
    throw new RecognitionFailure(RecognitionErrorCode.IMAGE_INVALID, '图片解码失败或格式不支持，请更换图片', true,
      `createPixelMap error: ${JSON.stringify(e)}`);
  }

  try {
    // 4. 方向归一化。
    await applyExifOrientation(pixelMap, exif);

    // 5. 读取紧凑像素。
    const info: image.ImageInfo = pixelMap.getImageInfoSync();
    const width: number = info.size.width;
    const height: number = info.size.height;
    const buffer: ArrayBuffer = new ArrayBuffer(width * height * BYTES_PER_PIXEL);
    await pixelMap.readPixelsToBuffer(buffer);

    const result: ImageSource = {
      imageId: nextImageId(origin),
      origin: origin,
      width: width,
      height: height,
      pixelFormat: PixelFormat.RGBA_8888,
      rowStride: width * BYTES_PER_PIXEL,
      data: buffer,
      isMirrored: false,
      exifOrientation: exif,
      capturedAtMs: Date.now()
    };
    hilog.info(DOMAIN, TAG, 'Decoded %{public}s image %{public}s: %{public}dx%{public}d, exif=%{public}d',
      origin, result.imageId, width, height, exif);
    return result;
  } catch (e) {
    if (e instanceof RecognitionFailure) {
      throw e;
    }
    throw new RecognitionFailure(RecognitionErrorCode.IMAGE_INVALID, '图片像素读取失败，请更换图片', true,
      `pixel read error: ${JSON.stringify(e)}`);
  } finally {
    // 契约 5.3：返回前释放原生 PixelMap；调用方释放 ImageSource。
    try {
      await pixelMap.release();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'PixelMap release failed: %{public}s', JSON.stringify(e));
    }
  }
}
