"""模型路由：版本查询与文件下载。"""
from __future__ import annotations

from fastapi import APIRouter, Depends
from fastapi.responses import FileResponse
from sqlalchemy.orm import Session

from app.core.auth import get_current_device
from app.core.database import get_db
from app.core.errors import ApiError, ErrorCode
from app.models.device import Device
from app.schemas.models import ModelVersionResponse
from app.services import model_service

router = APIRouter(prefix="/api/models", tags=["models"])


@router.get("/version", response_model=ModelVersionResponse, summary="当前模型版本")
def get_version(
    device: Device = Depends(get_current_device), db: Session = Depends(get_db)
) -> ModelVersionResponse:
    return model_service.to_response(model_service.get_current_model(db))


@router.get("/download", summary="下载模型文件")
def download_model(device: Device = Depends(get_current_device)) -> FileResponse:
    path = model_service.model_file_path()
    if not path.is_file():
        raise ApiError(
            404,
            ErrorCode.MODEL_NOT_FOUND,
            "模型文件不存在",
            str(path),
        )
    return FileResponse(
        path,
        media_type="application/octet-stream",
        filename=path.name,
    )
