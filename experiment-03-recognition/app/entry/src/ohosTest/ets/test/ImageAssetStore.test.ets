/**
 * ImageAssetStore 运行时验证（第二阶段，Agent 1）。
 *
 * 覆盖：persistCapturedImage 写出原图+缩略图、缩略图最长边≤480、小图不放大、
 * 文件路径格式、deleteImages 幂等、resolveAbsolutePath 路径校验与可重解析、
 * 孤儿清理对新文件的 mtime 宽限保护。
 */
import abilityDelegatorRegistry from '@ohos.application.abilityDelegatorRegistry';
import { common } from '@kit.AbilityKit';
import { describe, it, expect } from '@ohos/hypium';
import {
  CapturedImageAssets,
  ImageAssetStore
} from '../../../main/ets/services/imaging/ImageAssetStore';
import { ImageOrigin, ImageSource, PixelFormat } from '../../../main/ets/models/ImageTypes';

/** 获取应用上下文（测试环境）。 */
function appContext(): common.Context {
  return abilityDelegatorRegistry.getAbilityDelegator().getAppContext() as common.Context;
}

/** 构造一张 RGBA_8888 紧凑像素图。 */
function makeRgbaImage(width: number, height: number): ImageSource {
  const data: ArrayBuffer = new ArrayBuffer(width * height * 4);
  const arr: Uint8Array = new Uint8Array(data);
  for (let i: number = 0; i < width * height; i++) {
    arr[i * 4] = i % 256;
    arr[i * 4 + 1] = (i >> 1) % 256;
    arr[i * 4 + 2] = (i >> 2) % 256;
    arr[i * 4 + 3] = 255;
  }
  return {
    imageId: `test-${width}x${height}`,
    origin: ImageOrigin.GALLERY,
    width: width,
    height: height,
    pixelFormat: PixelFormat.RGBA_8888,
    rowStride: width * 4,
    data: data,
    isMirrored: false,
    exifOrientation: 1,
    capturedAtMs: Date.now()
  };
}

export default function testsuite(): void {
  describe('ImageAssetStore runtime', () => {
    it('persist writes original + thumbnail; thumbnail max edge <= 480', 0, async () => {
      const store: ImageAssetStore = ImageAssetStore.getInstance();
      const ctx: common.Context = appContext();
      const src: ImageSource = makeRgbaImage(1000, 600);
      const assets: CapturedImageAssets = await store.persistCapturedImage(ctx, src);

      // 原图保持输入尺寸
      expect(assets.original.width).assertEqual(1000);
      expect(assets.original.height).assertEqual(600);
      // 缩略图最长边 ≤ 480，且等比（宽高比约 1000:600 = 5:3）
      const thumbLongest: number = Math.max(assets.thumbnail.width, assets.thumbnail.height);
      expect(thumbLongest).assertLess(481);
      expect(thumbLongest > 0).assertTrue();
      // 比例校验：缩放因子 = 480/1000 = 0.48，缩略图约 480x288
      expect(Math.abs(assets.thumbnail.width - 480)).assertLess(2);
      expect(Math.abs(assets.thumbnail.height - 288)).assertLess(2);
      // 路径格式：扁平 records/{assetId}_original.jpg + _thumb.jpg
      expect(assets.originalPath.indexOf('/records/rec_')).assertLarger(0);
      expect(assets.originalPath.endsWith('_original.jpg')).assertTrue();
      expect(assets.thumbnailPath.endsWith('_thumb.jpg')).assertTrue();

      // 文件可读
      expect(await store.imageFileExists(ctx, assets.originalPath)).assertTrue();
      expect(await store.imageFileExists(ctx, assets.thumbnailPath)).assertTrue();

      await store.deleteImages(ctx, assets.originalPath, assets.thumbnailPath);
    });

    it('small image is not upscaled', 0, async () => {
      const store: ImageAssetStore = ImageAssetStore.getInstance();
      const ctx: common.Context = appContext();
      const src: ImageSource = makeRgbaImage(200, 300);
      const assets: CapturedImageAssets = await store.persistCapturedImage(ctx, src);
      // 最长边 300 < 480，不放大
      expect(assets.thumbnail.width).assertEqual(200);
      expect(assets.thumbnail.height).assertEqual(300);
      await store.deleteImages(ctx, assets.originalPath, assets.thumbnailPath);
    });

    it('deleteImages is idempotent', 0, async () => {
      const store: ImageAssetStore = ImageAssetStore.getInstance();
      const ctx: common.Context = appContext();
      const src: ImageSource = makeRgbaImage(640, 480);
      const assets: CapturedImageAssets = await store.persistCapturedImage(ctx, src);

      // 第一次删除
      await store.deleteImages(ctx, assets.originalPath, assets.thumbnailPath);
      // 第二次删除不抛错
      await store.deleteImages(ctx, assets.originalPath, assets.thumbnailPath);

      expect(await store.imageFileExists(ctx, assets.originalPath)).assertFalse();
    });

    it('resolveAbsolutePath parses relative and rejects unsafe paths', 0, () => {
      const store: ImageAssetStore = ImageAssetStore.getInstance();
      const ctx: common.Context = appContext();
      const rel: string = 'records/rec_x_thumb.jpg';
      const abs: string = store.resolveAbsolutePath(ctx, rel);
      // 重启后可重解析：相对路径在新 context 下仍能拼出同一绝对路径
      expect(abs.startsWith(ctx.filesDir)).assertTrue();
      expect(abs.endsWith(rel)).assertTrue();

      let rejectedAbsolute: boolean = false;
      try {
        store.resolveAbsolutePath(ctx, '/etc/passwd');
      } catch (e) {
        rejectedAbsolute = true;
      }
      expect(rejectedAbsolute).assertTrue();

      let rejectedDotDot: boolean = false;
      try {
        store.resolveAbsolutePath(ctx, 'records/../secret.jpg');
      } catch (e) {
        rejectedDotDot = true;
      }
      expect(rejectedDotDot).assertTrue();
    });

    it('newly persisted files are protected from orphan cleanup by mtime grace', 0, async () => {
      const store: ImageAssetStore = ImageAssetStore.getInstance();
      const ctx: common.Context = appContext();
      const src: ImageSource = makeRgbaImage(500, 500);
      const assets: CapturedImageAssets = await store.persistCapturedImage(ctx, src);

      // 新文件 mtime 在宽限期内，不应被列为孤儿
      const orphans: Array<string> =
        await store.listOrphanRecordImages(ctx, [], 10 * 60 * 1000);
      const hit: boolean = orphans.some((p: string): boolean =>
        p === assets.originalPath || p === assets.thumbnailPath);
      expect(hit).assertFalse();

      // 用 0 宽限强制列出，验证新文件确实在 records/ 下且可被识别为孤儿
      const forced: Array<string> = await store.listOrphanRecordImages(ctx, [], 0);
      const forcedHit: boolean = forced.some((p: string): boolean =>
        p === assets.originalPath || p === assets.thumbnailPath);
      expect(forcedHit).assertTrue();

      await store.deleteImages(ctx, assets.originalPath, assets.thumbnailPath);
    });
  });
}
