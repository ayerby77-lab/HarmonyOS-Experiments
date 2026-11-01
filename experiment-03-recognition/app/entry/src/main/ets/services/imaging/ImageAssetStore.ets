/**
 * 图像资源持久化（第二阶段，Agent 1）。已按 docs/phase-2-contract.md 对齐。
 *
 * 对齐依据（phase-2-contract.md 2.4/5.1/5.2/5.3/6.3 + models/RecordTypes.ets 冻结常量）：
 * - 布局：filesDir/records/{assetId}_original.jpg + {assetId}_thumb.jpg（扁平，无子目录）；
 * - 缩略图：最长边 ≤ 480 px，JPEG quality 80，等比不放大；原图 JPEG quality 90
 *   （参数与 Agent 0 冻结的 RecordTypes.ets 常量 THUMBNAIL_MAX_EDGE 等一致）；
 * - assetId 格式 rec_{unix_ms}_{hex4}，与 recordId 生成规则一致：
 *   每次 persist 生成新 id，重复保存产生独立文件，不覆盖仍被记录引用的旧文件；
 *   建议 Agent 4 直接采用 assetId 作为 recordId（见交接报告协调节）；
 * - 写入：临时目录 → rename 原子就位；任一文件失败，清理该 assetId 已写文件，不进 RDB 流程；
 * - 删除：幂等，缺文件不报错；只接受 records/ 下 _original.jpg/_thumb.jpg 路径；
 * - 孤儿清理：按“文件名 id 不在引用集合”判定，带 mtime 宽限（默认 10 分钟），
 *   避免把正在保存流程中、尚未写入 RDB 的新文件误删；单次最多 200 个（契约 5.3）。
 *
 * 临时 URI vs 长期文件：picker URI 与相机 JPEG 缓冲只在采集当次有效，解码为
 * ImageSource 像素后由本模块落成沙箱 JPEG；像素 ArrayBuffer 本身不持久化（契约 2.4）。
 *
 * 线程说明：编码与文件 I/O 在调用线程同步执行；调用方应在后台任务中调用。
 */
import { image } from '@kit.ImageKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ImageSource, PixelFormat } from '../../models/ImageTypes';
import { MAX_IMAGE_PIXELS } from '../camera/ImageDecoder';

const TAG: string = 'ImageAssetStore';
const DOMAIN: number = 0x0000;

/** 缩略图最长边（像素），与 RecordTypes.ets（Agent 0 冻结）一致。 */
export const THUMBNAIL_MAX_EDGE: number = 480;
/** 缩略图 JPEG 质量（RecordTypes.ets 冻结值）。 */
export const THUMBNAIL_JPEG_QUALITY: number = 80;
/** 原图副本 JPEG 质量。 */
export const ORIGINAL_JPEG_QUALITY: number = 90;

/** 图像根目录名（filesDir 下）。 */
export const RECORDS_DIR_NAME: string = 'records';
const TEMP_DIR_NAME: string = 'tmp';
const ORIGINAL_SUFFIX: string = '_original.jpg';
const THUMB_SUFFIX: string = '_thumb.jpg';
const JPEG_FORMAT: string = 'image/jpeg';
const JPEG_FORMAT_LABEL: string = 'jpeg';
/** 孤儿清理：mtime 早于此宽限期的文件才允许删除，保护进行中的保存流程。 */
export const ORPHAN_GRACE_PERIOD_MS: number = 10 * 60 * 1000;
/** 孤儿清理单次上限（契约 5.3）。 */
export const ORPHAN_CLEANUP_MAX_COUNT: number = 200;

export type ImageAssetErrorCode = 'invalid-input' | 'encode-failed' | 'io-failed';

/**
 * 图像持久化错误。与 Agent 4 RecordErrorCode 映射：
 * io-failed -> IMAGE_COPY_FAILED；encode-failed -> THUMBNAIL_FAILED。
 */
