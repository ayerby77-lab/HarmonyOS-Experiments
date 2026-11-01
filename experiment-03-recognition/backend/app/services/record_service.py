"""记录业务逻辑：幂等批量写入、时间/类别筛选与分页。"""
from __future__ import annotations

import hashlib
import json

from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError, SQLAlchemyError
from sqlalchemy.orm import Session, selectinload

from app.core.errors import ApiError, ErrorCode
from app.models.record import Record, RecordDetection
from app.schemas.records import (
    CountItem,
    DetectionView,
    RecordBatchRequest,
    RecordDetail,
    RecordPage,
    RecordStatistics,
    RecordSummary,
    RecordUploadItem,
    RecordUploadResult,
)
from app.services.auth_service import now_ms

SUPPORTED_SCHEMA_VERSION = 1


def _canonical_payload(item: RecordUploadItem) -> str:
    """规范化 JSON：字段排序、紧凑分隔符，保证同一载荷哈希稳定。"""
    return json.dumps(
        item.model_dump(mode="json"), sort_keys=True, separators=(",", ":"), ensure_ascii=False
    )


def _payload_hash(item: RecordUploadItem) -> str:
    return hashlib.sha256(_canonical_payload(item).encode("utf-8")).hexdigest()


def _validate_item(item: RecordUploadItem) -> tuple[str, str] | None:
    """按契约不变量校验；返回 (code, message) 或 None。"""
    if item.schemaVersion != SUPPORTED_SCHEMA_VERSION:
        return (
            ErrorCode.SCHEMA_VERSION_UNSUPPORTED,
            f"不支持的 schemaVersion: {item.schemaVersion}",
        )
    if item.rawDetectionCount != len(item.detections):
        return (
            ErrorCode.RECORD_INVALID,
            f"rawDetectionCount={item.rawDetectionCount} 与 detections={len(item.detections)} 不一致",
        )
    raw_indexes = {d.rawIndex for d in item.detections}
    if len(raw_indexes) != len(item.detections):
        return (ErrorCode.RECORD_INVALID, "rawIndex 重复")
    detection_ids = {d.detectionId for d in item.detections}
    if len(detection_ids) != len(item.detections):
        return (ErrorCode.RECORD_INVALID, "detectionId 重复")
    for det in item.detections:
        if det.right < det.left or det.bottom < det.top:
            return (ErrorCode.RECORD_INVALID, f"检测框坐标非法: {det.detectionId}")
    return None


def _query_existing(db: Session, device_id: str, record_id: str) -> Record | None:
    return db.scalar(
        select(Record).where(Record.device_id == device_id, Record.record_id == record_id)
    )


def _existing_result(existing: Record, payload_hash: str) -> RecordUploadResult:
    if existing.payload_hash == payload_hash:
        return RecordUploadResult(
            recordId=existing.record_id,
            status="duplicate",
            serverRevision=str(existing.revision),
        )
    return RecordUploadResult(
        recordId=existing.record_id,
        status="conflict",
        serverRevision=str(existing.revision),
        code=ErrorCode.RECORD_CONFLICT,
        message="recordId 已存在且载荷不同，不覆盖已有记录",
    )


def _build_record(device_id: str, item: RecordUploadItem, payload_hash: str) -> Record:
    record = Record(
        device_id=device_id,
        record_id=item.recordId,
        payload_hash=payload_hash,
        revision=1,
        schema_version=item.schemaVersion,
        request_id=item.requestId,
        image_id=item.imageId,
        captured_at_ms=item.capturedAtMs,
        recognized_at_ms=item.recognizedAtMs,
        saved_at_ms=item.savedAtMs,
        edited_at_ms=item.editedAtMs,
        image_width=item.imageWidth,
        image_height=item.imageHeight,
        is_mirrored=item.isMirrored,
        image_origin=item.imageOrigin,
        model_id=item.model.modelId,
        model_sha256=item.model.sha256,
        confidence_threshold=item.options.confidenceThreshold,
        iou_threshold=item.options.iouThreshold,
        max_detections=item.options.maxDetections,
        execution_mode=item.options.executionMode,
        preprocess_ms=item.timing.preprocessMs,
        inference_ms=item.timing.inferenceMs,
        postprocess_ms=item.timing.postprocessMs,
        total_ms=item.timing.totalMs,
        cold_start=item.timing.coldStart,
        model_load_ms=item.timing.modelLoadMs,
        raw_detection_count=item.rawDetectionCount,
        edited=item.edited,
        received_at_ms=now_ms(),
    )
    record.detections = [
        RecordDetection(
            detection_id=det.detectionId,
            raw_index=det.rawIndex,
            raw_class_id=det.rawClassId,
            raw_label=det.rawLabel,
            class_id=det.classId,
            label=det.label,
            confidence=det.confidence,
            left=det.left,
            top=det.top,
            right=det.right,
            bottom=det.bottom,
            deleted=det.deleted,
            class_corrected=det.classCorrected,
            edited_at_ms=det.editedAtMs,
        )
        for det in item.detections
    ]
    return record


