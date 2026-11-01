/**
 * 历史记录页展示辅助：时间、来源、执行模式与存储错误文案。
 * 仅做展示格式化，不访问存储。
 */
import { InferenceExecutionMode } from '../../models/DetectionTypes';
import { ImageOrigin } from '../../models/ImageTypes';
import { RecordErrorCode } from '../../models/RecordTypes';
import { RecordFailure } from '../../services/storage/RecordService';
import { ImageAssetError } from '../../services/imaging/ImageAssetStore';

function pad2(value: number): string {
  return value < 10 ? `0${value}` : `${value}`;
}

/** Unix 毫秒 → `YYYY-MM-DD HH:mm`。 */
export function formatRecordTime(ms: number): string {
  if (!Number.isFinite(ms) || ms <= 0) {
    return '--';
  }
  const date: Date = new Date(ms);
  return `${date.getFullYear()}-${pad2(date.getMonth() + 1)}-${pad2(date.getDate())} ` +
    `${pad2(date.getHours())}:${pad2(date.getMinutes())}`;
}

/** 图像来源中文名。 */
export function formatSource(source: ImageOrigin): string {
  return source === ImageOrigin.CAMERA ? '相机' : '相册';
}

/** 执行模式中文名。 */
export function formatExecutionMode(mode: InferenceExecutionMode): string {
  return mode === InferenceExecutionMode.SYNC ? '同步' : 'TaskPool';
}

/** 存储相关错误 → 面向用户的恢复提示。 */
export function describeStorageError(err: Object): string {
  const recordFailure: RecordFailure = err as RecordFailure;
  if (recordFailure !== undefined && recordFailure.code !== undefined) {
    switch (recordFailure.code) {
      case RecordErrorCode.DB_INIT_FAILED:
        return '识别历史暂不可用，请重启应用后重试';
      case RecordErrorCode.DB_WRITE_FAILED:
        return '保存失败，请重试';
      case RecordErrorCode.RECORD_NOT_FOUND:
        return '记录已删除';
      case RecordErrorCode.IMAGE_COPY_FAILED:
        return '原图保存失败，请检查存储空间后重试';
      case RecordErrorCode.THUMBNAIL_FAILED:
        return '缩略图生成失败，请重试';
      default:
        break;
    }
    if (recordFailure.message !== undefined && recordFailure.message.length > 0) {
      return recordFailure.message;
    }
  }
  const imageFailure: ImageAssetError = err as ImageAssetError;
  if (imageFailure !== undefined && imageFailure.code !== undefined) {
    if (imageFailure.code === 'invalid-input') {
      return '图片格式不支持保存，请重新选择图片';
    }
    return '图像保存失败，请重试';
  }
  const plain: Error = err as Error;
  if (plain !== undefined && plain.message !== undefined && plain.message.length > 0) {
    return plain.message;
  }
  return '操作失败，请重试';
}