export class ImageAssetError extends Error {
  code: ImageAssetErrorCode;
  detail: string;

  constructor(code: ImageAssetErrorCode, message: string, detail: string) {
    super(message);
    this.code = code;
    this.detail = detail;
  }
}

/** 单个已保存文件的元信息。 */
export interface PersistedImageFile {
  /** 相对 filesDir 的路径，如 records/rec_xxx_original.jpg。 */
  relativePath: string;
  width: number;
  height: number;
  format: string;
  byteSize: number;
}

/** 一次持久化的产物；originalPath/thumbnailPath 为绝对路径，可直接解码或传给 RecordService.save。 */
export interface CapturedImageAssets {
  /** rec_{unix_ms}_{hex4}；建议 Agent 4 直接用作 recordId。 */
  assetId: string;
  /** 原图绝对路径：filesDir/records/{assetId}_original.jpg。 */
  originalPath: string;
  /** 缩略图绝对路径：filesDir/records/{assetId}_thumb.jpg。 */
  thumbnailPath: string;
  original: PersistedImageFile;
  thumbnail: PersistedImageFile;
}

/** 采集返回结构（契约 6.3 数据流）：像素供推理，路径供持久化。 */
export interface CapturedImage {
  imageSource: ImageSource;
  assets: CapturedImageAssets;
}

let idSeq: number = 0;
let tempSeq: number = 0;

export class ImageAssetStore {
  private static instance: ImageAssetStore | null = null;

  static getInstance(): ImageAssetStore {
    if (ImageAssetStore.instance === null) {
      ImageAssetStore.instance = new ImageAssetStore();
    }
    return ImageAssetStore.instance;
  }

  private constructor() {
  }