def save_batch(db: Session, device_id: str, batch: RecordBatchRequest) -> list[RecordUploadResult]:
    """逐条写入；单条失败不影响其他条（部分成功）。

    幂等：同 (deviceId, recordId) 且规范化载荷相同 → duplicate；
    载荷不同 → conflict，不覆盖已有记录。
    """
    if batch.schemaVersion != SUPPORTED_SCHEMA_VERSION:
        raise ApiError(
            422,
            ErrorCode.SCHEMA_VERSION_UNSUPPORTED,
            "不支持的 schemaVersion",
            f"batch.schemaVersion={batch.schemaVersion}",
        )

    results: list[RecordUploadResult] = []
    for item in batch.records:
        invalid = _validate_item(item)
        if invalid is not None:
            code, message = invalid
            results.append(
                RecordUploadResult(recordId=item.recordId, status="invalid", code=code, message=message)
            )
            continue

        payload_hash = _payload_hash(item)
        existing = _query_existing(db, device_id, item.recordId)
        if existing is not None:
            results.append(_existing_result(existing, payload_hash))
            continue

        try:
            db.add(_build_record(device_id, item, payload_hash))
            db.commit()
            results.append(
                RecordUploadResult(recordId=item.recordId, status="created", serverRevision="1")
            )
        except IntegrityError:
            # 并发下同 recordId 已由另一请求写入：回查后按幂等语义返回
            db.rollback()
            existing = _query_existing(db, device_id, item.recordId)
            if existing is not None:
                results.append(_existing_result(existing, payload_hash))
            else:
                results.append(
                    RecordUploadResult(
                        recordId=item.recordId,
                        status="invalid",
                        code=ErrorCode.STORAGE_WRITE_FAILED,
                        message="写入失败，请重试",
                    )
                )
        except SQLAlchemyError:
            db.rollback()
            results.append(
                RecordUploadResult(
                    recordId=item.recordId,
                    status="invalid",
                    code=ErrorCode.STORAGE_WRITE_FAILED,
                    message="写入失败，请重试",
                )
            )
    return results


def _counts_of(record: Record) -> list[CountItem]:
    """最终计数：deleted=false 的最终 classId 分组，count 降序 + classId 升序。"""
    grouped: dict[int, CountItem] = {}
    for det in record.detections:
        if det.deleted:
            continue
        current = grouped.get(det.class_id)
        if current is None:
            grouped[det.class_id] = CountItem(classId=det.class_id, label=det.label, count=1)
        else:
            current.count += 1
    return sorted(grouped.values(), key=lambda c: (-c.count, c.classId))


def list_records(
    db: Session,
    device_id: str,
    *,
    from_ms: int | None,
    to_ms: int | None,
    class_id: int | None,
    image_origin: str | None,
    page: int,
    page_size: int,
) -> RecordPage:
    filters = [Record.device_id == device_id]
    if from_ms is not None:
        filters.append(Record.recognized_at_ms >= from_ms)
    if to_ms is not None:
        filters.append(Record.recognized_at_ms <= to_ms)
    if image_origin is not None:
        filters.append(Record.image_origin == image_origin)
    if class_id is not None:
        filters.append(
            Record.id.in_(
                select(RecordDetection.record_pk).where(
                    RecordDetection.deleted.is_(False), RecordDetection.class_id == class_id
                )
            )
        )

    total = db.scalar(select(func.count()).select_from(select(Record.id).where(*filters).subquery()))
    rows = db.scalars(
        select(Record)
        .where(*filters)
        .options(selectinload(Record.detections))
        .order_by(Record.recognized_at_ms.desc(), Record.record_id.desc())
        .offset((page - 1) * page_size)
        .limit(page_size)
    ).all()

    items = [
        RecordSummary(
            recordId=row.record_id,
            recognizedAtMs=row.recognized_at_ms,
            savedAtMs=row.saved_at_ms,
            imageOrigin=row.image_origin,
            imageWidth=row.image_width,
            imageHeight=row.image_height,
            modelId=row.model_id,
            executionMode=row.execution_mode,
            totalMs=row.total_ms,
            rawDetectionCount=row.raw_detection_count,
            edited=row.edited,
            counts=_counts_of(row),
        )
        for row in rows
    ]
    total_count = int(total or 0)
    return RecordPage(
        items=items,
        page=page,
        pageSize=page_size,
        total=total_count,
        hasMore=page * page_size < total_count,
    )


