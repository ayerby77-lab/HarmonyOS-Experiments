/**
 * 历史记录图片加载：把 RDB 中的相对路径解析为沙箱绝对路径并解码为 PixelMap。
 * 缩略图为列表使用，原图为详情使用，调用方负责 release 返回的 PixelMap。
 */
import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { ImageAssetStore } from '../../services/imaging/ImageAssetStore';

/**
 * @param relativePath RDB 中的相对路径，如 records/rec_xxx_thumb.jpg
 * @param maxEdge 最长边上限；<=0 表示按原尺寸解码
 */
export async function loadRecordPixelMap(context: common.Context, relativePath: string,
  maxEdge: number): Promise<image.PixelMap> {
  const absolutePath: string = ImageAssetStore.getInstance().resolveAbsolutePath(context, relativePath);
  const source: image.ImageSource = image.createImageSource(absolutePath);
  try {
    const info: image.ImageInfo = await source.getImageInfo();
    let width: number = info.size.width;
    let height: number = info.size.height;
    if (width <= 0 || height <= 0) {
      throw new Error('图片尺寸无效');
    }
    if (maxEdge > 0) {
      const longest: number = Math.max(width, height);
      if (longest > maxEdge) {
        const scale: number = maxEdge / longest;
        width = Math.max(1, Math.round(width * scale));
        height = Math.max(1, Math.round(height * scale));
      }
    }
    const options: image.DecodingOptions = {
      desiredSize: { width: width, height: height },
      desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
      editable: false
    };
    return await source.createPixelMap(options);
  } finally {
    await source.release();
  }
}
