/**
 * 页面专用：把 ImageSource 的像素缓冲区转换为可显示的 PixelMap。
 *
 * 契约规定 ImageSource 只携带 ArrayBuffer，不含 URI/PixelMap；界面负责展示。
 * 方向归一化与镜像已由采集层完成，这里不得再次旋转或翻转。
 */
import { image } from '@kit.ImageKit';
import { ImageSource, PixelFormat } from '../../models/ImageTypes';

/** 每像素字节数。 */
function bytesPerPixel(format: PixelFormat): number {
  return format === PixelFormat.RGBA_8888 ? 4 : 3;
}

/** 去除行尾填充，生成紧凑像素缓冲区。 */
function packRows(source: ImageSource, rowBytes: number): ArrayBuffer {
  const packed: ArrayBuffer = new ArrayBuffer(rowBytes * source.height);
  const sourceBytes: Uint8Array = new Uint8Array(source.data);
  const targetBytes: Uint8Array = new Uint8Array(packed);
  for (let y = 0; y < source.height; y++) {
    const start: number = y * source.rowStride;
    targetBytes.set(sourceBytes.subarray(start, start + rowBytes), y * rowBytes);
  }
  return packed;
}

/**
 * 创建用于预览的 PixelMap。
 * 像素数据非法时抛出 Error，由调用方提示“预览失败但识别仍可继续”。
 */
export async function createPreviewPixelMap(source: ImageSource): Promise<image.PixelMap> {
  const bpp: number = bytesPerPixel(source.pixelFormat);
  const rowBytes: number = source.width * bpp;
  if (source.width <= 0 || source.height <= 0 || rowBytes <= 0) {
    throw new Error('图片尺寸无效');
  }
  if (source.rowStride < rowBytes) {
    throw new Error('rowStride 小于像素行宽');
  }
  if (source.rowStride * source.height > source.data.byteLength) {
    throw new Error('像素缓冲区长度不足');
  }

  const pixels: ArrayBuffer = source.rowStride === rowBytes ? source.data : packRows(source, rowBytes);
  const srcFormat: image.PixelMapFormat = source.pixelFormat === PixelFormat.RGBA_8888 ?
    image.PixelMapFormat.RGBA_8888 : image.PixelMapFormat.RGB_888;
  const options: image.InitializationOptions = {
    size: { width: source.width, height: source.height },
    srcPixelFormat: srcFormat,
    pixelFormat: image.PixelMapFormat.RGBA_8888,
    editable: false
  };
  return await image.createPixelMap(pixels, options);
}