  /**
   * 把方向归一化后的 ImageSource 像素持久化为原图 + 缩略图（契约 6.3 数据流）。
   *
   * 每次调用生成新 assetId：重复保存同一图片产生两组独立文件，
   * 不覆盖、不删除仍可能被记录引用的旧文件（重复保存保护）。
   *
   * @throws ImageAssetError（invalid-input/encode-failed/io-failed）；失败时清理半成品。
   */
  async persistCapturedImage(context: common.Context, captured: ImageSource): Promise<CapturedImageAssets> {
    if (captured.pixelFormat !== PixelFormat.RGBA_8888) {
      throw new ImageAssetError('invalid-input', '仅支持 RGBA_8888 像素', `format=${captured.pixelFormat}`);
    }
    if (captured.width <= 0 || captured.height <= 0 || captured.width * captured.height > MAX_IMAGE_PIXELS) {
      throw new ImageAssetError('invalid-input', '图片尺寸无效或过大',
        `${captured.width}x${captured.height}`);
    }
    const expectedBytes: number = captured.width * captured.height * 4;
    if (captured.rowStride !== captured.width * 4 || captured.data.byteLength < expectedBytes) {
      throw new ImageAssetError('invalid-input', '像素缓冲与尺寸不一致',
        `rowStride=${captured.rowStride}, byteLength=${captured.data.byteLength}, expect=${expectedBytes}`);
    }

    const assetId: string = ImageAssetStore.nextAssetId();
    const filesDir: string = context.filesDir;
    const recordsDir: string = `${filesDir}/${RECORDS_DIR_NAME}`;
    tempSeq += 1;
    const tempDir: string = `${filesDir}/${TEMP_DIR_NAME}/img-${Date.now()}-${tempSeq}`;
    const finalOriginal: string = `${recordsDir}/${assetId}${ORIGINAL_SUFFIX}`;
    const finalThumb: string = `${recordsDir}/${assetId}${THUMB_SUFFIX}`;

    let pixelMap: image.PixelMap | null = null;
    try {
      const initOptions: image.InitializationOptions = {
        size: { width: captured.width, height: captured.height },
        pixelFormat: image.PixelMapFormat.RGBA_8888,
        editable: true
      };
      pixelMap = image.createPixelMapSync(captured.data, initOptions);

      fs.mkdirSync(tempDir, true);

      // 缩略图：保持方向与比例，最长边 480，不放大。
      const thumbBuffer: ArrayBuffer =
        await ImageAssetStore.encodeScaledJpeg(pixelMap, THUMBNAIL_MAX_EDGE, THUMBNAIL_JPEG_QUALITY);
      ImageAssetStore.writeFileSync(`${tempDir}/${THUMB_SUFFIX}`, thumbBuffer);

      // 原图副本：不缩放。
      const originalBuffer: ArrayBuffer =
        await ImageAssetStore.encodeScaledJpeg(pixelMap, 0, ORIGINAL_JPEG_QUALITY);
      ImageAssetStore.writeFileSync(`${tempDir}/${ORIGINAL_SUFFIX}`, originalBuffer);

      // 原子就位：临时目录 → records/。
      // 注意：本设备 fileIo.mkdirSync 在目录已存在时抛 EEXIST（13900015），不能直接调用。
      if (!fs.accessSync(recordsDir)) {
        fs.mkdirSync(recordsDir, true);
      }
      ImageAssetStore.moveIntoPlace(`${tempDir}/${THUMB_SUFFIX}`, finalThumb);
      ImageAssetStore.moveIntoPlace(`${tempDir}/${ORIGINAL_SUFFIX}`, finalOriginal);

      const thumbnail: PersistedImageFile =
        await ImageAssetStore.describeSaved(finalThumb, `${RECORDS_DIR_NAME}/${assetId}${THUMB_SUFFIX}`);
      const original: PersistedImageFile =
        await ImageAssetStore.describeSaved(finalOriginal, `${RECORDS_DIR_NAME}/${assetId}${ORIGINAL_SUFFIX}`);
      hilog.info(DOMAIN, TAG, 'Persisted %{public}s: thumb %{public}dB, original %{public}dB',
        assetId, thumbnail.byteSize, original.byteSize);
      const assets: CapturedImageAssets = {
        assetId: assetId,
        originalPath: finalOriginal,
        thumbnailPath: finalThumb,
        original: original,
        thumbnail: thumbnail
      };
      return assets;
    } catch (e) {
      // 写入失败回滚：清理临时目录与该 assetId 已就位的文件，不进 RDB 流程（契约 5.2）。
      ImageAssetStore.removeDirQuietly(tempDir);
      ImageAssetStore.removeFileQuietly(finalThumb);
      ImageAssetStore.removeFileQuietly(finalOriginal);
      if (e instanceof ImageAssetError) {
        throw e;
      }
      throw new ImageAssetError('io-failed', '图像保存失败，请重试', JSON.stringify(e));
    } finally {
      ImageAssetStore.removeDirQuietly(tempDir);
      if (pixelMap !== null) {
        try {
          await pixelMap.release();
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'PixelMap release failed: %{public}s', JSON.stringify(e));
        }
      }
    }
  }

  /**
   * 删除一组原图 + 缩略图。幂等：文件缺失不报错。
   * 接受绝对路径或相对 filesDir 路径；仅允许 records/ 下 _original.jpg/_thumb.jpg，防止误删。
   * 调用方：Agent 4 RecordService.delete（先删 RDB 行）、保存失败回滚。
   */
  async deleteImages(context: common.Context, originalPath: string, thumbnailPath: string): Promise<void> {
    ImageAssetStore.removeFileQuietly(ImageAssetStore.checkImageFile(context, originalPath));
    ImageAssetStore.removeFileQuietly(ImageAssetStore.checkImageFile(context, thumbnailPath));
  }

  /**
   * 扫描 records/ 下的孤儿图像文件：文件名 id 不在 referencedIds 中，
   * 且 mtime 早于宽限期（保护正在保存、尚未写入 RDB 的新文件）。
   *
   * @param referencedIds RDB 中全部 record_id（或文件名 id 集合）。
   * @param gracePeriodMs mtime 宽限，默认 ORPHAN_GRACE_PERIOD_MS（10 分钟）。
   * @param maxCount 单次最多返回数量，默认 ORPHAN_CLEANUP_MAX_COUNT（200）。
   * @returns 孤儿文件绝对路径列表。
   */
  async listOrphanRecordImages(context: common.Context, referencedIds: Array<string>,
    gracePeriodMs?: number, maxCount?: number): Promise<Array<string>> {
    const recordsDir: string = `${context.filesDir}/${RECORDS_DIR_NAME}`;
    if (!fs.accessSync(recordsDir)) {
      return [];
    }
    const grace: number = gracePeriodMs ?? ORPHAN_GRACE_PERIOD_MS;
    const limit: number = maxCount ?? ORPHAN_CLEANUP_MAX_COUNT;
    const known: Set<string> = new Set<string>(referencedIds);
    const nowMs: number = Date.now();
    const orphans: Array<string> = [];
    try {
      const entries: Array<string> = fs.listFileSync(recordsDir);
      for (const entry of entries) {
        if (orphans.length >= limit) {
          break;
        }
        const id: string = ImageAssetStore.extractAssetId(entry);
        if (id.length === 0 || known.has(id)) {
          continue;
        }
        const path: string = `${recordsDir}/${entry}`;
        try {
          const stat: fs.Stat = fs.statSync(path);
          // mtime 单位为秒；新文件跳过，避免误删进行中的保存。
          if (nowMs - stat.mtime * 1000 < grace) {
            continue;
          }
          orphans.push(path);
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'stat %{public}s failed: %{public}s', path, JSON.stringify(e));
        }
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'list records dir failed: %{public}s', JSON.stringify(e));
    }
    return orphans;
  }

  /**
   * 清理孤儿图像文件，返回删除数量。
   * 契约 5.3：必须在 RDB 打开成功后执行；RDB 打不开时跳过（Agent 4 负责判断）。
   */
  async cleanupOrphanRecordImages(context: common.Context, referencedIds: Array<string>,
    gracePeriodMs?: number, maxCount?: number): Promise<number> {
    const orphans: Array<string> =
      await this.listOrphanRecordImages(context, referencedIds, gracePeriodMs, maxCount);
    let removed: number = 0;
    for (const path of orphans) {
      ImageAssetStore.removeFileQuietly(path);
      removed += 1;
      hilog.info(DOMAIN, TAG, 'Cleaned orphan image %{public}s', path);
    }
    return removed;
  }

  /**
   * 把相对路径解析为绝对沙箱路径（应用重启后重解析使用）。
   * 校验：拒绝绝对路径与 .. 段。
   */
  resolveAbsolutePath(context: common.Context, relativePath: string): string {
    if (relativePath.length === 0 || relativePath.startsWith('/') || relativePath.indexOf('..') >= 0) {
      throw new ImageAssetError('invalid-input', '非法的资源相对路径', relativePath);
    }
    return `${context.filesDir}/${relativePath}`;
  }

  /** 校验文件存在且可读；缩略图缺失视为记录损坏。 */
  async imageFileExists(context: common.Context, absoluteOrRelativePath: string): Promise<boolean> {
    const path: string = absoluteOrRelativePath.startsWith('/') ?
      absoluteOrRelativePath : this.resolveAbsolutePath(context, absoluteOrRelativePath);
    return fs.accessSync(path);
  }

  /**
   * 从持久化 JPEG 文件解码出可显示的 PixelMap（供历史列表/详情页展示缩略图或原图）。
   *
   * 与 createPreviewPixelMap（components/recognition/PreviewPixelMap.ets）的区别：
   * 后者从采集层 ImageSource 像素缓冲构建，用于当前会话预览；本方法从沙箱 JPEG
   * 文件解码，用于已保存记录的回放。
   *
   * @param context 应用上下文
   * @param relativeOrAbsolutePath 相对 filesDir 路径或绝对路径
   * @param maxEdge 可选：最长边等比缩放到 ≤ maxEdge；不放大；不传则返回原图尺寸
   * @returns PixelMap，调用方负责 release
   * @throws ImageAssetError（invalid-input/io-failed）
   */
  async decodePixelMap(context: common.Context, relativeOrAbsolutePath: string,
    maxEdge?: number): Promise<image.PixelMap> {
    const path: string = relativeOrAbsolutePath.startsWith('/') ?
      relativeOrAbsolutePath : this.resolveAbsolutePath(context, relativeOrAbsolutePath);
    let source: image.ImageSource | null = null;
    try {
      source = image.createImageSource(path);
      const pixelMap: image.PixelMap = await source.createPixelMap();
      if (maxEdge !== undefined && maxEdge > 0) {
        const info: image.ImageInfo = pixelMap.getImageInfoSync();
        const longest: number = Math.max(info.size.width, info.size.height);
        if (longest > maxEdge) {
          await pixelMap.scale(maxEdge / longest, maxEdge / longest);
        }
      }
      return pixelMap;
    } catch (e) {
      throw new ImageAssetError('io-failed', '图像解码失败', JSON.stringify(e));
    } finally {
      if (source !== null) {
        try {
          await source.release();
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'ImageSource release failed: %{public}s', JSON.stringify(e));
        }
      }
    }
  }

  // ---------------- 内部实现 ----------------

  /** rec_{unix_ms}_{hex4}；与契约 2.1 recordId 格式一致。hex4 随机 + 递增序号防同毫秒碰撞。 */
  private static nextAssetId(): string {
    idSeq = (idSeq + 1) % 0x10000;
    const rand: number = Math.floor(Math.random() * 0x10000);
    const hex: string = ((rand ^ idSeq) & 0xFFFF).toString(16).padStart(4, '0');
    return `rec_${Date.now()}_${hex}`;
  }

  /** 从文件名提取 assetId：rec_xxx_original.jpg / rec_xxx_thumb.jpg → rec_xxx；不匹配返回空串。 */
  private static extractAssetId(fileName: string): string {
    if (fileName.endsWith(ORIGINAL_SUFFIX)) {
      return fileName.substring(0, fileName.length - ORIGINAL_SUFFIX.length);
    }
    if (fileName.endsWith(THUMB_SUFFIX)) {
      return fileName.substring(0, fileName.length - THUMB_SUFFIX.length);
    }
    return '';
  }

  /** 校验并归一化为绝对路径：必须在 filesDir/records/ 下且为 _original.jpg/_thumb.jpg。 */
  private static checkImageFile(context: common.Context, path: string): string {
    const absolute: string = path.startsWith('/') ? path : `${context.filesDir}/${path}`;
    const prefix: string = `${context.filesDir}/${RECORDS_DIR_NAME}/`;
    if (!absolute.startsWith(prefix) || absolute.indexOf('..') >= 0) {
      throw new ImageAssetError('invalid-input', '路径不在图像目录内', path);
    }
    if (!absolute.endsWith(ORIGINAL_SUFFIX) && !absolute.endsWith(THUMB_SUFFIX)) {
      throw new ImageAssetError('invalid-input', '不是图像持久化文件', path);
    }
    return absolute;
  }

  /**
   * 将 PixelMap 按最长边等比缩放并编码为 JPEG。
   * maxEdge <= 0 或原图已小于等于 maxEdge 时不缩放（不放大）。
   */
  private static async encodeScaledJpeg(source: image.PixelMap, maxEdge: number,
    quality: number): Promise<ArrayBuffer> {
    const info: image.ImageInfo = source.getImageInfoSync();
    const width: number = info.size.width;
    const height: number = info.size.height;
    const longest: number = Math.max(width, height);
    let target: image.PixelMap = source;
    let owned: image.PixelMap | null = null;
    try {
      if (maxEdge > 0 && longest > maxEdge) {
        const factor: number = maxEdge / longest;
        // 复制一份再缩放：缩略图与原图副本共用同一 source，不能原地改动。
        const copy: image.PixelMap = image.createPixelMapSync(ImageAssetStore.dumpPixels(source), {
          size: { width: width, height: height },
          pixelFormat: image.PixelMapFormat.RGBA_8888,
          editable: true
        });
        await copy.scale(factor, factor);
        owned = copy;
        target = copy;
      }
      const packer: image.ImagePacker = image.createImagePacker();
      const options: image.PackingOption = { format: JPEG_FORMAT, quality: quality };
      return await packer.packing(target, options);
    } catch (e) {
      throw new ImageAssetError('encode-failed', 'JPEG 编码失败', JSON.stringify(e));
    } finally {
      if (owned !== null) {
        try {
          await owned.release();
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'scaled PixelMap release failed: %{public}s', JSON.stringify(e));
        }
      }
    }
  }

  private static dumpPixels(pixelMap: image.PixelMap): ArrayBuffer {
    const info: image.ImageInfo = pixelMap.getImageInfoSync();
    const buffer: ArrayBuffer = new ArrayBuffer(info.size.width * info.size.height * 4);
    pixelMap.readPixelsToBufferSync(buffer);
    return buffer;
  }

  private static writeFileSync(path: string, data: ArrayBuffer): void {
    const file: fs.File = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, data);
    } finally {
      fs.closeSync(file);
    }
  }

  /** rename 原子就位；目标已存在时先尝试直接 rename，失败再删后移。 */
  private static moveIntoPlace(tempPath: string, finalPath: string): void {
    try {
      fs.renameSync(tempPath, finalPath);
      return;
    } catch (e) {
      hilog.debug(DOMAIN, TAG, 'rename over existing failed, fallback: %{public}s', JSON.stringify(e));
    }
    if (fs.accessSync(finalPath)) {
      fs.unlinkSync(finalPath);
    }
    fs.renameSync(tempPath, finalPath);
  }

  private static async describeSaved(absolute: string, relativePath: string): Promise<PersistedImageFile> {
    const stat: fs.Stat = fs.statSync(absolute);
    // 缩放后尺寸经四舍五入不可推导，回读 JPEG 头获取真实尺寸与可解码性。
    const source: image.ImageSource = image.createImageSource(absolute);
    let width: number = 0;
    let height: number = 0;
    try {
      const info: image.ImageInfo = source.getImageInfoSync(0);
      width = info.size.width;
      height = info.size.height;
    } finally {
      await source.release();
    }
    const saved: PersistedImageFile = {
      relativePath: relativePath,
      width: width,
      height: height,
      format: JPEG_FORMAT_LABEL,
      byteSize: stat.size
    };
    return saved;
  }

  private static removeFileQuietly(path: string): void {
    try {
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'remove %{public}s failed: %{public}s', path, JSON.stringify(e));
    }
  }

  /** 删除本模块创建的扁平目录（仅含文件）；尽力而为，不抛错。 */
  private static removeDirQuietly(dir: string): void {
    try {
      if (!fs.accessSync(dir)) {
        return;
      }
      const entries: Array<string> = fs.listFileSync(dir);
      for (const entry of entries) {
        const path: string = `${dir}/${entry}`;
        try {
          const stat: fs.Stat = fs.statSync(path);
          if (stat.isDirectory()) {
            ImageAssetStore.removeDirQuietly(path);
          } else {
            fs.unlinkSync(path);
          }
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'remove %{public}s failed: %{public}s', path, JSON.stringify(e));
        }
      }
      fs.rmdirSync(dir);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'removeDir %{public}s failed: %{public}s', dir, JSON.stringify(e));
    }
  }
}
