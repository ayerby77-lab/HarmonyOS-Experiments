"""模型版本查询结构。"""
from __future__ import annotations

from pydantic import BaseModel


class ModelVersionResponse(BaseModel):
    modelId: str
    version: str
    sha256: str
    fileName: str
    sizeBytes: int
    opset: int
    inputWidth: int
    inputHeight: int
    classCount: int
    releasedAtMs: int
    downloadUrl: str
