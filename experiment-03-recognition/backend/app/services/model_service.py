"""模型版本业务：当前版本元数据与下载文件定位。"""
from __future__ import annotations

from pathlib import Path

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.config import get_settings
from app.models.model_version import ModelVersion
from app.schemas.models import ModelVersionResponse
from app.services.auth_service import now_ms


def ensure_seed_model(db: Session) -> ModelVersion:
    """首次启动时用配置登记当前模型版本（已存在则不覆盖）。"""
    settings = get_settings()
    existing = db.scalar(select(ModelVersion).where(ModelVersion.version == settings.model_version))
    if existing is not None:
        return existing
    path: Path = settings.model_path
    model = ModelVersion(
        version=settings.model_version,
        model_id=settings.model_id,
        sha256=settings.model_sha256,
        file_name=path.name,
        size_bytes=path.stat().st_size if path.is_file() else 0,
        opset=18,
        input_width=640,
        input_height=640,
        class_count=80,
        released_at_ms=now_ms(),
        is_current=True,
    )
    db.add(model)
    db.commit()
    return model


def get_current_model(db: Session) -> ModelVersion:
    current = db.scalar(
        select(ModelVersion)
        .where(ModelVersion.is_current.is_(True))
        .order_by(ModelVersion.released_at_ms.desc())
    )
    if current is None:
        current = ensure_seed_model(db)
    return current


def to_response(model: ModelVersion) -> ModelVersionResponse:
    return ModelVersionResponse(
        modelId=model.model_id,
        version=model.version,
        sha256=model.sha256,
        fileName=model.file_name,
        sizeBytes=model.size_bytes,
        opset=model.opset,
        inputWidth=model.input_width,
        inputHeight=model.input_height,
        classCount=model.class_count,
        releasedAtMs=model.released_at_ms,
        downloadUrl="/api/models/download",
    )


def model_file_path() -> Path:
    return get_settings().model_path