def get_record_detail(db: Session, device_id: str, record_id: str) -> RecordDetail:
    """按 (device_id, record_id) 取详情；跨设备访问与不存在一样返回 404。"""
    record = db.scalar(
        select(Record)
        .where(Record.device_id == device_id, Record.record_id == record_id)
        .options(selectinload(Record.detections))
    )
    if record is None:
        raise ApiError(
            404, ErrorCode.RECORD_NOT_FOUND, "记录不存在", f"recordId={record_id}"
        )
    detections = sorted(record.detections, key=lambda d: d.raw_index)
    return RecordDetail(
        recordId=record.record_id,
        revision=record.revision,
        capturedAtMs=record.captured_at_ms,
        recognizedAtMs=record.recognized_at_ms,
        savedAtMs=record.saved_at_ms,
        editedAtMs=record.edited_at_ms,
        imageOrigin=record.image_origin,
        imageWidth=record.image_width,
        imageHeight=record.image_height,
        isMirrored=record.is_mirrored,
        modelId=record.model_id,
        modelSha256=record.model_sha256,
        confidenceThreshold=record.confidence_threshold,
        iouThreshold=record.iou_threshold,
        maxDetections=record.max_detections,
        executionMode=record.execution_mode,
        preprocessMs=record.preprocess_ms,
        inferenceMs=record.inference_ms,
        postprocessMs=record.postprocess_ms,
        totalMs=record.total_ms,
        coldStart=record.cold_start,
        modelLoadMs=record.model_load_ms,
        rawDetectionCount=record.raw_detection_count,
        edited=record.edited,
        counts=_counts_of(record),
        detections=[
            DetectionView(
                detectionId=det.detection_id,
                rawIndex=det.raw_index,
                rawClassId=det.raw_class_id,
                rawLabel=det.raw_label,
                classId=det.class_id,
                label=det.label,
                confidence=det.confidence,
                left=det.left,
                top=det.top,
                right=det.right,
                bottom=det.bottom,
                deleted=det.deleted,
                classCorrected=det.class_corrected,
                editedAtMs=det.edited_at_ms,
            )
            for det in detections
        ],
    )


def statistics(
    db: Session,
    device_id: str,
    *,
    from_ms: int | None,
    to_ms: int | None,
) -> RecordStatistics:
    """时间范围内聚合：记录数、有效检测数、按最终类别计数（排除 deleted）。

    空结果记录计入 totalRecords，但不产生类别计数（api-plan 统计规划）。
    """
    record_filters = [Record.device_id == device_id]
    if from_ms is not None:
        record_filters.append(Record.recognized_at_ms >= from_ms)
    if to_ms is not None:
        record_filters.append(Record.recognized_at_ms <= to_ms)

    total_records = int(
        db.scalar(select(func.count()).select_from(Record).where(*record_filters)) or 0
    )

    det_filters = [
        Record.device_id == device_id,
        RecordDetection.deleted.is_(False),
    ]
    if from_ms is not None:
        det_filters.append(Record.recognized_at_ms >= from_ms)
    if to_ms is not None:
        det_filters.append(Record.recognized_at_ms <= to_ms)

    total_detections = int(
        db.scalar(
            select(func.count())
            .select_from(RecordDetection)
            .join(Record, RecordDetection.record_pk == Record.id)
            .where(*det_filters)
        )
        or 0
    )

    rows = db.execute(
        select(RecordDetection.class_id, func.max(RecordDetection.label), func.count())
        .select_from(RecordDetection)
        .join(Record, RecordDetection.record_pk == Record.id)
        .where(*det_filters)
        .group_by(RecordDetection.class_id)
    ).all()
    counts = sorted(
        (CountItem(classId=class_id, label=label, count=count) for class_id, label, count in rows),
        key=lambda c: (-c.count, c.classId),
    )
    return RecordStatistics(
        totalRecords=total_records, totalDetections=total_detections, counts=counts
    )
