"""模型版本元数据：供客户端查询最新版本与下载。"""
from __future__ import annotations

from sqlalchemy import BigInteger, Boolean, Integer, String
from sqlalchemy.orm import Mapped, mapped_column

from app.core.database import Base


class ModelVersion(Base):
    __tablename__ = "model_versions"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    version: Mapped[str] = mapped_column(String(32), unique=True, nullable=False)
    model_id: Mapped[str] = mapped_column(String(64), nullable=False)
    sha256: Mapped[str] = mapped_column(String(64), nullable=False)
    file_name: Mapped[str] = mapped_column(String(128), nullable=False)
    size_bytes: Mapped[int] = mapped_column(BigInteger, nullable=False, default=0)
    opset: Mapped[int] = mapped_column(Integer, nullable=False, default=18)
    input_width: Mapped[int] = mapped_column(Integer, nullable=False, default=640)
    input_height: Mapped[int] = mapped_column(Integer, nullable=False, default=640)
    class_count: Mapped[int] = mapped_column(Integer, nullable=False, default=80)
    released_at_ms: Mapped[int] = mapped_column(BigInteger, nullable=False)
    is_current: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
