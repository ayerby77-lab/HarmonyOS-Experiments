"""记录路由：批量幂等上传与筛选分页。"""
from __future__ import annotations

from typing import Literal

from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session

from app.core.auth import get_current_device
from app.core.database import get_db
from app.core.errors import ApiError, ErrorCode
from app.models.device import Device
from app.schemas.records import (
    RecordBatchRequest,
    RecordBatchResponse,
    RecordDetail,
    RecordPage,
    RecordStatistics,
)
from app.services import record_service

router = APIRouter(prefix="/api/records", tags=["records"])
statistics_router = APIRouter(prefix="/api/statistics", tags=["statistics"])


@router.post("", response_model=RecordBatchResponse, summary="批量上传识别记录（按 recordId 幂等）")
def upload_records(
    batch: RecordBatchRequest,
    device: Device = Depends(get_current_device),
    db: Session = Depends(get_db),
) -> RecordBatchResponse:
    results = record_service.save_batch(db, device.device_id, batch)
    return RecordBatchResponse(results=results)


@router.get("", response_model=RecordPage, summary="查询记录（时间/类别筛选、分页）")
def query_records(
    fromMs: int | None = Query(default=None, ge=0, description="recognizedAtMs 下界，闭区间"),
    toMs: int | None = Query(default=None, ge=0, description="recognizedAtMs 上界，闭区间"),
    classId: int | None = Query(default=None, ge=0, description="最终类别，仅匹配 deleted=false"),
    source: Literal["camera", "gallery"] | None = Query(default=None, description="图像来源"),
    page: int = Query(default=1, ge=1),
    pageSize: int = Query(default=20, ge=1, le=100),
    device: Device = Depends(get_current_device),
    db: Session = Depends(get_db),
) -> RecordPage:
    if fromMs is not None and toMs is not None and fromMs > toMs:
        raise ApiError(400, ErrorCode.VALIDATION_ERROR, "时间范围非法", "fromMs > toMs")
    return record_service.list_records(
        db,
        device.device_id,
        from_ms=fromMs,
        to_ms=toMs,
        class_id=classId,
        image_origin=source,
        page=page,
        page_size=pageSize,
    )


@router.get("/{record_id}", response_model=RecordDetail, summary="单条记录详情（含检测项）")
def get_record(
    record_id: str,
    device: Device = Depends(get_current_device),
    db: Session = Depends(get_db),
) -> RecordDetail:
    return record_service.get_record_detail(db, device.device_id, record_id)


@statistics_router.get("", response_model=RecordStatistics, summary="识别统计（时间范围聚合）")
def get_statistics(
    fromMs: int | None = Query(default=None, ge=0, description="recognizedAtMs 下界，闭区间"),
    toMs: int | None = Query(default=None, ge=0, description="recognizedAtMs 上界，闭区间"),
    device: Device = Depends(get_current_device),
    db: Session = Depends(get_db),
) -> RecordStatistics:
    if fromMs is not None and toMs is not None and fromMs > toMs:
        raise ApiError(400, ErrorCode.VALIDATION_ERROR, "时间范围非法", "fromMs > toMs")
    return record_service.statistics(db, device.device_id, from_ms=fromMs, to_ms=toMs)
